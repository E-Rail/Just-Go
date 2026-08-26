import CryptoKit
import Foundation

/// Credentials and endpoint for Baidu's Web Service API.
///
/// The 服务端 (server) key type is deliberate. The alternative. An iOS-type key with Baidu's
/// native SDK: would bind the key to the bundle ID, which is better for key safety, but it also
/// links a closed-source binary that collects device identifiers into an app whose whole promise is
/// that it does not do that. It also speaks BD-09, a third coordinate frame on top of the two this
/// codebase already reconciles. HTTP + `ret_coordtype=gcj02` costs one client and stays honest.
///
/// `baseURL` is the port for moving off a shipped key: point it at a proxy that holds the AK and
/// the app stops carrying a secret at all, with no other code changing.
struct BaiduMapsConfiguration: Sendable, Equatable {
    let accessKey: String
    let secretKey: String?
    let baseURL: URL

    /// Baidu's own host. Replaced wholesale when requests move behind a proxy.
    static let defaultBaseHost = "https://api.map.baidu.com"

    init(accessKey: String, secretKey: String? = nil, baseURL: URL? = nil) {
        self.accessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = (secretKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretKey = trimmedSecret.isEmpty ? nil : trimmedSecret
        self.baseURL = baseURL ?? URL(string: Self.defaultBaseHost)!
    }

    /// No key means every Baidu-backed feature reports unavailable rather than guessing. The app
    /// must build and run without one: a missing key is a normal state, not an error.
    var isConfigured: Bool { !accessKey.isEmpty }

    /// Signing turns itself on when an SK exists. With the console set to IP 白名单 there is no SK
    /// and requests go unsigned; switching the console to SN 校验 and pasting an SK into
    /// Secrets.xcconfig is the whole migration.
    var signsRequests: Bool { secretKey != nil }

    static func fromBundle(_ bundle: Bundle = .main) -> BaiduMapsConfiguration {
        BaiduMapsConfiguration(
            accessKey: bundle.object(forInfoDictionaryKey: "BaiduMapsAK") as? String ?? "",
            secretKey: bundle.object(forInfoDictionaryKey: "BaiduMapsSK") as? String
        )
    }
}

/// Baidu's SN request signature.
///
/// The published prose describes building `/path?query` + SK and taking its MD5. Doing exactly that
/// produces the wrong digest: the assembled string is URL-encoded *again* before hashing, which
/// only Baidu's worked example reveals. `Scripts/test_baidu_sn_signature.rb` pins that example so
/// this cannot silently regress into a runtime `{"status":211,"message":"APP SN校验失败"}`.
enum BaiduRequestSigner {
    /// PHP's `urlencode`, which is what Baidu's reference implementations use. Note space becomes
    /// `+`, not `%20`. Swift's `addingPercentEncoding` does the opposite and produces a signature
    /// that fails for any query containing a space.
    static func urlEncoded(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in Array(value.utf8) {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            case UInt8(ascii: " "):
                encoded.append("+")
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    static func signature(path: String, query: String, secretKey: String) -> String {
        let assembled = "\(path)?\(query)\(secretKey)"
        return Insecure.MD5.hash(data: Data(urlEncoded(assembled).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum BaiduMapsError: Error, Equatable {
    case notConfigured
    /// Baidu answered, and said no. `status` is its own code. 302/210 Are quota and permission.
    case service(status: Int, message: String)
    case malformedResponse
    /// This launch has already made as many calls to that endpoint as it is allowed. Local, so it
    /// costs no round trip, and indistinguishable to every caller from having no key at all.
    case budgetExhausted(path: String)
}

/// Every Baidu Web Service response carries this envelope, and a non-zero `status` means the
/// payload is absent or meaningless, so it is checked before anything is decoded.
protocol BaiduResponseEnvelope: Decodable, Sendable {
    var status: Int { get }
    var message: String? { get }
}

/// Calls Baidu's Web Service API.
///
/// Requests are built as an ordered parameter list rather than a dictionary because the SN
/// signature must be computed over the parameters *in the order they are sent*; a dictionary's
/// arbitrary order would produce a valid-looking signature that Baidu rejects.
actor BaiduMapsClient {
    /// How many calls one launch may make to each endpoint family.
    ///
    /// The published free allowance is per *account* per day, not per device: 100 place searches,
    /// 300 reverse geocodes, 5,000 route plans, shared across every rider using the app. No number
    /// held on a phone can enforce that, and this does not pretend to. What it does is stop a
    /// single device spending the whole day's allowance in one sitting, and turn the aftermath into
    /// an immediate local refusal instead of a round trip to be told 302 每日配额超限.
    ///
    /// The ceilings are deliberately lopsided in the same proportion as the allowance itself. Route
    /// planning is where the headroom is and where every fact this app reads now comes from; place
    /// search is the starved one.
    enum RequestBudget {
        static let ceilings: [String: Int] = [
            "/place/v2/search": 25,
            "/reverse_geocoding/v3/": 20,
            "/direction/v2/transit": 200,
            "/direction/v2/riding": 200
        ]
    }

    /// At most this many requests may be in flight at once.
    ///
    /// The published free tier allows 3 QPS. Two, not three, because the ceiling is enforced on
    /// Baidu's side across the whole account — every rider using the app shares it — so sitting
    /// exactly on the limit means the first two devices to plan a trip in the same second decide
    /// whether the third gets an answer. Concurrency is not the same as rate, which is why
    /// `minimumRequestSpacing` exists as well.
    static let maximumConcurrentRequests = 2
    /// Minimum wall-clock gap between two request *starts*, which is what a per-second quota
    /// actually measures. 350 ms keeps a burst under 3/s even when every response is instant.
    static let minimumRequestSpacing = Duration.milliseconds(350)

    let configuration: BaiduMapsConfiguration
    private let session: URLSession
    private var spent: [String: Int] = [:]
    /// The last thing Baidu said no about, per endpoint.
    ///
    /// Recorded because every one of the five call sites turns a failure into
    /// `AppLog.…info("… unavailable: \(error)")` and moves on. `BaiduMapsError.service` has always
    /// carried Baidu's own status code — 302 daily quota, 401 concurrency, 240 service disabled —
    /// and nothing has ever read it, so "the API stopped working" has been unanswerable from
    /// inside the app. Kept in memory only, like everything else this client touches.
    private var failures: [String: BaiduEndpointDiagnostics.Failure] = [:]
    private var inFlightRequests = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var earliestNextStart: ContinuousClock.Instant = .now
    /// Identical requests already on the wire, keyed by URL.
    ///
    /// The per-service caches check on the way in and write on the way out, so two identical plans
    /// starting together both miss and both spend a call. This closes that window, and it closes it
    /// for every endpoint at once rather than once per service.
    private var coalescing: [String: Task<Data, Error>] = [:]

    init(configuration: BaiduMapsConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            // Ephemeral: Baidu's terms forbid caching what the service releases, and a URL cache
            // writing responses to disk is exactly that. It also keeps rider queries off the disk.
            sessionConfiguration.urlCache = nil
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.timeoutIntervalForRequest = 12
            sessionConfiguration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    var isConfigured: Bool { configuration.isConfigured }

    func get<Response: BaiduResponseEnvelope>(
        _ type: Response.Type,
        path: String,
        parameters: [(name: String, value: String)]
    ) async throws -> Response {
        guard configuration.isConfigured else { throw BaiduMapsError.notConfigured }

        var ordered = parameters
        ordered.append((name: "output", value: "json"))
        ordered.append((name: "ak", value: configuration.accessKey))

        // The signed string and the sent string must be byte-identical, so both are built from the
        // same encoder. Encoding twice with two different escapers is the classic way to get 211.
        var query = ordered
            .map { "\($0.name)=\(BaiduRequestSigner.urlEncoded($0.value))" }
            .joined(separator: "&")
        if let secretKey = configuration.secretKey {
            let signature = BaiduRequestSigner.signature(path: path, query: query, secretKey: secretKey)
            query += "&sn=\(signature)"
        }

        guard let url = URL(string: "\(configuration.baseURL.absoluteString)\(path)?\(query)") else {
            throw BaiduMapsError.malformedResponse
        }

        let data = try await fetch(url, path: path)

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            record(BaiduMapsError.malformedResponse, for: path)
            throw BaiduMapsError.malformedResponse
        }
        guard decoded.status == 0 else {
            let error = BaiduMapsError.service(status: decoded.status, message: decoded.message ?? "")
            record(error, for: path)
            throw error
        }
        return decoded
    }

    /// Everything between deciding to make a request and having its bytes: coalescing, the budget,
    /// the concurrency gate and the rate gate, in that order.
    ///
    /// The order matters. Coalescing comes first so a request that is already on the wire costs no
    /// budget and takes no slot; the budget comes next so an exhausted one is refused without ever
    /// queueing; and the two gates come last, closest to the wire.
    private func fetch(_ url: URL, path: String) async throws -> Data {
        let key = url.absoluteString
        if let existing = coalescing[key] {
            return try await existing.value
        }

        // Checked before anything is sent, so an exhausted budget costs nothing at all. Every
        // caller already treats a throw as "no answer" and falls back, so this needs no new
        // handling anywhere: it degrades the app to what it is with no key.
        if let ceiling = RequestBudget.ceilings[path] {
            let used = spent[path, default: 0]
            guard used < ceiling else {
                let error = BaiduMapsError.budgetExhausted(path: path)
                record(error, for: path)
                throw error
            }
            spent[path] = used + 1
        }

        // Detached on purpose. A plain `Task` inside an actor method inherits that actor's
        // isolation, so `enterGate` would be a same-actor call — synchronous, never suspending,
        // and the gate would admit everything it was written to hold back.
        let task = Task.detached { [session] () throws -> Data in
            await self.enterGate()
            do {
                let (data, _) = try await session.data(from: url)
                await self.leaveGate()
                return data
            } catch {
                await self.leaveGate()
                throw BaiduMapsError.service(status: -1, message: error.localizedDescription)
            }
        }
        coalescing[key] = task
        defer { coalescing[key] = nil }
        do {
            return try await task.value
        } catch {
            record(error, for: path)
            throw error
        }
    }

    /// Waits until this request is allowed to start, by concurrency and then by rate.
    private func enterGate() async {
        if inFlightRequests >= Self.maximumConcurrentRequests {
            // The slot is handed over directly by `leaveGate` rather than released and re-taken,
            // so a third caller cannot slip into it between the resume and this continuation
            // running.
            await withCheckedContinuation { waiting.append($0) }
        } else {
            inFlightRequests += 1
        }

        // The slot is reserved *before* the sleep, not after it. An actor releases its lock across
        // an await, so reading the next free instant, sleeping to it, and only then writing the one
        // after lets every waiter read the same instant and wake together — which is the shape of
        // the burst this exists to prevent. Reserving first is the only part that has to be atomic,
        // and between these two lines there is no suspension point.
        let start = max(ContinuousClock.now, earliestNextStart)
        earliestNextStart = start.advanced(by: Self.minimumRequestSpacing)
        try? await Task.sleep(until: start, clock: ContinuousClock())
    }

    private func leaveGate() {
        if waiting.isEmpty {
            inFlightRequests -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func record(_ error: Error, for path: String) {
        guard let error = error as? BaiduMapsError else { return }
        let summary: String
        switch error {
        case .notConfigured: return
        case .malformedResponse: summary = "malformed response"
        case .budgetExhausted: summary = "this launch's own budget for this endpoint"
        case .service(let status, let message):
            summary = message.isEmpty ? "status \(status)" : "\(status) \(message)"
        }
        failures[path] = BaiduEndpointDiagnostics.Failure(at: Date(), summary: summary)
    }

    /// What this launch has spent and what it was last refused, per endpoint.
    func diagnostics() -> [BaiduEndpointDiagnostics] {
        RequestBudget.ceilings.keys.sorted().map { path in
            BaiduEndpointDiagnostics(
                path: path,
                spent: spent[path, default: 0],
                ceiling: RequestBudget.ceilings[path] ?? 0,
                lastFailure: failures[path]
            )
        }
    }
}

/// One endpoint's usage this launch, for the Transit Data screen.
struct BaiduEndpointDiagnostics: Sendable, Identifiable {
    struct Failure: Sendable, Equatable {
        let at: Date
        let summary: String
    }

    let path: String
    let spent: Int
    let ceiling: Int
    let lastFailure: Failure?

    var id: String { path }
}

/// A coordinate as Baidu returns it. Requested as GCJ-02 on every endpoint, which is the frame the
/// rest of this app draws and measures in, so nothing needs converting on arrival.
///
/// Note the parameter that asks for it differs per endpoint. `Coord_type=gcj02` on directions,
/// `coord_type=2` on place search, `coordtype=gcj02ll` on reverse geocoding. They were each
/// verified against the live API rather than inferred, because a wrong one is not an error: it
/// returns BD-09 that looks plausible and lands a few hundred metres away.
struct BaiduCoordinate: Decodable, Sendable {
    let lat: Double
    let lng: Double
}
