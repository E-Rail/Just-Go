import Foundation

enum OfficialStationInformationCategory: String, CaseIterable, Identifiable, Sendable {
    case firstLast
    case exits
    case facilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstLast:
            return AppLocalization.text(
                english: "First / Last",
                simplified: "首末车",
                traditional: "首末班車"
            )
        case .exits:
            return AppLocalization.text(
                english: "Exits",
                simplified: "出入口",
                traditional: "出入口"
            )
        case .facilities:
            return AppLocalization.text(
                english: "Facilities",
                simplified: "设施",
                traditional: "設施"
            )
        }
    }

    func title(for cityID: String) -> String {
        guard self == .firstLast, cityID == "8100" else { return title }
        return AppLocalization.text(
            english: "Trains",
            simplified: "列车",
            traditional: "列車"
        )
    }

    var icon: String {
        switch self {
        case .firstLast: return "clock"
        case .exits: return "door.left.hand.open"
        case .facilities: return "info.circle"
        }
    }
}

enum OfficialStationInformationSource: String, Sendable, Equatable, Codable {
    case beijingSubwayOnline
    case shanghaiMetroOnline
    case guangzhouMetroOnline
    case hangzhouMetroOnline
    case hongKongGovernment

    var title: String {
        switch self {
        case .beijingSubwayOnline:
            return AppLocalization.text(
                english: "Beijing Subway",
                simplified: "北京地铁",
                traditional: "北京地鐵"
            )
        case .shanghaiMetroOnline:
            return AppLocalization.text(
                english: "Shanghai Metro",
                simplified: "上海地铁",
                traditional: "上海地鐵"
            )
        case .guangzhouMetroOnline:
            return AppLocalization.text(
                english: "Guangzhou Metro",
                simplified: "广州地铁",
                traditional: "廣州地鐵"
            )
        case .hangzhouMetroOnline:
            return AppLocalization.text(
                english: "Hangzhou Metro",
                simplified: "杭州地铁",
                traditional: "杭州地鐵"
            )
        case .hongKongGovernment:
            return AppLocalization.text(
                english: "MTR Corporation Limited · DATA.GOV.HK",
                simplified: "港铁公司 · DATA.GOV.HK",
                traditional: "港鐵公司 · DATA.GOV.HK"
            )
        }
    }

}

/// One direction of travel from this station: the service window a rider sees on the platform
/// sign, plus a live countdown where an operator publishes one.
struct OfficialStationServiceInformation: Identifiable, Sendable, Equatable, Codable {
    /// The direction marker a rider reads on the platform sign. Names *a* way, not necessarily
    /// where this particular train ends.
    let direction: String
    /// Where this individual service terminates, when the operator distinguishes it from the
    /// direction marker. At 国贸 every northbound 10号线 row shares `terminalStationName = 双井` while
    /// `destStationName` separates 车道沟, 成寿寺 and 巴沟: three services, three last trains. Optional so
    /// sources with one name, and older device caches, decode.
    let destination: String?
    let firstTrain: String?
    let lastTrain: String?
    let liveTime: String?

    init(
        direction: String,
        destination: String? = nil,
        firstTrain: String?,
        lastTrain: String?,
        liveTime: String?
    ) {
        self.direction = direction
        self.destination = destination
        self.firstTrain = firstTrain
        self.lastTrain = lastTrain
        self.liveTime = liveTime
    }

    /// Positional, not `compactMap`-ed, so `(first: "5:27", last: nil)` and `(first: nil, last:
    /// "5:27")` stay distinct ids and `uniqued(by:)` keeps both rows.
    var id: String {
        [direction, destination ?? "", firstTrain ?? "", lastTrain ?? "", liveTime ?? ""]
            .joined(separator: "|")
    }
}

/// Services grouped under the line that runs them, so a consumer of the published payload reads one
/// line's whole picture without regrouping, and the line's colour is stated once.
struct OfficialStationLineInformation: Identifiable, Sendable, Equatable, Codable {
    let lineName: String
    let lineColorHex: String?
    let services: [OfficialStationServiceInformation]

    var id: String { lineName }
}

struct OfficialStationExitInformation: Identifiable, Sendable, Equatable, Codable {
    let name: String
    let details: [String]
    let isAccessible: Bool?

    var id: String { "\(name)|\(details.joined(separator: "|"))" }
}

enum OfficialStationFacilityAvailability: String, Sendable, Equatable, Codable {
    case available
    case unavailable
}

struct OfficialStationFacilityInformation: Identifiable, Sendable, Equatable, Codable {
    let name: String
    let location: String?
    let availability: OfficialStationFacilityAvailability?

    var id: String { "\(name)|\(location ?? "")|\(String(describing: availability))" }
}

struct OfficialStationFacilityGroup: Identifiable, Sendable, Equatable, Codable {
    let name: String
    let items: [OfficialStationFacilityInformation]

    var id: String { name }
}

/// Whether a snapshot came from the official service or from this device's last-good copy while the
/// service was unreachable. Encoded as `{"state": "live"}` / `{"state": "cached", "fetchedAt":
/// "…"}`, not Swift's synthesised shape: this type is part of a published interchange contract
/// (`DataPacks/STATION_INFORMATION_SCHEMA.md`).
enum OfficialStationInformationFreshness: Sendable, Equatable, Codable {
    case live
    case cached(fetchedAt: Date)

    private enum CodingKeys: String, CodingKey {
        case state
        case fetchedAt
    }

    private enum State: String, Codable {
        case live
        case cached
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .live:
            try container.encode(State.live, forKey: .state)
        case .cached(let fetchedAt):
            try container.encode(State.cached, forKey: .state)
            try container.encode(fetchedAt, forKey: .fetchedAt)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .live:
            self = .live
        case .cached:
            self = .cached(fetchedAt: try container.decode(Date.self, forKey: .fetchedAt))
        }
    }
}

struct OfficialStationInformationSnapshot: Sendable, Equatable, Codable {
    let stationID: String
    let stationName: String
    let source: OfficialStationInformationSource
    let freshness: OfficialStationInformationFreshness
    /// Which service day these times describe, in the source's own words, when it says: Hangzhou's
    /// payload is titled `工作日时刻表`, the weekday timetable. Optional because only Hangzhou publishes
    /// one and older caches must decode.
    let serviceDayNote: String?
    let lines: [OfficialStationLineInformation]
    let exits: [OfficialStationExitInformation]
    let facilityGroups: [OfficialStationFacilityGroup]

    init(
        stationID: String,
        stationName: String,
        source: OfficialStationInformationSource,
        freshness: OfficialStationInformationFreshness,
        serviceDayNote: String? = nil,
        lines: [OfficialStationLineInformation],
        exits: [OfficialStationExitInformation],
        facilityGroups: [OfficialStationFacilityGroup]
    ) {
        self.stationID = stationID
        self.stationName = stationName
        self.source = source
        self.freshness = freshness
        self.serviceDayNote = serviceDayNote
        self.lines = lines
        self.exits = exits
        self.facilityGroups = facilityGroups
    }

    func withFreshness(_ freshness: OfficialStationInformationFreshness) -> OfficialStationInformationSnapshot {
        OfficialStationInformationSnapshot(
            stationID: stationID,
            stationName: stationName,
            source: source,
            freshness: freshness,
            serviceDayNote: serviceDayNote,
            lines: lines,
            exits: exits,
            facilityGroups: facilityGroups
        )
    }
}

/// Device-only persistence for last-good station-information snapshots. Implemented outside
/// this file (`OfficialStationInformationDiskCache`) so the provider itself stays free of
/// storage APIs; the runtime data policy validates both files separately.
protocol OfficialStationInformationCaching: Sendable {
    func storedSnapshot(
        cityID: String,
        stationID: String,
        externalStationID: String
    ) async -> (snapshot: OfficialStationInformationSnapshot, fetchedAt: Date)?
    func store(
        _ snapshot: OfficialStationInformationSnapshot,
        cityID: String,
        externalStationID: String
    ) async
    func clearAll() async
}

enum OfficialStationInformationReference: Hashable, Sendable {
    case beijing(externalStationID: String, expectedNames: [String])
    /// Shanghai keys station information per line, so the reference carries every line key the
    /// station serves (from the bundled directory), not a single ID.
    case shanghai(lineStationIDs: [String], expectedNames: [String])
    /// Guangzhou's serviceTime endpoint returns every line for a physical station from any one of
    /// its per-line codes, so the reference carries a single representative stationShowCode.
    case guangzhou(stationShowCode: String, expectedNames: [String])
    /// Hangzhou returns the whole network at once, so the reference carries every code the operator
    /// publishes for this station: usually one, but 火车东站 is split into a main-hall and an
    /// east-plaza record.
    case hangzhou(stationCodes: [String], expectedNames: [String])
}

struct OfficialStationInformationRequest: Hashable, Sendable {
    let stationID: String
    let reference: OfficialStationInformationReference
}

protocol OfficialStationInformationProviding: Sendable {
    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot
}

enum OfficialStationInformationProviderError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case timedOut
    case transport(String)
    case invalidResponse
    case responseTooLarge
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case serviceUnavailable(String?)
    case contractViolation(String)

    /// Transient failures worth another attempt before the rider sees an error: a cold first
    /// request after launch can time out or reset on the DNS/TLS handshake while the endpoint is
    /// reachable. Permanent failures and rate limiting, which carries its own backoff, are never
    /// retried.
    var isRetryable: Bool {
        switch self {
        case .timedOut, .transport, .serviceUnavailable:
            return true
        case .httpStatus(let code):
            return (500...599).contains(code)
        case .rateLimited, .invalidRequest, .invalidResponse, .responseTooLarge, .contractViolation:
            return false
        }
    }

    /// Whether a failure may be answered from the copy this device stored earlier. An availability
    /// failure gets the cached answer, labelled as cached; a rejected request or a contract
    /// violation never does, because a stored copy must not paper over a response that no longer
    /// means what the app thinks. Non-provider errors, cancellation above all, propagate untouched.
    var allowsStoredFallback: Bool {
        switch self {
        case .timedOut, .transport, .invalidResponse, .responseTooLarge,
             .rateLimited, .httpStatus, .serviceUnavailable:
            return true
        case .invalidRequest, .contractViolation:
            return false
        }
    }
}

/// The small parsers every operator provider needs: what an operator's field means, not how any
/// one operator's API is shaped, which stays in each provider.
enum OperatorFieldParsing {
    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// What operators write where they have no value, including "终点站" where a direction ends at
    /// this station and so has no departure to show.
    static let placeholders: Set<String> = [
        "--", "-", "/", "／", "—", "——", "n/a", "na", "none", "null",
        "无", "沒有", "没有", "暫無", "暂无", "终点站", "終點站"
    ]

    /// Nil for a value that only looks like data.
    static func placeholderAware(_ value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        return placeholders.contains(value.lowercased()) ? nil : value
    }

    /// "23:45" as minutes into the service day, with after-midnight hours carried past 24:00 so a
    /// last train at 00:30 sorts after one at 23:50 rather than before it.
    static func serviceMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else { return nil }
        return (hour < 4 ? hour + 24 : hour) * 60 + minute
    }

    static func preferredServiceTime(_ lhs: String?, _ rhs: String?, earliest: Bool) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        // An unparseable time keeps the side we can reason about rather than winning by accident.
        guard let lhsMinutes = serviceMinutes(lhs) else { return rhs }
        guard let rhsMinutes = serviceMinutes(rhs) else { return lhs }
        let preferLhs = earliest ? lhsMinutes <= rhsMinutes : lhsMinutes >= rhsMinutes
        return preferLhs ? lhs : rhs
    }

    /// A station name reduced to what two spellings of it have in common: case, width and accents
    /// folded away, everything that is not a letter or digit dropped.
    static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    static func isReviewedName(_ name: String, in expectedNames: [String]) -> Bool {
        expectedNames.map(normalizedName).contains(normalizedName(name))
    }

    /// `#RRGGBB`, from a colour with or without `#` and with an alpha byte (Guangzhou) dropped.
    static func hexColor(_ value: String?) -> String? {
        guard let raw = trimmed(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "#")) else { return nil }
        let hex = raw.count == 8 ? String(raw.prefix(6)) : raw
        guard hex.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else { return nil }
        return "#\(hex.uppercased())"
    }

    /// The request's station ID and the reviewed names a response must carry. Both are required:
    /// without them a response cannot be checked against the station the rider asked about.
    static func reviewedIdentity(
        of request: OfficialStationInformationRequest,
        names: [String]
    ) throws -> (stationID: String, expectedNames: [String]) {
        guard let stationID = trimmed(request.stationID) else {
            throw OfficialStationInformationProviderError.invalidRequest("stationID is empty")
        }
        let expectedNames = names.compactMap(trimmed).uniqued().sorted()
        guard !expectedNames.isEmpty else {
            throw OfficialStationInformationProviderError.invalidRequest("expected station names are empty")
        }
        return (stationID, expectedNames)
    }
}

/// Follows a redirect only back to the same operator, over https: an endpoint that redirects off
/// its own host is not answering for that operator any more.
final class OperatorRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String

    init(host: String) {
        self.host = host.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// How every operator provider talks to its operator.
enum OperatorHTTP {
    /// Ephemeral and cookie-free: operator content is fetched for this rider, now, and nothing about
    /// the exchange is kept by the URL system. The app's own caches decide what is kept.
    static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    /// One request to an operator's own endpoint: the body, or the provider error that says why not.
    ///
    /// The response has to still be https on `host` (and `path`, when given) after redirects, 2xx,
    /// within `maximumBytes`, and JSON when `requiresJSON`; a 429 carries its Retry-After. Raced
    /// against `timeout`, because the session's own timeout only fires when no bytes arrive and a
    /// connection that trickles never trips it. `data(for:)` rather than `bytes(for:)`, whose
    /// one-byte-per-iteration loop measured 0.09 MB/s and timed out on the read alone.
    static func data(
        for request: URLRequest,
        host: String,
        path: String? = nil,
        maximumBytes: Int,
        requiresJSON: Bool = false,
        timeout: TimeInterval,
        using session: URLSession
    ) async throws -> Data {
        try await withDeadline(seconds: timeout, onTimeout: { OfficialStationInformationProviderError.timedOut }) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request, delegate: OperatorRedirectDelegate(host: host))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                throw OfficialStationInformationProviderError.timedOut
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            } catch {
                throw OfficialStationInformationProviderError.transport(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse,
                  http.url?.scheme?.lowercased() == "https",
                  http.url?.host?.lowercased() == host,
                  path == nil || http.url?.path == path else {
                throw OfficialStationInformationProviderError.invalidResponse
            }
            if http.statusCode == 429 {
                throw OfficialStationInformationProviderError.rateLimited(retryAfter: retryAfterDelay(from: http))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OfficialStationInformationProviderError.httpStatus(http.statusCode)
            }
            // The declared length rejects an honest oversize body before it is read; the count
            // catches a server that lies about it.
            guard http.expectedContentLength <= Int64(maximumBytes), data.count <= maximumBytes else {
                throw OfficialStationInformationProviderError.responseTooLarge
            }
            if requiresJSON, http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") != true {
                throw OfficialStationInformationProviderError.invalidResponse
            }
            return data
        }
    }

    /// Retry-After as seconds, whether the header is a number or an HTTP date.
    static func retryAfterDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = OperatorFieldParsing.trimmed(response.value(forHTTPHeaderField: "Retry-After")) else {
            return nil
        }
        if let seconds = TimeInterval(rawValue), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: rawValue) else { return nil }
        return max(date.timeIntervalSinceNow, 0)
    }
}

/// Operator answers kept in memory for half an hour, one fetch per key however many callers arrive
/// together, and a hold-off after the operator answers 429.
///
/// The fetch runs in an unstructured task, so a caller that stops waiting (the planner's deadline)
/// leaves the answer to land here for the next caller instead of cancelling a request already paid
/// for. Nothing here touches storage: the device-only copy is `OfficialStationInformationCaching`.
actor OperatorAnswerCache<Key: Hashable & Sendable, Value: Sendable> {
    private let cacheLifetime: TimeInterval = 1800
    private let defaultRateLimitBackoff: TimeInterval = 30
    private let clock = ContinuousClock()
    private var entries: [Key: (value: Value, expiresAt: ContinuousClock.Instant)] = [:]
    private var inFlight: [Key: (token: UUID, task: Task<Value, Error>)] = [:]
    private var rateLimitedUntil: ContinuousClock.Instant?

    func value(for key: Key, fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let now = clock.now
        entries = entries.filter { $0.value.expiresAt > now }
        if let entry = entries[key] { return entry.value }
        if let rateLimitedUntil, rateLimitedUntil > now {
            throw OfficialStationInformationProviderError.rateLimited(retryAfter: nil)
        }
        let active: (token: UUID, task: Task<Value, Error>)
        if let existing = inFlight[key] {
            active = existing
        } else {
            active = (UUID(), Task { try await fetch() })
            inFlight[key] = active
        }
        do {
            let value = try await active.task.value
            if inFlight[key]?.token == active.token {
                inFlight[key] = nil
                entries[key] = (value, clock.now.advanced(by: .seconds(cacheLifetime)))
            }
            return value
        } catch {
            if inFlight[key]?.token == active.token { inFlight[key] = nil }
            if case .rateLimited(let retryAfter)? = error as? OfficialStationInformationProviderError {
                let until = clock.now.advanced(by: .seconds(max(retryAfter ?? defaultRateLimitBackoff, 1)))
                rateLimitedUntil = max(rateLimitedUntil ?? until, until)
            }
            throw error
        }
    }

    func releaseMemory() {
        entries.removeAll(keepingCapacity: false)
    }
}

extension OperatorAnswerCache where Value == OfficialStationInformationSnapshot {
    /// One station's answer: cached and shared as above, stored to the device after each real
    /// fetch, and replaced by that stored copy when the failure allows it.
    func snapshot(
        for key: Key,
        cityID: String,
        stationID: String,
        externalStationID: String,
        diskCache: (any OfficialStationInformationCaching)?,
        fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await value(for: key) {
                let snapshot = try await fetch()
                if let diskCache {
                    Task { await diskCache.store(snapshot, cityID: cityID, externalStationID: externalStationID) }
                }
                return snapshot
            }
        } catch {
            return try await storedSnapshot(
                replacing: error,
                from: diskCache,
                cityID: cityID,
                stationID: stationID,
                externalStationID: externalStationID
            )
        }
    }
}

/// The copy this device stored earlier, labelled as cached, when `error` allows one
/// (`allowsStoredFallback`); otherwise `error` itself.
func storedSnapshot(
    replacing error: Error,
    from diskCache: (any OfficialStationInformationCaching)?,
    cityID: String,
    stationID: String,
    externalStationID: String
) async throws -> OfficialStationInformationSnapshot {
    guard (error as? OfficialStationInformationProviderError)?.allowsStoredFallback == true,
          let diskCache,
          let stored = await diskCache.storedSnapshot(
              cityID: cityID,
              stationID: stationID,
              externalStationID: externalStationID
          ) else {
        throw error
    }
    return stored.snapshot.withFreshness(.cached(fetchedAt: stored.fetchedAt))
}

actor BeijingStationInformationProvider: OfficialStationInformationProviding {
    static let cityID = "1100"
    fileprivate static let host = "www.bjsubway.com"
    private static let endpointPath = "/api/guanwang/v2/getStationDetail"
    private static let maximumResponseBytes = 1_048_576
    private static let requestTimeout: TimeInterval = 5

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let externalStationID: String
        let expectedNames: [String]
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private let answers = OperatorAnswerCache<PreparedRequest, OfficialStationInformationSnapshot>()

    init(session: URLSession? = nil, diskCache: (any OfficialStationInformationCaching)? = nil) {
        self.session = session ?? OperatorHTTP.session(timeout: Self.requestTimeout)
        self.diskCache = diskCache
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        let prepared = try Self.prepare(request)
        let session = self.session
        return try await answers.snapshot(
            for: prepared,
            cityID: Self.cityID,
            stationID: prepared.stationID,
            externalStationID: prepared.externalStationID,
            diskCache: diskCache
        ) {
            try await Self.fetch(prepared, using: session)
        }
    }

    func releaseMemory() async {
        await answers.releaseMemory()
    }

    private static func prepare(_ request: OfficialStationInformationRequest) throws -> PreparedRequest {
        guard case .beijing(let externalStationID, let names) = request.reference,
              let externalID = OperatorFieldParsing.trimmed(externalStationID),
              externalID.range(of: #"^\d{9}$"#, options: .regularExpression) != nil else {
            throw OfficialStationInformationProviderError.invalidRequest(
                "Beijing station reference is not a reviewed nine-digit ID"
            )
        }
        let identity = try OperatorFieldParsing.reviewedIdentity(of: request, names: names)
        return PreparedRequest(
            stationID: identity.stationID,
            externalStationID: externalID,
            expectedNames: identity.expectedNames
        )
    }

    private static func fetch(
        _ request: PreparedRequest,
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = endpointPath
        components.queryItems = [
            URLQueryItem(name: "accLocation", value: request.externalStationID)
        ]
        guard let url = components.url else {
            throw OfficialStationInformationProviderError.invalidRequest("official station reference is invalid")
        }
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await OperatorHTTP.data(
            for: urlRequest,
            host: host,
            path: endpointPath,
            maximumBytes: maximumResponseBytes,
            requiresJSON: true,
            timeout: requestTimeout,
            using: session
        )

        let payload: BeijingPayload
        do {
            payload = try JSONDecoder().decode(BeijingPayload.self, from: data)
        } catch {
            throw OfficialStationInformationProviderError.contractViolation("response is not valid station JSON")
        }
        guard payload.status == 200 else {
            throw OfficialStationInformationProviderError.serviceUnavailable(OperatorFieldParsing.trimmed(payload.message))
        }
        guard let responseData = payload.data,
              let station = responseData.station,
              station.stationDeviceLocation == request.externalStationID,
              let stationName = OperatorFieldParsing.trimmed(station.stationName) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station identity is missing or does not match the reviewed reference"
            )
        }
        guard OperatorFieldParsing.isReviewedName(stationName, in: request.expectedNames) else {
            throw OfficialStationInformationProviderError.contractViolation("station name does not match the reviewed catalog")
        }

        let exits = (station.exits ?? []).compactMap { exit in
            guard let name = OperatorFieldParsing.trimmed(exit.name) else { return nil }
            return OfficialStationExitInformation(
                name: name,
                details: (exit.nearby ?? []).compactMap(OperatorFieldParsing.trimmed).uniqued(),
                isAccessible: nil
            )
        }.uniqued(by: \OfficialStationExitInformation.id)

        let facilityGroups = (station.facilitys ?? []).compactMap { group in
            guard let groupName = OperatorFieldParsing.trimmed(group.name) else { return nil }
            let items = (group.data ?? []).compactMap { item in
                guard let name = OperatorFieldParsing.trimmed(item.name),
                      let rawDetail = OperatorFieldParsing.trimmed(item.contentDesc) else { return nil }
                let unavailable = OperatorFieldParsing.placeholderAware(rawDetail) == nil
                return OfficialStationFacilityInformation(
                    name: name,
                    location: unavailable ? nil : rawDetail,
                    availability: unavailable ? OfficialStationFacilityAvailability.unavailable : .available
                )
            }.uniqued(by: \OfficialStationFacilityInformation.id)
            guard !items.isEmpty else { return nil }
            return OfficialStationFacilityGroup(name: groupName, items: items)
        }.uniqued(by: \OfficialStationFacilityGroup.id)

        return OfficialStationInformationSnapshot(
            stationID: request.stationID,
            stationName: stationName,
            source: .beijingSubwayOnline,
            freshness: .live,
            lines: groupedLines(responseData.lines ?? []),
            exits: exits,
            facilityGroups: facilityGroups
        )
    }

    /// Beijing returns one record per *service*: `terminalStationName` is a direction marker (the
    /// next station that way), `destStationName` the service's terminus. The group key is the pair.
    /// At 国贸 the three northbound 10号线 records share `terminalStationName = 双井`:
    ///
    ///     → 车道沟  5:18 – 21:28      → 成寿寺  5:18 – 23:36      → 巴沟  5:18 – 23:12
    ///
    /// Grouped by direction alone that is 5:18 – 23:36, a last train that turns back seventeen
    /// stops before 车道沟. `ServiceHoursResolver.servingWindows` picks the service that reaches the
    /// rider's stop, and needs the services apart. Records with the same direction and terminus
    /// still collapse into one window.
    private static func groupedLines(_ lines: [BeijingLine]) -> [OfficialStationLineInformation] {
        struct ServiceKey: Hashable {
            let direction: String
            let destination: String
        }
        var lineOrder: [String] = []
        var colors: [String: String] = [:]
        var serviceOrder: [String: [ServiceKey]] = [:]
        var services: [String: [ServiceKey: OfficialStationServiceInformation]] = [:]

        for line in lines {
            guard let lineName = OperatorFieldParsing.trimmed(line.lineName),
                  let direction = OperatorFieldParsing.trimmed(line.terminalStationName)
                    ?? OperatorFieldParsing.trimmed(line.destStationName) else { continue }
            let first = OperatorFieldParsing.trimmed(line.firstTime)
            let last = OperatorFieldParsing.trimmed(line.lastTime)
            guard first != nil || last != nil else { continue }
            let destination = OperatorFieldParsing.trimmed(line.destStationName) ?? direction
            let key = ServiceKey(direction: direction, destination: destination)

            if services[lineName] == nil {
                lineOrder.append(lineName)
                services[lineName] = [:]
                serviceOrder[lineName] = []
            }
            if colors[lineName] == nil, let color = OperatorFieldParsing.hexColor(line.lineColor) {
                colors[lineName] = color
            }

            guard let existing = services[lineName]?[key] else {
                serviceOrder[lineName]?.append(key)
                services[lineName]?[key] = OfficialStationServiceInformation(
                    direction: direction,
                    destination: destination,
                    firstTrain: first,
                    lastTrain: last,
                    liveTime: nil
                )
                continue
            }
            services[lineName]?[key] = OfficialStationServiceInformation(
                direction: existing.direction,
                destination: existing.destination,
                firstTrain: OperatorFieldParsing.preferredServiceTime(existing.firstTrain, first, earliest: true),
                lastTrain: OperatorFieldParsing.preferredServiceTime(existing.lastTrain, last, earliest: false),
                liveTime: nil
            )
        }

        return lineOrder.map { lineName in
            OfficialStationLineInformation(
                lineName: lineName,
                lineColorHex: colors[lineName],
                services: (serviceOrder[lineName] ?? []).compactMap { services[lineName]?[$0] }
            )
        }
    }
}

private struct BeijingPayload: Decodable {
    let status: Int
    let message: String?
    let data: BeijingResponseData?

    private enum CodingKeys: String, CodingKey {
        case status
        case message
        case data
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(FlexibleInt.self, forKey: .status).value
        message = try values.decodeIfPresent(String.self, forKey: .message)
        data = try? values.decodeIfPresent(BeijingResponseData.self, forKey: .data)
    }
}

private struct BeijingResponseData: Decodable {
    let lines: [BeijingLine]?
    let station: BeijingStation?
}

private struct BeijingLine: Decodable {
    let lineName: String?
    let lineColor: String?
    let firstTime: String?
    let lastTime: String?
    let terminalStationName: String?
    let destStationName: String?
}

private struct BeijingStation: Decodable {
    let stationName: String?
    let stationDeviceLocation: String?
    let facilitys: [BeijingFacilityGroup]?
    let exits: [BeijingExit]?

    private enum CodingKeys: String, CodingKey {
        case stationName
        case stationDeviceLocation
        case facilitys
        case exits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stationName = try values.decodeIfPresent(String.self, forKey: .stationName)
        stationDeviceLocation = try values
            .decodeIfPresent(FlexibleString.self, forKey: .stationDeviceLocation)?
            .value
        facilitys = try? values.decodeIfPresent([BeijingFacilityGroup].self, forKey: .facilitys)
        exits = try? values.decodeIfPresent([BeijingExit].self, forKey: .exits)
    }
}

private struct BeijingFacilityGroup: Decodable {
    let name: String?
    let data: [BeijingFacility]?
}

private struct BeijingFacility: Decodable {
    let name: String?
    let contentDesc: String?
}

private struct BeijingExit: Decodable {
    let name: String?
    let nearby: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case nearby
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        nearby = try? values.decodeIfPresent([String].self, forKey: .nearby)
    }
}

/// An integer an operator may send as a number or as a string.
struct FlexibleInt: Decodable {
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

/// A string an operator may send as a number.
struct FlexibleString: Decodable {
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

/// One operating notice as the operator published it: headline, date, page. Nothing summarised,
/// ranked or reworded.
struct OperatorServiceNotice: Identifiable, Sendable, Equatable {
    let title: String
    /// As published, `YYYY-MM-DD`, shown verbatim so a stale feed is visibly stale.
    let publishedOn: String
    let url: URL

    var id: String { url.absoluteString }
}

/// Fetches Beijing Subway's 运营信息 notices from the operator's site, on the rider's device. The
/// content is `LicenseRef-External-Link-Only`: fetched at runtime, held in memory only, never
/// committed or redistributed.
///
/// **Not a live advisory feed, and must not be presented as one.** Beijing publishes here
/// irregularly, so every notice carries its publication date and the UI shows it.
actor BeijingServiceNoticeProvider {
    static let cityID = "1100"
    private static let host = "www.bjsubway.com"
    private static let listPath = "/news/qyxw/yyzd/"
    private static let maximumResponseBytes = 512_000
    private static let requestTimeout: TimeInterval = 5
    private static let cacheLifetime: TimeInterval = 1800
    private static let clock = ContinuousClock()

    private var cached: [OperatorServiceNotice] = []
    private var cachedAt: ContinuousClock.Instant?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func notices(limit: Int = 3) async throws -> [OperatorServiceNotice] {
        if let cachedAt, Self.clock.now - cachedAt < .seconds(Self.cacheLifetime) {
            return Array(cached.prefix(limit))
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = Self.listPath
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              // A redirect off this host would mean fetching operator content from somewhere the
              // rights statement says nothing about.
              http.url?.host?.lowercased() == Self.host,
              data.count <= Self.maximumResponseBytes else { return [] }

        // The site is GB18030, declared in a meta tag rather than the HTTP header, so decoding as
        // UTF-8 silently yields mojibake instead of failing.
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        guard let html = String(data: data, encoding: String.Encoding(rawValue: encoding))
            ?? String(data: data, encoding: .utf8) else { return [] }

        let parsed = Self.parse(html: html)
        cached = parsed
        cachedAt = Self.clock.now
        return Array(parsed.prefix(limit))
    }

    /// Pulls `<a href="/news/qyxw/yyzd/2026-05-16/129685.html">标题2026-05-16</a>` rows out of the
    /// listing. The date comes from the path: the link text runs title and date together.
    nonisolated static func parse(html: String) -> [OperatorServiceNotice] {
        let pattern = #"<a[^>]+href="(/news/qyxw/yyzd/(\d{4}-\d{2}-\d{2})/\d+\.html)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<String>()
        var notices: [OperatorServiceNotice] = []
        for match in regex.matches(in: html, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: html),
                  let dateRange = Range(match.range(at: 2), in: html),
                  let textRange = Range(match.range(at: 3), in: html) else { continue }
            let path = String(html[pathRange])
            let published = String(html[dateRange])
            var title = String(html[textRange])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The anchor text ends with the same date it links to; it is shown separately.
            if title.hasSuffix(published) { title = String(title.dropLast(published.count)) }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)

            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            guard !title.isEmpty, let url = components.url, seen.insert(path).inserted else { continue }
            notices.append(OperatorServiceNotice(title: title, publishedOn: published, url: url))
        }
        // Newest first regardless of the page's own ordering.
        return notices.sorted { $0.publishedOn > $1.publishedOn }
    }

    func releaseMemory() {
        cached = []
        cachedAt = nil
    }
}
