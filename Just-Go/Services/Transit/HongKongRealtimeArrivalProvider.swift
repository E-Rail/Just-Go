import Foundation

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

enum RealtimeArrivalProviderError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case timedOut
    case transport(String)
    case invalidResponse
    case rateLimited(retryAfter: TimeInterval)
    case httpStatus(Int)
    case serviceUnavailable(String?)
    case contractViolation(String)
}

extension RealtimeArrivalProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason):
            return "Invalid realtime arrival request: \(reason)"
        case .timedOut:
            return "The realtime arrival request timed out."
        case .transport(let message):
            return "The realtime arrival request failed: \(message)"
        case .invalidResponse:
            return "The realtime arrival service returned an invalid response."
        case .rateLimited(let retryAfter):
            let seconds = String(format: "%.0f", retryAfter.rounded(.up))
            return "The realtime arrival service is rate limited. Retry in \(seconds) seconds."
        case .httpStatus(let statusCode):
            return "The realtime arrival service returned HTTP \(statusCode)."
        case .serviceUnavailable(let message):
            return message ?? "The realtime arrival service is unavailable."
        case .contractViolation(let reason):
            return "The realtime arrival response was invalid: \(reason)"
        }
    }
}

actor HongKongRealtimeArrivalProvider: RealtimeArrivalProviding {
    private enum Endpoint: Hashable, Sendable {
        case heavyRail
        case lightRail
    }

    private struct DestinationKey: Hashable, Sendable {
        let code: String
        let name: String
    }

    private struct CacheKey: Hashable, Sendable {
        let stationID: String
        let reference: RealtimeArrivalReference
        let destinations: [DestinationKey]
        let lineName: String
        let lineColorHex: String
    }

    private struct PreparedRequest: Sendable {
        let cacheKey: CacheKey
        let endpoint: Endpoint
        let reference: RealtimeArrivalReference
        let destinationNamesByCode: [String: String]
        let lineName: String
        let lineColorHex: String
    }

    private struct CacheEntry: Sendable {
        let arrivals: [RealTimeArrival]
        let expiresAt: ContinuousClock.Instant
    }

    private struct InFlightRequest: Sendable {
        let token: UUID
        let task: Task<[RealTimeArrival], Error>
    }

    private static let cacheLifetime: TimeInterval = 10
    private static let requestTimeout: TimeInterval = 5
    private static let defaultRetryDelay: TimeInterval = 30
    // Monotonic, not wall-clock: a device clock change/NTP resync must not make a 10s cache
    // entry or a 30s rate-limit backoff appear valid for far longer than intended.
    private static let clock = ContinuousClock()

    private let session: URLSession
    private var cache: [CacheKey: CacheEntry] = [:]
    private var inFlight: [CacheKey: InFlightRequest] = [:]
    private var retryNotBefore: [Endpoint: ContinuousClock.Instant] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func arrivals(for request: RealtimeArrivalRequest) async throws -> [RealTimeArrival] {
        let prepared = try Self.prepare(request)
        let key = prepared.cacheKey
        let now = Self.clock.now

        if let cached = cache[key] {
            if cached.expiresAt > now {
                return cached.arrivals
            }
            cache.removeValue(forKey: key)
        }

        if let active = inFlight[key] {
            return try await finish(active, for: key, endpoint: prepared.endpoint)
        }

        if let retryDate = retryNotBefore[prepared.endpoint] {
            guard retryDate <= now else {
                throw RealtimeArrivalProviderError.rateLimited(
                    retryAfter: (retryDate - now).timeInterval
                )
            }
            retryNotBefore.removeValue(forKey: prepared.endpoint)
        }

        let token = UUID()
        let session = self.session
        let task = Task<[RealTimeArrival], Error> {
            try await Self.fetch(prepared, using: session)
        }
        let active = InFlightRequest(token: token, task: task)
        inFlight[key] = active
        return try await finish(active, for: key, endpoint: prepared.endpoint)
    }

    private func finish(
        _ active: InFlightRequest,
        for key: CacheKey,
        endpoint: Endpoint
    ) async throws -> [RealTimeArrival] {
        do {
            let arrivals = try await active.task.value
            // Only the task still registered for this exact station/reference may update its cache.
            if inFlight[key]?.token == active.token {
                inFlight.removeValue(forKey: key)
                cache[key] = CacheEntry(
                    arrivals: arrivals,
                    expiresAt: Self.clock.now.advanced(by: .seconds(Self.cacheLifetime))
                )
            }
            return arrivals
        } catch {
            if inFlight[key]?.token == active.token {
                inFlight.removeValue(forKey: key)
                if let providerError = error as? RealtimeArrivalProviderError,
                   case .rateLimited(let retryAfter) = providerError {
                    let retryDate = Self.clock.now.advanced(by: .seconds(retryAfter))
                    retryNotBefore[endpoint] = max(retryNotBefore[endpoint] ?? retryDate, retryDate)
                }
            }
            throw error
        }
    }

    private static func prepare(_ request: RealtimeArrivalRequest) throws -> PreparedRequest {
        let stationID = trimmed(request.stationID)
        guard let stationID else {
            throw RealtimeArrivalProviderError.invalidRequest("stationID is empty")
        }

        let reference: RealtimeArrivalReference
        let endpoint: Endpoint
        switch request.reference {
        case .hongKongHeavyRail(let lineCode, let stationCode):
            guard let lineCode = normalizedCode(lineCode),
                  let stationCode = normalizedCode(stationCode) else {
                throw RealtimeArrivalProviderError.invalidRequest(
                    "heavy rail line and station codes are required"
                )
            }
            reference = .hongKongHeavyRail(lineCode: lineCode, stationCode: stationCode)
            endpoint = .heavyRail
        case .hongKongLightRail(let officialStationID):
            guard let officialStationID = trimmed(officialStationID) else {
                throw RealtimeArrivalProviderError.invalidRequest(
                    "Light Rail station_id is required"
                )
            }
            reference = .hongKongLightRail(stationID: officialStationID)
            endpoint = .lightRail
        }

        guard let lineName = trimmed(request.lineName.localized) else {
            throw RealtimeArrivalProviderError.invalidRequest("line name is empty")
        }
        guard let lineColorHex = trimmed(request.lineColorHex) else {
            throw RealtimeArrivalProviderError.invalidRequest("line color is empty")
        }

        var destinationNamesByCode: [String: String] = [:]
        for (rawCode, name) in request.destinationNamesByCode {
            guard let code = normalizedCode(rawCode),
                  let localizedName = trimmed(name.localized) else { continue }
            destinationNamesByCode[code] = destinationNamesByCode[code] ?? localizedName
        }
        var destinations: [DestinationKey] = destinationNamesByCode.map {
            DestinationKey(code: $0.key, name: $0.value)
        }
        destinations.sort {
            $0.code == $1.code ? $0.name < $1.name : $0.code < $1.code
        }
        let key = CacheKey(
            stationID: stationID,
            reference: reference,
            destinations: destinations,
            lineName: lineName,
            lineColorHex: lineColorHex
        )
        return PreparedRequest(
            cacheKey: key,
            endpoint: endpoint,
            reference: reference,
            destinationNamesByCode: destinationNamesByCode,
            lineName: lineName,
            lineColorHex: lineColorHex
        )
    }

    private static func fetch(
        _ request: PreparedRequest,
        using session: URLSession
    ) async throws -> [RealTimeArrival] {
        let urlRequest = try makeURLRequest(for: request.reference)
        let data: Data
        let response: URLResponse
        do {
            // `timeoutIntervalForRequest` only fires when no bytes arrive for the interval. A
            // connection that trickles data indefinitely never trips it, so an unguarded fetch
            // could hang well past `requestTimeout`. Race the fetch against an explicit deadline.
            (data, response) = try await withDeadline(
                seconds: requestTimeout,
                onTimeout: { RealtimeArrivalProviderError.timedOut }
            ) {
                try await session.data(for: urlRequest)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RealtimeArrivalProviderError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw RealtimeArrivalProviderError.timedOut
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw RealtimeArrivalProviderError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RealtimeArrivalProviderError.invalidResponse
        }
        if httpResponse.statusCode == 429 {
            throw RealtimeArrivalProviderError.rateLimited(
                retryAfter: retryDelay(from: httpResponse)
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RealtimeArrivalProviderError.httpStatus(httpResponse.statusCode)
        }

        do {
            switch request.reference {
            case .hongKongHeavyRail(let lineCode, let stationCode):
                return try parseHeavyRail(
                    data,
                    lineCode: lineCode,
                    stationCode: stationCode,
                    request: request
                )
            case .hongKongLightRail:
                return try parseLightRail(data, request: request)
            }
        } catch let error as RealtimeArrivalProviderError {
            throw error
        } catch {
            throw RealtimeArrivalProviderError.contractViolation(error.localizedDescription)
        }
    }

    private static func makeURLRequest(
        for reference: RealtimeArrivalReference
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "rt.data.gov.hk"

        switch reference {
        case .hongKongHeavyRail(let lineCode, let stationCode):
            components.path = "/v1/transport/mtr/getSchedule.php"
            components.queryItems = [
                URLQueryItem(name: "line", value: lineCode),
                URLQueryItem(name: "sta", value: stationCode),
                URLQueryItem(name: "lang", value: "EN")
            ]
        case .hongKongLightRail(let stationID):
            components.path = "/v1/transport/mtr/lrt/getSchedule"
            components.queryItems = [
                URLQueryItem(name: "station_id", value: stationID),
                URLQueryItem(name: "with_special", value: "1")
            ]
        }

        guard let url = components.url else {
            throw RealtimeArrivalProviderError.invalidRequest("official reference is invalid")
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func parseHeavyRail(
        _ data: Data,
        lineCode: String,
        stationCode: String,
        request: PreparedRequest
    ) throws -> [RealTimeArrival] {
        let payload = try JSONDecoder().decode(HeavyRailPayload.self, from: data)
        guard payload.status.value == 1 else {
            throw RealtimeArrivalProviderError.serviceUnavailable(trimmed(payload.message))
        }
        guard let schedules = payload.data else {
            throw RealtimeArrivalProviderError.contractViolation("heavy rail data is missing")
        }

        let expectedKey = "\(lineCode)-\(stationCode)"
        guard let schedule = schedules.first(where: {
            $0.key.caseInsensitiveCompare(expectedKey) == .orderedSame
        })?.value else {
            throw RealtimeArrivalProviderError.contractViolation(
                "heavy rail data does not contain \(expectedKey)"
            )
        }

        let directions: [(HeavyRailDirection, [HeavyRailTrain])] = [
            (.up, schedule.up ?? []),
            (.down, schedule.down ?? [])
        ]
        var arrivals: [RealTimeArrival] = []
        for (direction, trains) in directions {
            for train in trains {
                if let valid = trimmed(train.valid?.value), valid.uppercased() != "Y" {
                    continue
                }
                guard let destinationCode = normalizedCode(train.destination.value) else {
                    throw RealtimeArrivalProviderError.contractViolation(
                        "heavy rail \(direction.rawValue) destination is empty"
                    )
                }
                arrivals.append(RealTimeArrival(
                    id: UUID(),
                    lineName: request.lineName,
                    lineColorHex: request.lineColorHex,
                    destination: request.destinationNamesByCode[destinationCode] ?? destinationCode,
                    minutesRemaining: countdownMinutes(train.ttnt.value),
                    timeText: nil,
                    source: .liveCountdown
                ))
            }
        }
        return arrivals
    }

    private static func parseLightRail(
        _ data: Data,
        request: PreparedRequest
    ) throws -> [RealTimeArrival] {
        let payload = try JSONDecoder().decode(LightRailPayload.self, from: data)
        guard payload.status.value == 1 else {
            throw RealtimeArrivalProviderError.serviceUnavailable(trimmed(payload.message))
        }
        guard let platforms = payload.platformList else {
            throw RealtimeArrivalProviderError.contractViolation("Light Rail platform_list is missing")
        }

        var arrivals: [RealTimeArrival] = []
        for platform in platforms {
            for route in platform.routeList {
                // A single unexpected `stop`/`special` value or empty destination on one entry
                // (plausible during unusual service states) should drop just that entry, not
                // discard every other valid platform/route already parsed in this response.
                do {
                    guard route.stop.value == 0 || route.stop.value == 1 else {
                        throw RealtimeArrivalProviderError.contractViolation(
                            "Light Rail stop must be 0 or 1"
                        )
                    }
                    guard route.stop.value == 0 else { continue }
                    guard route.special.value == 0 || route.special.value == 1 else {
                        throw RealtimeArrivalProviderError.contractViolation(
                            "Light Rail special must be 0 or 1"
                        )
                    }

                    guard let destination = lightRailDestination(
                        english: route.destinationEnglish.value,
                        traditionalChinese: route.destinationChinese.value,
                        lookup: request.destinationNamesByCode
                    ) else {
                        throw RealtimeArrivalProviderError.contractViolation(
                            "Light Rail destination is empty"
                        )
                    }
                    let serviceName: String
                    if route.special.value == 1 {
                        serviceName = trimmed(route.additionalInfo1?.value) ?? request.lineName
                    } else {
                        serviceName = trimmed(route.routeNumber.value) ?? request.lineName
                    }
                    let time = lightRailTime(
                        english: route.timeEnglish.value,
                        traditionalChinese: route.timeChinese.value,
                        arrivalDeparture: route.arrivalDeparture.value
                    )
                    arrivals.append(RealTimeArrival(
                        id: UUID(),
                        lineName: serviceName,
                        lineColorHex: request.lineColorHex,
                        destination: destination,
                        minutesRemaining: time.minutes,
                        timeText: time.text,
                        source: .liveCountdown
                    ))
                } catch {
                    AppLog.data.warning("Skipping malformed Light Rail route entry: \(error)")
                }
            }
        }
        return arrivals
    }

    private static func lightRailDestination(
        english: String,
        traditionalChinese: String,
        lookup: [String: String]
    ) -> String? {
        if let englishKey = normalizedCode(english), let destination = lookup[englishKey] {
            return destination
        }
        if let chineseKey = normalizedCode(traditionalChinese), let destination = lookup[chineseKey] {
            return destination
        }
        return trimmed(RealtimeArrivalName(
            english: english,
            traditionalChinese: traditionalChinese
        ).localized)
    }

    private struct ParsedLightRailTime {
        let minutes: Int?
        let text: String?
    }

    private static func lightRailTime(
        english: String,
        traditionalChinese: String,
        arrivalDeparture: String
    ) -> ParsedLightRailTime {
        let english = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let traditionalChinese = traditionalChinese.trimmingCharacters(in: .whitespacesAndNewlines)
        if let minutes = lightRailCountdownMinutes(english) {
            return ParsedLightRailTime(minutes: minutes, text: nil)
        }

        switch english.lowercased() {
        case "arriving":
            return ParsedLightRailTime(
                minutes: nil,
                text: localizedServiceText(
                    english: "Arriving",
                    traditionalChinese: traditionalChinese
                )
            )
        case "departing":
            return ParsedLightRailTime(
                minutes: nil,
                text: localizedServiceText(
                    english: "Departing",
                    traditionalChinese: traditionalChinese
                )
            )
        case "-":
            switch arrivalDeparture.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "A":
                return ParsedLightRailTime(
                    minutes: nil,
                    text: AppLocalization.localized("Arriving")
                )
            case "D":
                return ParsedLightRailTime(
                    minutes: nil,
                    text: AppLocalization.text(
                        english: "Departing",
                        simplified: "正在离开",
                        traditional: "正在離開"
                    )
                )
            default:
                return ParsedLightRailTime(minutes: nil, text: nil)
            }
        case "":
            return ParsedLightRailTime(minutes: nil, text: nil)
        default:
            let localized = RealtimeArrivalName(
                english: english,
                traditionalChinese: traditionalChinese == "-" ? nil : traditionalChinese
            ).localized
            return ParsedLightRailTime(minutes: nil, text: trimmed(localized))
        }
    }

    private static func localizedServiceText(
        english: String,
        traditionalChinese: String
    ) -> String {
        RealtimeArrivalName(
            english: english,
            traditionalChinese: traditionalChinese == "-" ? nil : traditionalChinese
        ).localized
    }

    private static func countdownMinutes(_ rawValue: String) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    private static func lightRailCountdownMinutes(_ rawValue: String) -> Int? {
        let components = rawValue
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        guard components.count == 2,
              let value = Int(components[0]),
              value >= 0,
              ["min", "mins", "minute", "minutes"].contains(String(components[1])) else {
            return nil
        }
        return value
    }

    private static func retryDelay(from response: HTTPURLResponse) -> TimeInterval {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return defaultRetryDelay
        }
        if let seconds = UInt64(rawValue) {
            return TimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let retryDate = formatter.date(from: rawValue) else {
            return defaultRetryDelay
        }
        return max(0, retryDate.timeIntervalSinceNow)
    }

    private static func normalizedCode(_ value: String) -> String? {
        trimmed(value)?.uppercased()
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum HeavyRailDirection: String, Sendable {
    case up = "UP"
    case down = "DOWN"
}

private struct HeavyRailPayload: Decodable {
    let status: FlexibleInt
    let message: String?
    let data: [String: HeavyRailSchedule]?
}

private struct HeavyRailSchedule: Decodable {
    let up: [HeavyRailTrain]?
    let down: [HeavyRailTrain]?

    private enum CodingKeys: String, CodingKey {
        case up = "UP"
        case down = "DOWN"
    }
}

private struct HeavyRailTrain: Decodable {
    let ttnt: FlexibleString
    let valid: FlexibleString?
    let destination: FlexibleString

    private enum CodingKeys: String, CodingKey {
        case ttnt
        case valid
        case destination = "dest"
    }
}

private struct LightRailPayload: Decodable {
    let status: FlexibleInt
    let message: String?
    let platformList: [LightRailPlatform]?

    private enum CodingKeys: String, CodingKey {
        case status
        case message
        case platformList = "platform_list"
    }
}

private struct LightRailPlatform: Decodable {
    let routeList: [LightRailRoute]

    private enum CodingKeys: String, CodingKey {
        case routeList = "route_list"
    }
}

private struct LightRailRoute: Decodable {
    let arrivalDeparture: FlexibleString
    let destinationEnglish: FlexibleString
    let destinationChinese: FlexibleString
    let timeEnglish: FlexibleString
    let timeChinese: FlexibleString
    let routeNumber: FlexibleString
    let stop: FlexibleInt
    let special: FlexibleInt
    let additionalInfo1: FlexibleString?

    private enum CodingKeys: String, CodingKey {
        case arrivalDeparture = "arrival_departure"
        case destinationEnglish = "dest_en"
        case destinationChinese = "dest_ch"
        case timeEnglish = "time_en"
        case timeChinese = "time_ch"
        case routeNumber = "route_no"
        case stop
        case special
        case additionalInfo1
    }
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
            return
        }
        if let value = try? container.decode(Double.self),
           let integer = Int(exactly: value) {
            self.value = integer
            return
        }
        if let rawValue = try? container.decode(String.self),
           let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.value = value
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected an integer or integer string"
        )
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
            return
        }
        if let value = try? container.decode(Int.self) {
            self.value = String(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self.value = Int(exactly: value).map(String.init) ?? String(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a string or number"
        )
    }
}
