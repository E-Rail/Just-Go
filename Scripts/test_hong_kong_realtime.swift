import Darwin
import Foundation

// The production files depend only on this localization surface. Keeping the harness
// locale fixed makes response parsing deterministic without pulling in UI model types.
enum AppLocalization {
    static let isChinese = false
    static let isTraditionalChinese = false

    static func localized(_ key: String) -> String { key }
    static func chinese(_ simplified: String) -> String { simplified }

    static func text(english: String, simplified: String, traditional: String) -> String {
        english
    }

    static func minutes(_ count: Int) -> String {
        "\(count) min"
    }
}

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

private enum MockOutcome: @unchecked Sendable {
    case http(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data,
        delay: TimeInterval = 0
    )
    case urlError(URLError.Code, delay: TimeInterval = 0)
}

private enum MockTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> MockOutcome

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var requestURLs: [URL] = []

    static func install(_ newHandler: @escaping Handler) {
        lock.lock()
        handler = newHandler
        requestURLs = []
        lock.unlock()
    }

    static func respond(to request: URLRequest) throws -> MockOutcome {
        let activeHandler: Handler
        let invocation: Int

        lock.lock()
        guard let configuredHandler = handler else {
            lock.unlock()
            throw HarnessFailure(description: "Mock transport has no response handler")
        }
        activeHandler = configuredHandler
        if let url = request.url {
            requestURLs.append(url)
        }
        invocation = requestURLs.count
        lock.unlock()

        return try activeHandler(request, invocation)
    }

    static var requestCount: Int {
        lock.lock()
        let count = requestURLs.count
        lock.unlock()
        return count
    }

    static var urls: [URL] {
        lock.lock()
        let snapshot = requestURLs
        lock.unlock()
        return snapshot
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "rt.data.gov.hk"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let outcome = try MockTransport.respond(to: request)
            switch outcome {
            case .http(let statusCode, let headers, let body, let delay):
                sleep(for: delay)
                guard let url = request.url,
                      let response = HTTPURLResponse(
                        url: url,
                        statusCode: statusCode,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                      ) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)

            case .urlError(let code, let delay):
                sleep(for: delay)
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func sleep(for delay: TimeInterval) {
        guard delay > 0 else { return }
        Thread.sleep(forTimeInterval: delay)
    }
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw HarnessFailure(description: "\(file):\(line): \(message())")
    }
}

private func requireEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    try require(
        actual == expected,
        "\(message); expected \(String(describing: expected)), got \(String(describing: actual))",
        file: file,
        line: line
    )
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func heavyRailFixture(
    lineCode: String,
    stationCode: String,
    up: [[String: Any]],
    down: [[String: Any]] = []
) throws -> Data {
    try jsonData([
        "status": 1,
        "message": "success",
        "data": [
            "\(lineCode.uppercased())-\(stationCode.uppercased())": [
                "UP": up,
                "DOWN": down
            ]
        ]
    ])
}

private func lightRailFixture(routes: [[String: Any]]) throws -> Data {
    try jsonData([
        "status": 1,
        "message": "success",
        "platform_list": [[
            "platform_id": 1,
            "route_list": routes
        ]]
    ])
}

private func heavyRequest(
    stationID: String = "hk-hong-kong",
    lineCode: String = "TCL",
    stationCode: String = "HOK",
    destinationNames: [String: RealtimeArrivalName] = [
        "TSY": RealtimeArrivalName(
            english: "Tsing Yi",
            simplifiedChinese: "青衣",
            traditionalChinese: "青衣"
        ),
        "HOK": RealtimeArrivalName(
            english: "Hong Kong",
            simplifiedChinese: "香港",
            traditionalChinese: "香港"
        )
    ],
    lineName: String = "Tung Chung Line",
    lineColor: String = "F7943E"
) -> RealtimeArrivalRequest {
    RealtimeArrivalRequest(
        stationID: stationID,
        reference: .hongKongHeavyRail(lineCode: lineCode, stationCode: stationCode),
        destinationNamesByCode: destinationNames,
        lineName: RealtimeArrivalName(english: lineName),
        lineColorHex: lineColor
    )
}

private func lightRailRequest(
    stationID: String = "hk-hoi-wong-road",
    officialStationID: String = "100",
    destinationNames: [String: RealtimeArrivalName] = [
        "TIN SHUI WAI": RealtimeArrivalName(
            english: "Tin Shui Wai",
            simplifiedChinese: "天水围",
            traditionalChinese: "天水圍"
        ),
        "SIU HONG": RealtimeArrivalName(
            english: "Siu Hong",
            simplifiedChinese: "兆康",
            traditionalChinese: "兆康"
        )
    ]
) -> RealtimeArrivalRequest {
    RealtimeArrivalRequest(
        stationID: stationID,
        reference: .hongKongLightRail(stationID: officialStationID),
        destinationNamesByCode: destinationNames,
        lineName: RealtimeArrivalName(english: "Light Rail"),
        lineColorHex: "D3A809"
    )
}

private func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == name })?
        .value
}

private func providerError(
    from operation: @Sendable () async throws -> Void
) async throws -> RealtimeArrivalProviderError {
    do {
        try await operation()
        throw HarnessFailure(description: "Expected realtime provider operation to fail")
    } catch let error as RealtimeArrivalProviderError {
        return error
    } catch let error as HarnessFailure {
        throw error
    } catch {
        throw HarnessFailure(
            description: "Expected RealtimeArrivalProviderError, got \(String(reflecting: error))"
        )
    }
}

private func testHeavyRailParsingAndDestinationLookup() async throws {
    let body = try heavyRailFixture(
        lineCode: "TCL",
        stationCode: "HOK",
        up: [
            ["ttnt": "3", "valid": "Y", "dest": "TSY"],
            ["ttnt": "9", "valid": "N", "dest": "TSY"]
        ],
        down: [
            ["ttnt": 0, "valid": "Y", "dest": "HOK"]
        ]
    )
    MockTransport.install { _, _ in
        .http(statusCode: 200, body: body)
    }

    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = HongKongRealtimeArrivalProvider(session: session)
    let arrivals = try await provider.arrivals(for: heavyRequest(
        lineCode: " tcl ",
        stationCode: " hok "
    ))

    try requireEqual(arrivals.count, 2, "invalid heavy-rail trains must be omitted")
    let tsingYiName = RealtimeArrivalName(
        english: "Tsing Yi",
        simplifiedChinese: "青衣",
        traditionalChinese: "青衣"
    ).localized
    let tsingYi = try requireArrival(destination: tsingYiName, in: arrivals)
    try requireEqual(tsingYi.minutesRemaining, 3, "heavy-rail countdown must be parsed")
    try requireEqual(tsingYi.lineName, "Tung Chung Line", "line name must be preserved")
    try requireEqual(tsingYi.lineColorHex, "F7943E", "line color must be preserved")
    try requireEqual(tsingYi.source, .liveCountdown, "heavy-rail data must be live")

    let hongKong = try requireArrival(destination: "Hong Kong", in: arrivals)
    try requireEqual(hongKong.minutesRemaining, 0, "zero-minute arrivals must not be dropped")

    try requireEqual(MockTransport.requestCount, 1, "heavy-rail request count")
    guard let url = MockTransport.urls.first else {
        throw HarnessFailure(description: "Heavy-rail request URL was not recorded")
    }
    try requireEqual(url.path, "/v1/transport/mtr/getSchedule.php", "heavy-rail endpoint")
    try requireEqual(queryValue("line", in: url), "TCL", "line code normalization")
    try requireEqual(queryValue("sta", in: url), "HOK", "station code normalization")
    try requireEqual(queryValue("lang", in: url), "EN", "official response language")
}

private func testLightRailNormalAndSpecialServices() async throws {
    let body = try lightRailFixture(routes: [
        [
            "arrival_departure": "",
            "dest_en": "TIN SHUI WAI",
            "dest_ch": "天水圍",
            "time_en": "4 mins",
            "time_ch": "4 分鐘",
            "route_no": "751",
            "stop": 0,
            "special": 0
        ],
        [
            "arrival_departure": "",
            "dest_en": "SIU HONG",
            "dest_ch": "兆康",
            "time_en": "Arriving",
            "time_ch": "正在到站",
            "route_no": "",
            "stop": 0,
            "special": 1,
            "additionalInfo1": "Special service"
        ],
        [
            "arrival_departure": "D",
            "dest_en": "TIN SHUI WAI",
            "dest_ch": "天水圍",
            "time_en": "-",
            "time_ch": "-",
            "route_no": "751",
            "stop": 1,
            "special": 0
        ]
    ])
    MockTransport.install { _, _ in
        .http(statusCode: 200, body: body)
    }

    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = HongKongRealtimeArrivalProvider(session: session)
    let arrivals = try await provider.arrivals(for: lightRailRequest())

    try requireEqual(arrivals.count, 2, "stopped Light Rail services must be omitted")
    let normal = try requireArrival(destination: "Tin Shui Wai", in: arrivals)
    try requireEqual(normal.lineName, "751", "normal service must use its route number")
    try requireEqual(normal.minutesRemaining, 4, "normal Light Rail countdown")
    try requireEqual(normal.timeText, nil, "numeric countdown must not duplicate text")

    let special = try requireArrival(destination: "Siu Hong", in: arrivals)
    try requireEqual(special.lineName, "Special service", "special-service label")
    try requireEqual(special.minutesRemaining, nil, "textual live time must not invent minutes")
    try requireEqual(special.timeText, "Arriving", "textual live time must be preserved")
    try requireEqual(special.source, .liveCountdown, "Light Rail data must be live")
    try require(special.isLiveArrival, "text-only government responses must remain live")
    try require(!special.hasLiveCountdown, "text-only responses must not claim a numeric countdown")

    guard let url = MockTransport.urls.first else {
        throw HarnessFailure(description: "Light Rail request URL was not recorded")
    }
    try requireEqual(url.path, "/v1/transport/mtr/lrt/getSchedule", "Light Rail endpoint")
    try requireEqual(queryValue("station_id", in: url), "100", "Light Rail station ID")
    try requireEqual(queryValue("with_special", in: url), "1", "special-service query")
}

private func testTenSecondCache() async throws {
    let firstBody = try heavyRailFixture(
        lineCode: "TCL",
        stationCode: "HOK",
        up: [["ttnt": "2", "valid": "Y", "dest": "TSY"]]
    )
    let refreshedBody = try heavyRailFixture(
        lineCode: "TCL",
        stationCode: "HOK",
        up: [["ttnt": "8", "valid": "Y", "dest": "TSY"]]
    )
    MockTransport.install { _, invocation in
        .http(statusCode: 200, body: invocation == 1 ? firstBody : refreshedBody)
    }

    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = HongKongRealtimeArrivalProvider(session: session)
    let request = heavyRequest()

    let first = try await provider.arrivals(for: request)
    let cached = try await provider.arrivals(for: request)
    try requireEqual(MockTransport.requestCount, 1, "second call inside cache lifetime")
    try requireEqual(first.map(\.id), cached.map(\.id), "cache must return the stored result")
    try requireEqual(cached.first?.minutesRemaining, 2, "cached payload")

    try await Task.sleep(for: .milliseconds(10_200))
    let refreshed = try await provider.arrivals(for: request)
    try requireEqual(MockTransport.requestCount, 2, "cache must expire after ten seconds")
    try requireEqual(refreshed.first?.minutesRemaining, 8, "expired cache must refetch")
    try require(first.map(\.id) != refreshed.map(\.id), "refetch must not return stale identities")
}

private func testRequestCoalescing() async throws {
    let body = try heavyRailFixture(
        lineCode: "TCL",
        stationCode: "HOK",
        up: [["ttnt": "5", "valid": "Y", "dest": "TSY"]]
    )
    MockTransport.install { _, _ in
        .http(statusCode: 200, body: body, delay: 0.25)
    }

    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = HongKongRealtimeArrivalProvider(session: session)
    let request = heavyRequest()

    async let firstCall = provider.arrivals(for: request)
    async let secondCall = provider.arrivals(for: request)
    let (first, second) = try await (firstCall, secondCall)

    try requireEqual(MockTransport.requestCount, 1, "identical in-flight requests must coalesce")
    try requireEqual(first.map(\.id), second.map(\.id), "coalesced callers must share one result")
}

private func testRetryAfterBackoff() async throws {
    let successBody = try heavyRailFixture(
        lineCode: "TCL",
        stationCode: "HOK",
        up: [["ttnt": "1", "valid": "Y", "dest": "TSY"]]
    )
    MockTransport.install { _, invocation in
        if invocation == 1 {
            return .http(
                statusCode: 429,
                headers: ["Retry-After": "1"],
                body: Data()
            )
        }
        return .http(statusCode: 200, body: successBody)
    }

    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = HongKongRealtimeArrivalProvider(session: session)

    let initialError = try await providerError {
        _ = try await provider.arrivals(for: heavyRequest())
    }
    guard case .rateLimited(let initialDelay) = initialError else {
        throw HarnessFailure(description: "Expected Retry-After rate limit, got \(initialError)")
    }
    try require(initialDelay >= 0.99 && initialDelay <= 1.01, "Retry-After seconds must be honored")

    let blockedError = try await providerError {
        _ = try await provider.arrivals(for: heavyRequest(stationID: "hk-kowloon"))
    }
    guard case .rateLimited(let remainingDelay) = blockedError else {
        throw HarnessFailure(description: "Expected local rate-limit backoff, got \(blockedError)")
    }
    try require(remainingDelay > 0 && remainingDelay <= 1, "local backoff must report remaining time")
    try requireEqual(MockTransport.requestCount, 1, "backoff must prevent another HTTP request")

    try await Task.sleep(for: .milliseconds(1_100))
    let recovered = try await provider.arrivals(for: heavyRequest())
    try requireEqual(recovered.first?.minutesRemaining, 1, "provider must recover after Retry-After")
    try requireEqual(MockTransport.requestCount, 2, "request after Retry-After")
}

private func testDefaultThirtySecondBackoffAndEndpointIsolation() async throws {
    let lightBody = try lightRailFixture(routes: [[
        "arrival_departure": "",
        "dest_en": "TIN SHUI WAI",
        "dest_ch": "天水圍",
        "time_en": "2 mins",
        "time_ch": "2 分鐘",
        "route_no": "751",
        "stop": 0,
        "special": 0
    ]])
    MockTransport.install { request, _ in
        if request.url?.path == "/v1/transport/mtr/lrt/getSchedule" {
            return .http(statusCode: 200, body: lightBody)
        }
        return .http(statusCode: 429, body: Data())
    }

    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = HongKongRealtimeArrivalProvider(session: session)

    let initialError = try await providerError {
        _ = try await provider.arrivals(for: heavyRequest())
    }
    guard case .rateLimited(let retryAfter) = initialError else {
        throw HarnessFailure(description: "Expected default rate limit, got \(initialError)")
    }
    try requireEqual(retryAfter, 30, "missing Retry-After must use 30 seconds")

    _ = try await providerError {
        _ = try await provider.arrivals(for: heavyRequest(stationID: "hk-admiralty"))
    }
    try requireEqual(MockTransport.requestCount, 1, "default backoff must be enforced locally")

    let lightArrivals = try await provider.arrivals(for: lightRailRequest())
    try requireEqual(lightArrivals.first?.minutesRemaining, 2, "other endpoint must remain available")
    try requireEqual(MockTransport.requestCount, 2, "backoff must be endpoint-specific")
}

private func testMalformedServerAndOfflineErrors() async throws {
    MockTransport.install { _, _ in
        .http(statusCode: 200, body: Data("{".utf8))
    }
    let malformedSession = makeSession()
    let malformedProvider = HongKongRealtimeArrivalProvider(session: malformedSession)
    let malformedError = try await providerError {
        _ = try await malformedProvider.arrivals(for: heavyRequest())
    }
    guard case .contractViolation = malformedError else {
        throw HarnessFailure(description: "Malformed JSON must be a contract violation: \(malformedError)")
    }
    malformedSession.invalidateAndCancel()

    MockTransport.install { _, _ in
        .http(statusCode: 503, body: Data())
    }
    let serverSession = makeSession()
    let serverProvider = HongKongRealtimeArrivalProvider(session: serverSession)
    let serverError = try await providerError {
        _ = try await serverProvider.arrivals(for: heavyRequest())
    }
    try requireEqual(serverError, .httpStatus(503), "5xx response mapping")
    serverSession.invalidateAndCancel()

    MockTransport.install { _, _ in
        .urlError(.notConnectedToInternet)
    }
    let offlineSession = makeSession()
    let offlineProvider = HongKongRealtimeArrivalProvider(session: offlineSession)
    let offlineError = try await providerError {
        _ = try await offlineProvider.arrivals(for: heavyRequest())
    }
    guard case .transport = offlineError else {
        throw HarnessFailure(description: "Offline error must map to transport: \(offlineError)")
    }
    offlineSession.invalidateAndCancel()
}

private func testRequestIdentityIsolation() async throws {
    let hongKongBody = try heavyRailFixture(
        lineCode: "TCL",
        stationCode: "HOK",
        up: [["ttnt": "7", "valid": "Y", "dest": "TSY"]]
    )
    let admiraltyBody = try heavyRailFixture(
        lineCode: "ISL",
        stationCode: "ADM",
        up: [["ttnt": "1", "valid": "Y", "dest": "CHW"]]
    )
    MockTransport.install { request, _ in
        guard let url = request.url else {
            throw HarnessFailure(description: "Mock request has no URL")
        }
        switch queryValue("sta", in: url) {
        case "HOK":
            return .http(statusCode: 200, body: hongKongBody, delay: 0.3)
        case "ADM":
            return .http(statusCode: 200, body: admiraltyBody, delay: 0.02)
        default:
            return .http(statusCode: 404, body: Data())
        }
    }

    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = HongKongRealtimeArrivalProvider(session: session)
    let hongKongRequest = heavyRequest()
    let admiraltyRequest = heavyRequest(
        stationID: "hk-admiralty",
        lineCode: "ISL",
        stationCode: "ADM",
        destinationNames: ["CHW": RealtimeArrivalName(english: "Chai Wan")],
        lineName: "Island Line",
        lineColor: "0860A8"
    )

    async let slowCall = provider.arrivals(for: hongKongRequest)
    async let fastCall = provider.arrivals(for: admiraltyRequest)
    let (hongKong, admiralty) = try await (slowCall, fastCall)

    try requireEqual(hongKong.first?.destination, "Tsing Yi", "late Hong Kong response identity")
    try requireEqual(hongKong.first?.minutesRemaining, 7, "late Hong Kong countdown")
    try requireEqual(hongKong.first?.lineName, "Tung Chung Line", "late Hong Kong line")
    try requireEqual(admiralty.first?.destination, "Chai Wan", "Admiralty response identity")
    try requireEqual(admiralty.first?.minutesRemaining, 1, "Admiralty countdown")
    try requireEqual(admiralty.first?.lineName, "Island Line", "Admiralty line")
    try requireEqual(MockTransport.requestCount, 2, "distinct identities require distinct requests")

    let cachedHongKong = try await provider.arrivals(for: hongKongRequest)
    let cachedAdmiralty = try await provider.arrivals(for: admiraltyRequest)
    try requireEqual(cachedHongKong.map(\.id), hongKong.map(\.id), "Hong Kong cache identity")
    try requireEqual(cachedAdmiralty.map(\.id), admiralty.map(\.id), "Admiralty cache identity")
    try requireEqual(MockTransport.requestCount, 2, "late response must not replace another cache entry")
}

private func requireArrival(
    destination: String,
    in arrivals: [RealTimeArrival]
) throws -> RealTimeArrival {
    guard let arrival = arrivals.first(where: { $0.destination == destination }) else {
        throw HarnessFailure(
            description: "Missing destination \(destination); got \(arrivals.map(\.destination))"
        )
    }
    return arrival
}

private func runTest(
    _ name: String,
    operation: @Sendable () async throws -> Void
) async -> Bool {
    do {
        try await operation()
        print("PASS \(name)")
        return true
    } catch {
        FileHandle.standardError.write(Data("FAIL \(name): \(error)\n".utf8))
        return false
    }
}

@main
private struct HongKongRealtimeTestHarness {
    static func main() async {
        var passed = 0
        var failed = 0

        for result in [
            await runTest("heavy rail parsing and localized destinations") {
                try await testHeavyRailParsingAndDestinationLookup()
            },
            await runTest("Light Rail normal and special services") {
                try await testLightRailNormalAndSpecialServices()
            },
            await runTest("10-second response cache") {
                try await testTenSecondCache()
            },
            await runTest("in-flight request coalescing") {
                try await testRequestCoalescing()
            },
            await runTest("Retry-After backoff") {
                try await testRetryAfterBackoff()
            },
            await runTest("default 30-second endpoint backoff") {
                try await testDefaultThirtySecondBackoffAndEndpointIsolation()
            },
            await runTest("malformed, 5xx, and offline errors") {
                try await testMalformedServerAndOfflineErrors()
            },
            await runTest("request identity isolation") {
                try await testRequestIdentityIsolation()
            }
        ] {
            if result {
                passed += 1
            } else {
                failed += 1
            }
        }

        print("Hong Kong realtime harness: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(EXIT_FAILURE)
        }
    }
}
