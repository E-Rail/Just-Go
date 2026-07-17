import Darwin
import Foundation

enum AppLocalization {
    static func localized(_ key: String) -> String { key }

    static func text(english: String, simplified: String, traditional: String) -> String {
        english
    }
}

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

private enum MockOutcome: @unchecked Sendable {
    case http(
        statusCode: Int,
        headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"],
        body: Data,
        delay: TimeInterval = 0
    )
    case urlError(URLError.Code)
}

private enum MockTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> MockOutcome

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func install(_ newHandler: @escaping Handler) {
        lock.lock()
        handler = newHandler
        requests = []
        lock.unlock()
    }

    static func response(for request: URLRequest) throws -> MockOutcome {
        let activeHandler: Handler
        let invocation: Int
        lock.lock()
        guard let handler else {
            lock.unlock()
            throw HarnessFailure(description: "Mock transport has no handler")
        }
        activeHandler = handler
        requests.append(request)
        invocation = requests.count
        lock.unlock()
        return try activeHandler(request, invocation)
    }

    static var requestCount: Int {
        lock.lock()
        let result = requests.count
        lock.unlock()
        return result
    }

    static var firstRequest: URLRequest? {
        lock.lock()
        let result = requests.first
        lock.unlock()
        return result
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "www.bjsubway.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            switch try MockTransport.response(for: request) {
            case .http(let statusCode, let headers, let body, let delay):
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }
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
            case .urlError(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
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

private func fixture(
    stationID: Any = 150_995_220,
    stationName: String = "建国门",
    status: Any = 200
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "status": status,
        "message": "成功",
        "data": [
            "lines": [
                [
                    "lineName": "1号线八通线",
                    "lineColor": "BE3631",
                    "firstTime": "5:27",
                    "lastTime": "23:29",
                    "terminalStationName": "环球度假区",
                    "destStationName": "环球度假区"
                ],
                [
                    "lineName": "2号线",
                    "lineColor": "#006098",
                    "firstTime": "5:12",
                    "lastTime": "23:48",
                    "terminalStationName": "北京站",
                    "destStationName": "北京站"
                ]
            ],
            "station": [
                "stationName": stationName,
                "stationDeviceLocation": stationID,
                "exits": [
                    ["name": "A", "nearby": ["建国门内大街北侧", "北京站街"]]
                ],
                "facilitys": [
                    [
                        "name": "票务服务设施",
                        "data": [
                            ["name": "自动售票机", "contentDesc": "C口、B口、A口"],
                            ["name": "直梯", "contentDesc": "/"]
                        ]
                    ]
                ]
            ]
        ]
    ], options: [.sortedKeys])
}

private func request(
    externalStationID: String = "150995220",
    expectedNames: [String] = ["建国门", "Jianguomen"]
) -> OfficialStationInformationRequest {
    OfficialStationInformationRequest(
        stationID: "network-1100-jianguomen",
        reference: .beijing(
            externalStationID: externalStationID,
            expectedNames: expectedNames
        )
    )
}

private func providerError(
    from operation: @Sendable () async throws -> Void
) async throws -> OfficialStationInformationProviderError {
    do {
        try await operation()
        throw HarnessFailure(description: "Expected provider operation to fail")
    } catch let error as OfficialStationInformationProviderError {
        return error
    } catch let error as HarnessFailure {
        throw error
    } catch {
        throw HarnessFailure(
            description: "Expected OfficialStationInformationProviderError, got \(error)"
        )
    }
}

private func testParsingAndRequestContract() async throws {
    let body = try fixture()
    MockTransport.install { _, _ in .http(statusCode: 200, body: body) }
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = BeijingStationInformationProvider(session: session)

    let snapshot = try await provider.information(for: request())
    try requireEqual(OfficialStationInformationCategory.allCases.count, 3, "category count")
    try requireEqual(snapshot.stationName, "建国门", "station name")
    try requireEqual(snapshot.source, .beijingSubwayOnline, "source")
    try requireEqual(snapshot.trains.count, 2, "first/last train rows")
    try requireEqual(snapshot.trains.first?.lineColorHex, "#BE3631", "line color")
    try requireEqual(snapshot.exits.first?.details.count, 2, "exit nearby text")
    try requireEqual(snapshot.facilityGroups.first?.items.first?.location, "C口、B口、A口", "facility location")
    try requireEqual(snapshot.facilityGroups.first?.items.count, 2, "facility status rows")
    try requireEqual(
        snapshot.facilityGroups.first?.items.last?.availability,
        .unavailable,
        "slash placeholder must be unavailable"
    )
    try requireEqual(
        snapshot.facilityGroups.first?.items.last?.location,
        nil,
        "unavailable facility must not expose a slash location"
    )

    guard let sent = MockTransport.firstRequest,
          let url = sent.url,
          let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
        throw HarnessFailure(description: "Request was not recorded")
    }
    try requireEqual(url.scheme, "https", "request scheme")
    try requireEqual(url.host, "www.bjsubway.com", "request host")
    try requireEqual(url.path, "/api/guanwang/v2/getStationDetail", "request path")
    try requireEqual(query, [URLQueryItem(name: "accLocation", value: "150995220")], "query")
    try requireEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json", "Accept header")
    try requireEqual(sent.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData, "cache policy")
}

private func testCacheCoalescingAndRelease() async throws {
    let body = try fixture()
    MockTransport.install { _, _ in
        .http(statusCode: 200, body: body, delay: 0.2)
    }
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let provider = BeijingStationInformationProvider(session: session)

    async let first = provider.information(for: request())
    async let second = provider.information(for: request())
    let (firstSnapshot, secondSnapshot) = try await (first, second)
    try requireEqual(firstSnapshot, secondSnapshot, "coalesced snapshots")
    try requireEqual(MockTransport.requestCount, 1, "coalesced request count")

    _ = try await provider.information(for: request())
    try requireEqual(MockTransport.requestCount, 1, "five-minute memory cache")
    await provider.releaseMemory()
    _ = try await provider.information(for: request())
    try requireEqual(MockTransport.requestCount, 2, "memory release must clear cache")
}

private func testIdentityAndServiceValidation() async throws {
    let wrongID = try fixture(stationID: 150_995_221)
    MockTransport.install { _, _ in .http(statusCode: 200, body: wrongID) }
    let session = makeSession()
    let provider = BeijingStationInformationProvider(session: session)
    let identityError = try await providerError {
        _ = try await provider.information(for: request())
    }
    guard case .contractViolation = identityError else {
        throw HarnessFailure(description: "Wrong station ID was not rejected")
    }
    session.invalidateAndCancel()

    let wrongName = try fixture(stationName: "苹果园")
    MockTransport.install { _, _ in .http(statusCode: 200, body: wrongName) }
    let nameSession = makeSession()
    let nameProvider = BeijingStationInformationProvider(session: nameSession)
    let nameError = try await providerError {
        _ = try await nameProvider.information(for: request())
    }
    guard case .contractViolation = nameError else {
        throw HarnessFailure(description: "Wrong station name was not rejected")
    }
    nameSession.invalidateAndCancel()

    let unavailable = try fixture(status: "2161")
    MockTransport.install { _, _ in .http(statusCode: 200, body: unavailable) }
    let unavailableSession = makeSession()
    let unavailableProvider = BeijingStationInformationProvider(session: unavailableSession)
    let unavailableError = try await providerError {
        _ = try await unavailableProvider.information(for: request())
    }
    guard case .serviceUnavailable = unavailableError else {
        throw HarnessFailure(description: "API status was not respected")
    }
    unavailableSession.invalidateAndCancel()
}

private func testTransportAndResponseLimits() async throws {
    MockTransport.install { _, _ in .urlError(.timedOut) }
    let timeoutSession = makeSession()
    let timeoutProvider = BeijingStationInformationProvider(session: timeoutSession)
    let timeoutError = try await providerError {
        _ = try await timeoutProvider.information(for: request())
    }
    try requireEqual(timeoutError, .timedOut, "timeout mapping")
    timeoutSession.invalidateAndCancel()

    MockTransport.install { _, _ in
        .http(
            statusCode: 429,
            headers: [
                "Content-Type": "application/json",
                "Retry-After": "60"
            ],
            body: Data()
        )
    }
    let limitSession = makeSession()
    let limitProvider = BeijingStationInformationProvider(session: limitSession)
    let limitError = try await providerError {
        _ = try await limitProvider.information(for: request())
    }
    try requireEqual(limitError, .rateLimited(retryAfter: 60), "429 mapping")
    let cooldownError = try await providerError {
        _ = try await limitProvider.information(for: request())
    }
    guard case .rateLimited = cooldownError else {
        throw HarnessFailure(description: "Active endpoint cooldown was not enforced")
    }
    try requireEqual(MockTransport.requestCount, 1, "rate-limit cooldown request count")
    limitSession.invalidateAndCancel()

    MockTransport.install { _, _ in
        .http(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(repeating: 0, count: 1_048_577)
        )
    }
    let sizeSession = makeSession()
    let sizeProvider = BeijingStationInformationProvider(session: sizeSession)
    let sizeError = try await providerError {
        _ = try await sizeProvider.information(for: request())
    }
    try requireEqual(sizeError, .responseTooLarge, "response cap")
    sizeSession.invalidateAndCancel()

    MockTransport.install { _, _ in
        .http(
            statusCode: 200,
            headers: ["Content-Type": "text/html"],
            body: Data("<html></html>".utf8)
        )
    }
    let contentSession = makeSession()
    let contentProvider = BeijingStationInformationProvider(session: contentSession)
    let contentError = try await providerError {
        _ = try await contentProvider.information(for: request())
    }
    try requireEqual(contentError, .invalidResponse, "content type")
    contentSession.invalidateAndCancel()
}

private func testInvalidReviewedReference() async throws {
    let provider = BeijingStationInformationProvider(session: makeSession())
    let invalidID = try await providerError {
        _ = try await provider.information(for: request(externalStationID: "station-name"))
    }
    guard case .invalidRequest = invalidID else {
        throw HarnessFailure(description: "Non-reviewed station ID was accepted")
    }
    let missingName = try await providerError {
        _ = try await provider.information(for: request(expectedNames: []))
    }
    guard case .invalidRequest = missingName else {
        throw HarnessFailure(description: "Empty expected names were accepted")
    }
}

@main
private enum BeijingStationInformationHarness {
    static func main() async {
        do {
            try await testParsingAndRequestContract()
            print("PASS: native categories and request contract")
            try await testCacheCoalescingAndRelease()
            print("PASS: cache, coalescing, and memory release")
            try await testIdentityAndServiceValidation()
            print("PASS: station identity and API status validation")
            try await testTransportAndResponseLimits()
            print("PASS: timeout, rate limit, MIME, and response cap")
            try await testInvalidReviewedReference()
            print("PASS: reviewed reference validation")
            print("BeijingStationInformationProvider: 5 test groups passed")
        } catch {
            FileHandle.standardError.write(
                Data("Beijing station information test failed: \(error)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
