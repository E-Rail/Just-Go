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
    let direction: String
    let firstTrain: String?
    let lastTrain: String?
    let liveTime: String?

    /// Positional, not `compactMap`-ed: dropping nils before joining made
    /// `(first: "5:27", last: nil)` and `(first: nil, last: "5:27")` collide on one id, and the
    /// `uniqued(by:)` at the call sites then silently deleted the second row.
    var id: String {
        [direction, firstTrain ?? "", lastTrain ?? "", liveTime ?? ""].joined(separator: "|")
    }
}

/// Services grouped under the line that runs them. Nesting rather than repeating `lineName` on
/// every row is what makes the payload usable by anyone other than this app: a consumer reads one
/// line's whole service picture without regrouping a flat list, and the line's colour is stated
/// once instead of once per direction.
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

/// Whether a snapshot came straight from the official service or from this device's own
/// last-good copy served while the service was unreachable.
/// Encoded as `{"state": "live"}` / `{"state": "cached", "fetchedAt": "…"}` rather than the
/// synthesised `{"live": {}}` / `{"cached": {"fetchedAt": …}}`: this type is part of a published
/// interchange contract (`DataPacks/STATION_INFORMATION_SCHEMA.md`), and a payload keyed by its
/// own case name is not something another implementation can reasonably produce.
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
    let lines: [OfficialStationLineInformation]
    let exits: [OfficialStationExitInformation]
    let facilityGroups: [OfficialStationFacilityGroup]

    func withFreshness(_ freshness: OfficialStationInformationFreshness) -> OfficialStationInformationSnapshot {
        OfficialStationInformationSnapshot(
            stationID: stationID,
            stationName: stationName,
            source: source,
            freshness: freshness,
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
}

private final class BeijingStationInformationRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == BeijingStationInformationProvider.host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor BeijingStationInformationProvider: OfficialStationInformationProviding {
    /// Cities whose station accessibility/facility facts come from this official online
    /// surface rather than the bundled pack — coverage UI uses this to avoid claiming the
    /// data doesn't exist while every station page renders it.
    static func servesStationInformation(forCityID cityID: String) -> Bool {
        cityID == "1100"
    }

    static let cityID = "1100"
    fileprivate static let host = "www.bjsubway.com"
    private static let endpointPath = "/api/guanwang/v2/getStationDetail"
    private static let maximumResponseBytes = 1_048_576
    private static let requestTimeout: TimeInterval = 5
    // First/last trains, exits, and facilities change rarely; a longer in-session cache
    // keeps station re-visits instant instead of re-fetching every few minutes. The provider
    // itself never touches storage APIs — the injected `diskCache` (a separate file with its
    // own validate_runtime_data_policy.rb rules) keeps a device-only last-good snapshot that
    // is served, clearly labeled as cached, only when the official service is unreachable.
    private static let cacheLifetime: TimeInterval = 1800
    private static let defaultRateLimitBackoff: TimeInterval = 30
    private static let clock = ContinuousClock()

    private struct CacheEntry: Sendable {
        let snapshot: OfficialStationInformationSnapshot
        let expiresAt: ContinuousClock.Instant
    }

    private struct InFlightRequest: Sendable {
        let token: UUID
        let task: Task<OfficialStationInformationSnapshot, Error>
    }

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let externalStationID: String
        let expectedNames: [String]
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private var cache: [PreparedRequest: CacheEntry] = [:]
    private var inFlight: [PreparedRequest: InFlightRequest] = [:]
    private var rateLimitedUntil: ContinuousClock.Instant?

    init(session: URLSession? = nil, diskCache: (any OfficialStationInformationCaching)? = nil) {
        self.diskCache = diskCache
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        let prepared = try Self.prepare(request)
        let now = Self.clock.now

        // Entries otherwise only leave `cache` when that same station is looked up again after
        // expiring — over a session visiting many distinct stations it only ever shrinks on an
        // OS memory warning. Sweep proactively; bounded by the reviewed station count, so this
        // is cheap even every call.
        if !cache.isEmpty {
            cache = cache.filter { $0.value.expiresAt > now }
        }

        if let cached = cache[prepared] {
            if cached.expiresAt > now {
                return cached.snapshot
            }
            cache.removeValue(forKey: prepared)
        }

        if let rateLimitedUntil {
            guard rateLimitedUntil <= now else {
                return try await servingStoredSnapshot(
                    for: prepared,
                    insteadOf: OfficialStationInformationProviderError.rateLimited(retryAfter: nil)
                )
            }
            self.rateLimitedUntil = nil
        }

        if let active = inFlight[prepared] {
            return try await finish(active, for: prepared)
        }

        let token = UUID()
        let session = self.session
        let task = Task<OfficialStationInformationSnapshot, Error> {
            try await Self.fetch(prepared, using: session)
        }
        let active = InFlightRequest(token: token, task: task)
        inFlight[prepared] = active
        return try await finish(active, for: prepared)
    }

    func releaseMemory() {
        cache.removeAll(keepingCapacity: false)
    }

    private func finish(
        _ active: InFlightRequest,
        for request: PreparedRequest
    ) async throws -> OfficialStationInformationSnapshot {
        do {
            let snapshot = try await active.task.value
            if inFlight[request]?.token == active.token {
                inFlight.removeValue(forKey: request)
                cache[request] = CacheEntry(
                    snapshot: snapshot,
                    expiresAt: Self.clock.now.advanced(by: .seconds(Self.cacheLifetime))
                )
                if let diskCache {
                    let externalStationID = request.externalStationID
                    Task { await diskCache.store(snapshot, cityID: Self.cityID, externalStationID: externalStationID) }
                }
            }
            return snapshot
        } catch {
            if inFlight[request]?.token == active.token {
                inFlight.removeValue(forKey: request)
            }
            if let providerError = error as? OfficialStationInformationProviderError,
               case .rateLimited(let retryAfter) = providerError {
                let duration = max(retryAfter ?? Self.defaultRateLimitBackoff, 1)
                let candidate = Self.clock.now.advanced(by: .seconds(duration))
                if let current = rateLimitedUntil {
                    rateLimitedUntil = max(current, candidate)
                } else {
                    rateLimitedUntil = candidate
                }
            }
            return try await servingStoredSnapshot(for: request, insteadOf: error)
        }
    }

    /// Availability failures fall back to the last snapshot this device stored, labeled as
    /// cached. Caller and contract errors never do — a stored copy must not paper over a
    /// station-identity mismatch or a malformed request.
    private func servingStoredSnapshot(
        for request: PreparedRequest,
        insteadOf error: Error
    ) async throws -> OfficialStationInformationSnapshot {
        guard Self.allowsStoredFallback(error),
              let diskCache,
              let stored = await diskCache.storedSnapshot(
                  cityID: Self.cityID,
                  stationID: request.stationID,
                  externalStationID: request.externalStationID
              ) else {
            throw error
        }
        return stored.snapshot.withFreshness(.cached(fetchedAt: stored.fetchedAt))
    }

    private static func allowsStoredFallback(_ error: Error) -> Bool {
        guard let providerError = error as? OfficialStationInformationProviderError else {
            // Cancellation (and anything else non-provider) propagates untouched.
            return false
        }
        switch providerError {
        case .timedOut, .transport, .invalidResponse, .responseTooLarge,
             .rateLimited, .httpStatus, .serviceUnavailable:
            return true
        case .invalidRequest, .contractViolation:
            return false
        }
    }

    private static func prepare(
        _ request: OfficialStationInformationRequest
    ) throws -> PreparedRequest {
        let stationID = request.stationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stationID.isEmpty else {
            throw OfficialStationInformationProviderError.invalidRequest("stationID is empty")
        }

        switch request.reference {
        case .beijing(let externalStationID, let expectedNames):
            let externalID = externalStationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard externalID.range(of: #"^\d{9}$"#, options: .regularExpression) != nil else {
                throw OfficialStationInformationProviderError.invalidRequest(
                    "Beijing station reference is not a reviewed nine-digit ID"
                )
            }
            let names = expectedNames
                .compactMap(trimmed)
                .uniqued()
                .sorted()
            guard !names.isEmpty else {
                throw OfficialStationInformationProviderError.invalidRequest(
                    "expected station names are empty"
                )
            }
            return PreparedRequest(
                stationID: stationID,
                externalStationID: externalID,
                expectedNames: names
            )
        case .shanghai:
            throw OfficialStationInformationProviderError.invalidRequest(
                "Shanghai references are handled by ShanghaiStationInformationProvider"
            )
        }
    }

    /// `timeoutIntervalForRequest` only fires when no bytes arrive for the interval — a
    /// connection that trickles data indefinitely (observed on throttled routes to this host)
    /// never triggers it, so the byte-by-byte read below could hang well past `requestTimeout`
    /// and leave the loading spinner stuck. Race the whole fetch against an explicit deadline,
    /// mirroring `withMapKitTimeout` in MapKitProviders.swift, so it is always bounded.
    private static func fetch(
        _ request: PreparedRequest,
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        try await withThrowingTaskGroup(of: OfficialStationInformationSnapshot.self) { group in
            group.addTask { try await performFetch(request, using: session) }
            group.addTask {
                try await Task.sleep(for: .seconds(requestTimeout))
                throw OfficialStationInformationProviderError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw OfficialStationInformationProviderError.timedOut
            }
            return result
        }
    }

    private static func performFetch(
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
            throw OfficialStationInformationProviderError.invalidRequest(
                "official station reference is invalid"
            )
        }

        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: urlRequest,
                delegate: BeijingStationInformationRedirectDelegate()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw OfficialStationInformationProviderError.timedOut
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw OfficialStationInformationProviderError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url?.scheme?.lowercased() == "https",
              httpResponse.url?.host?.lowercased() == host,
              httpResponse.url?.path == endpointPath else {
            throw OfficialStationInformationProviderError.invalidResponse
        }
        if httpResponse.statusCode == 429 {
            throw OfficialStationInformationProviderError.rateLimited(
                retryAfter: retryAfterDelay(from: httpResponse)
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OfficialStationInformationProviderError.httpStatus(httpResponse.statusCode)
        }
        guard httpResponse.expectedContentLength <= 0 ||
                httpResponse.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw OfficialStationInformationProviderError.responseTooLarge
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            throw OfficialStationInformationProviderError.invalidResponse
        }

        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(Int(httpResponse.expectedContentLength))
        }
        do {
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw OfficialStationInformationProviderError.responseTooLarge
                }
                data.append(byte)
            }
        } catch let error as OfficialStationInformationProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OfficialStationInformationProviderError.transport(error.localizedDescription)
        }

        let payload: BeijingPayload
        do {
            payload = try JSONDecoder().decode(BeijingPayload.self, from: data)
        } catch {
            throw OfficialStationInformationProviderError.contractViolation(
                "response is not valid station JSON"
            )
        }

        guard payload.status == 200 else {
            throw OfficialStationInformationProviderError.serviceUnavailable(trimmed(payload.message))
        }
        guard let responseData = payload.data,
              let station = responseData.station,
              station.stationDeviceLocation == request.externalStationID,
              let stationName = trimmed(station.stationName) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station identity is missing or does not match the reviewed reference"
            )
        }

        let expectedNames = Set(request.expectedNames.map(normalizedName))
        guard expectedNames.contains(normalizedName(stationName)) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station name does not match the reviewed catalog"
            )
        }

        let serviceLines = groupedLines(responseData.lines ?? [])

        let exits = (station.exits ?? []).compactMap { exit in
            guard let name = trimmed(exit.name) else { return nil }
            return OfficialStationExitInformation(
                name: name,
                details: (exit.nearby ?? []).compactMap(trimmed).uniqued(),
                isAccessible: nil
            )
        }.uniqued(by: \OfficialStationExitInformation.id)

        let facilityGroups = (station.facilitys ?? []).compactMap { group in
            guard let groupName = trimmed(group.name) else { return nil }
            let items = (group.data ?? []).compactMap { item in
                guard let name = trimmed(item.name),
                      let rawDetail = trimmed(item.contentDesc) else { return nil }
                let unavailable = unavailableFacilityMarkers.contains(
                    rawDetail.lowercased()
                )
                return OfficialStationFacilityInformation(
                    name: name,
                    location: unavailable ? nil : rawDetail,
                    availability: unavailable ? .unavailable : .available
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
            lines: serviceLines,
            exits: exits,
            facilityGroups: facilityGroups
        )
    }

    /// The upstream returns one record per *service*, not per direction: `terminalStationName`
    /// is a direction marker (the next station toward that end of the line) while
    /// `destStationName` is that individual service's terminus. A direction served by several
    /// short-turn services therefore yields several records sharing a line name, a direction and
    /// a first-train time, differing only in the last-train digits — which rendered as visually
    /// identical duplicate rows. Observed at 宋家庄 line 10 (three records, all "开往 石榴庄",
    /// all first 5:07, last 21:44/22:05/23:28) and at 西直门 line 2.
    ///
    /// Collapse each (line, direction) to a single row spanning the whole service window:
    /// earliest first train, latest last train — which is what platform signage shows.
    /// The two directions then nest under their line, so a rider (and any other consumer of the
    /// schema) sees one block per line holding both of its service windows.
    private static func groupedLines(_ lines: [BeijingLine]) -> [OfficialStationLineInformation] {
        var lineOrder: [String] = []
        var colors: [String: String] = [:]
        var directionOrder: [String: [String]] = [:]
        var services: [String: [String: OfficialStationServiceInformation]] = [:]

        for line in lines {
            guard let lineName = trimmed(line.lineName),
                  let direction = trimmed(line.terminalStationName)
                    ?? trimmed(line.destStationName) else { continue }
            let first = trimmed(line.firstTime)
            let last = trimmed(line.lastTime)
            guard first != nil || last != nil else { continue }

            if services[lineName] == nil {
                lineOrder.append(lineName)
                services[lineName] = [:]
                directionOrder[lineName] = []
            }
            if colors[lineName] == nil, let color = normalizedColor(line.lineColor) {
                colors[lineName] = color
            }

            guard let existing = services[lineName]?[direction] else {
                directionOrder[lineName]?.append(direction)
                services[lineName]?[direction] = OfficialStationServiceInformation(
                    direction: direction,
                    firstTrain: first,
                    lastTrain: last,
                    liveTime: nil
                )
                continue
            }
            services[lineName]?[direction] = OfficialStationServiceInformation(
                direction: existing.direction,
                firstTrain: preferredServiceTime(existing.firstTrain, first, earliest: true),
                lastTrain: preferredServiceTime(existing.lastTrain, last, earliest: false),
                liveTime: nil
            )
        }

        return lineOrder.map { lineName in
            OfficialStationLineInformation(
                lineName: lineName,
                lineColorHex: colors[lineName],
                services: (directionOrder[lineName] ?? []).compactMap { services[lineName]?[$0] }
            )
        }
    }

    /// Minutes into the *service* day. A metro service day runs past midnight, so a last train
    /// at "0:21" is later than one at "23:39" — comparing the raw strings, or a plain clock
    /// time, would rank it as the earliest of the day and discard the real last train.
    private static func serviceMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else { return nil }
        return (hour < 4 ? hour + 24 : hour) * 60 + minute
    }

    private static func preferredServiceTime(
        _ lhs: String?,
        _ rhs: String?,
        earliest: Bool
    ) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        // An unparseable time keeps the side we can reason about rather than winning by accident.
        guard let lhsMinutes = serviceMinutes(lhs) else { return rhs }
        guard let rhsMinutes = serviceMinutes(rhs) else { return lhs }
        let preferLhs = earliest ? lhsMinutes <= rhsMinutes : lhsMinutes >= rhsMinutes
        return preferLhs ? lhs : rhs
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        .unicodeScalars
        .filter(CharacterSet.alphanumerics.contains)
        .map(String.init)
        .joined()
    }

    private static func normalizedColor(_ value: String?) -> String? {
        guard let value = trimmed(value)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              value.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "#\(value.uppercased())"
    }

    private static let unavailableFacilityMarkers: Set<String> = [
        "/",
        "／",
        "-",
        "--",
        "—",
        "n/a",
        "na",
        "none",
        "null",
        "无",
        "沒有",
        "没有",
        "暫無",
        "暂无"
    ]

    private static func retryAfterDelay(
        from response: HTTPURLResponse
    ) -> TimeInterval? {
        guard let rawValue = trimmed(
            response.value(forHTTPHeaderField: "Retry-After")
        ) else { return nil }
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

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
        } else {
            let value = try container.decode(String.self)
            guard let integer = Int(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an integer"
                )
            }
            self.value = integer
        }
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else {
            self.value = String(try container.decode(Int.self))
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
