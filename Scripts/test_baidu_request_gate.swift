import Darwin
import Foundation

// Counts what actually reaches the wire, so the claims below are measured rather than read off the
// source. BaiduMapsClient.swift is compiled for real by test_baidu_request_gate.sh; only the
// network under it is replaced.
final class CountingProtocol: URLProtocol, @unchecked Sendable {
    struct Sample: Sendable {
        let url: String
        let startedAt: Date
        let finishedAt: Date
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var samples: [Sample] = []
    nonisolated(unsafe) private static var live = 0
    nonisolated(unsafe) private static var peakLive = 0

    static func reset() {
        lock.lock(); samples = []; live = 0; peakLive = 0; lock.unlock()
    }
    static var allSamples: [Sample] { lock.lock(); defer { lock.unlock() }; return samples }
    static var peakConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peakLive }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let started = Date()
        Self.lock.lock()
        Self.live += 1
        Self.peakLive = max(Self.peakLive, Self.live)
        Self.lock.unlock()

        let url = request.url!
        // A real response takes time, which is what makes a concurrency ceiling observable at all.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            Self.lock.lock()
            Self.live -= 1
            Self.samples.append(Sample(url: url.absoluteString, startedAt: started, finishedAt: Date()))
            Self.lock.unlock()
            let body = Data(#"{"status":0,"message":"ok"}"#.utf8)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

struct Envelope: BaiduResponseEnvelope {
    let status: Int
    let message: String?
}

final class Recorder {
    private(set) var failures = 0
    func check(_ label: String, _ actual: String, _ expected: String) {
        if actual == expected {
            print("  ok   \(label) -> \(actual)")
        } else {
            failures += 1
            print("  FAIL \(label) -> \(actual), expected \(expected)")
        }
    }
}

@main
enum BaiduRequestGateTests {
    static func makeClient() -> BaiduMapsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]
        return BaiduMapsClient(
            configuration: BaiduMapsConfiguration(accessKey: "test-key"),
            session: URLSession(configuration: configuration)
        )
    }

    static func fire(_ client: BaiduMapsClient, query: String) async {
        _ = try? await client.get(
            Envelope.self,
            path: "/direction/v2/transit",
            parameters: [(name: "origin", value: query)]
        )
    }

    static func main() async {
        let recorder = Recorder()

        // Identical requests already on the wire are joined, not repeated. The per-service caches
        // check on the way in and write on the way out, so without this two plans started together
        // both miss and both spend a call.
        print("coalescing")
        CountingProtocol.reset()
        let coalesced = makeClient()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { await fire(coalesced, query: "same") } }
        }
        recorder.check(
            "6 identical concurrent requests reach the wire once",
            String(CountingProtocol.allSamples.count),
            "1"
        )

        // Distinct requests are not joined — coalescing must not silently drop real work.
        print("distinct requests")
        CountingProtocol.reset()
        let distinct = makeClient()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 { group.addTask { await fire(distinct, query: "q\(index)") } }
        }
        recorder.check(
            "6 distinct concurrent requests all reach the wire",
            String(CountingProtocol.allSamples.count),
            "6"
        )
        recorder.check(
            "never more than the concurrency ceiling in flight",
            String(CountingProtocol.peakConcurrent <= BaiduMapsClient.maximumConcurrentRequests),
            "true"
        )
        // Against the published free-tier limit, not against our own constant. Checking the gate
        // only against the number it was told to enforce would pass however that number was
        // raised, which is exactly the regression worth catching.
        recorder.check(
            "and the ceiling itself stays inside Baidu's 3 QPS",
            String(BaiduMapsClient.maximumConcurrentRequests <= 3),
            "true"
        )

        // The account limit is per second, which concurrency alone does not bound: two slots with
        // instant responses is unlimited throughput.
        let starts = CountingProtocol.allSamples.map(\.startedAt).sorted()
        let tightest = zip(starts, starts.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .min() ?? .infinity
        let spacing = Double(BaiduMapsClient.minimumRequestSpacing.components.attoseconds) / 1e18
            + Double(BaiduMapsClient.minimumRequestSpacing.components.seconds)
        recorder.check(
            "starts are spaced by at least the declared minimum",
            String(tightest >= spacing * 0.8),
            "true"
        )
        recorder.check(
            "and the declared minimum keeps a burst under 3/s",
            String(spacing >= 1.0 / 3.0),
            "true"
        )

        // An exhausted budget is refused locally, and the refusal is recorded rather than swallowed
        // — the whole reason a rider could never tell which Baidu limit they had hit.
        print("budget and diagnostics")
        CountingProtocol.reset()
        let rationed = makeClient()
        let ceiling = BaiduMapsClient.RequestBudget.ceilings["/place/v2/search"] ?? 0
        for index in 0...ceiling {
            _ = try? await rationed.get(
                Envelope.self,
                path: "/place/v2/search",
                parameters: [(name: "query", value: "q\(index)")]
            )
        }
        recorder.check(
            "spending stops at the ceiling",
            String(CountingProtocol.allSamples.count),
            String(ceiling)
        )
        let search = await rationed.diagnostics().first { $0.path == "/place/v2/search" }
        recorder.check("the ceiling is reported", String(search?.spent ?? -1), String(ceiling))
        recorder.check(
            "and the refusal is recorded, not swallowed",
            String(search?.lastFailure != nil),
            "true"
        )

        if recorder.failures > 0 {
            print("\n\(recorder.failures) failure(s)")
            exit(1)
        }
        print("\nall Baidu request-gate checks passed")
    }
}
