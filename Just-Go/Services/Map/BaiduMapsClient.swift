import CryptoKit
import Foundation

/// Credentials and endpoint for Baidu's Web Service API.
///
/// A 服务端 (server) key over plain HTTP, on purpose: Baidu's native SDK would bind the key to the
/// bundle ID but links a closed binary that collects device identifiers, and speaks BD-09, a third
/// coordinate frame. `baseURL` is the way off a shipped key: point it at a proxy that holds the AK
/// and nothing else changes.
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

    /// No key means every Baidu-backed feature reports unavailable. The app builds and runs without
    /// one; a missing key is a normal state.
    var isConfigured: Bool { !accessKey.isEmpty }

    static func fromBundle(_ bundle: Bundle = .main) -> BaiduMapsConfiguration {
        BaiduMapsConfiguration(
            accessKey: bundle.object(forInfoDictionaryKey: "BaiduMapsAK") as? String ?? "",
            secretKey: bundle.object(forInfoDictionaryKey: "BaiduMapsSK") as? String
        )
    }
}

/// Baidu's SN request signature. The published prose (MD5 of `/path?query` + SK) produces the wrong
/// digest: the string is URL-encoded again before hashing, which only Baidu's worked example shows.
/// `Scripts/test_baidu_sn_signature.rb` pins that example.
enum BaiduRequestSigner {
    /// PHP's `urlencode`, as Baidu's reference implementations use: a space becomes `+`, not `%20`.
    /// Swift's `addingPercentEncoding` does the opposite and breaks the signature for any query
    /// with a space.
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
    /// Baidu answered, and said no. `status` is its own code; 302 and 210 are quota and permission.
    case service(status: Int, message: String)
    case malformedResponse
    /// The transport answered, but not with a 200. Distinct from `.service`, which is Baidu
    /// answering properly and saying no.
    case http(status: Int)
    /// This launch has already made as many calls to that endpoint as it is allowed. Local, so it
    /// costs no round trip, and indistinguishable to every caller from having no key at all.
    case budgetExhausted(path: String)
    /// Baidu refused this endpoint recently enough that asking again would only be refused again.
    /// Also local, also free.
    case refusedRecently(path: String)
}

/// A handle on an in-flight `URLSessionDataTask`, so a caller that has stopped waiting can stop the
/// transfer too. A class because `onCancel:` runs synchronously and cannot await; `NSLock` because
/// the adopting and cancelling sides are different tasks.
private final class SessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var waiters = 0

    /// Callers waiting on this one shared transfer. It is abandoned only once nobody is left
    /// waiting: one caller's deadline must not cancel an answer a joined caller is still waiting
    /// for.
    func addWaiter() {
        lock.lock()
        waiters += 1
        lock.unlock()
    }

    func removeWaiter() {
        lock.lock()
        waiters -= 1
        guard waiters <= 0 else {
            lock.unlock()
            return
        }
        cancelled = true
        let pending = task
        task = nil
        lock.unlock()
        pending?.cancel()
    }

    func adopt(_ task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        // Cancelled before the task even started: honour it rather than leaving a transfer running
        // that nobody is waiting for.
        if cancelled {
            task.cancel()
        } else {
            self.task = task
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
        task = nil
    }
}

/// Every Baidu Web Service response carries this envelope, and a non-zero `status` means the
/// payload is absent or meaningless, so it is checked before anything is decoded.
protocol BaiduResponseEnvelope: Decodable, Sendable {
    var status: Int { get }
    var message: String? { get }
}

/// Calls Baidu's Web Service API. Parameters are an ordered list, not a dictionary, because the SN
/// signature is computed over them in the order they are sent.
actor BaiduMapsClient {
    /// How many calls one launch may make to each endpoint family.
    ///
    /// The free allowance is per account per day, shared by every rider: 100 place searches, 300
    /// reverse geocodes, 5,000 route plans. A phone cannot enforce that; this stops one device
    /// spending the day's allowance in a sitting, and turns the aftermath into an immediate local
    /// refusal. The ceilings follow the allowance's proportions: route planning has the headroom,
    /// place search is starved.
    enum RequestBudget {
        static let ceilings: [String: Int] = [
            "/place/v2/search": 25,
            "/reverse_geocoding/v3/": 20,
            "/direction/v2/transit": 200,
            "/direction/v2/riding": 200
        ]
    }

    /// At most this many requests in flight at once. The free tier allows 3 QPS across the whole
    /// account, so two leaves room for another rider in the same second. Concurrency is not rate,
    /// hence `minimumRequestSpacing` too.
    static let maximumConcurrentRequests = 2
    /// Minimum gap between two request starts, which is what a per-second quota measures: 350 ms
    /// keeps a burst under 3/s.
    static let minimumRequestSpacing = Duration.milliseconds(350)
    /// Baidu statuses that will still be no in a moment: daily quota, concurrency ceiling, service
    /// disabled, referer or IP rejected.
    private static let refusalStatuses: Set<Int> = [210, 211, 240, 302, 401]
    /// How long an endpoint is left alone after one of those: long enough that a redraw or a retry
    /// does not walk back into it, short enough that a concurrency refusal clears within a session.
    private static let refusalHoldOff = Duration.seconds(120)

    let configuration: BaiduMapsConfiguration
    private let session: URLSession
    private var spent: [String: Int] = [:]
    /// The last thing Baidu refused, per endpoint, with its own status code, so "the API stopped
    /// working" is answerable from Transit Data. In memory only, like everything this client
    /// touches.
    private var failures: [String: BaiduEndpointDiagnostics.Failure] = [:]
    /// Endpoints Baidu has refused, and the instant it is worth asking again.
    private var refusedUntil: [String: ContinuousClock.Instant] = [:]
    private var inFlightRequests = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var earliestNextStart: ContinuousClock.Instant = .now
    /// Identical requests already on the wire, keyed by URL, with the handle that can stop each.
    /// The per-service caches check on the way in and write on the way out, so two identical plans
    /// starting together would both spend a call. The box travels with the task because joined
    /// callers need it too; see `SessionTaskBox.addWaiter`.
    private var coalescing: [String: (task: Task<Data, Error>, box: SessionTaskBox)] = [:]

    init(configuration: BaiduMapsConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            // Ephemeral: Baidu's terms forbid caching what the service releases, and it keeps rider
            // queries off the disk.
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

        // The signed string and the sent string must be byte-identical, so both come from the same
        // encoder; two escapers is the classic way to get 211.
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

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            // The real decoding error, so diagnostics can tell an HTML error page from a schema
            // change. Recorded in the per-endpoint failure rather than through `AppLog`: this file
            // has no app dependencies, which lets `Scripts/test_baidu_request_gate.sh` compile it
            // alone.
            record(BaiduMapsError.malformedResponse, for: path)
            failures[path] = BaiduEndpointDiagnostics.Failure(
                at: Date(),
                summary: "malformed response: \(error)"
            )
            throw BaiduMapsError.malformedResponse
        }
        guard decoded.status == 0 else {
            let error = BaiduMapsError.service(status: decoded.status, message: decoded.message ?? "")
            record(error, for: path)
            throw error
        }
        return decoded
    }

    /// Everything between deciding to make a request and having its bytes, in order: coalescing (a
    /// request already on the wire costs no budget and no slot), the budget (an exhausted one is
    /// refused without queueing), then the concurrency and rate gates, closest to the wire.
    private func fetch(_ url: URL, path: String) async throws -> Data {
        let key = url.absoluteString
        if let existing = coalescing[key] {
            // A joined caller counts as a waiter, and gets a cancellation handler of its own, so
            // walking away drops only its own claim on the shared transfer.
            existing.box.addWaiter()
            return try await withTaskCancellationHandler {
                try await existing.task.value
            } onCancel: {
                existing.box.removeWaiter()
            }
        }

        // Refused recently: the next call is also wasted, and this endpoint has a hard daily quota.
        if let until = refusedUntil[path], until > ContinuousClock.now {
            let error = BaiduMapsError.refusedRecently(path: path)
            record(error, for: path)
            throw error
        }

        // Checked before anything is sent. Every caller treats a throw as "no answer", so an
        // exhausted budget degrades the app to what it is with no key.
        if let ceiling = RequestBudget.ceilings[path] {
            let used = spent[path, default: 0]
            guard used < ceiling else {
                let error = BaiduMapsError.budgetExhausted(path: path)
                record(error, for: path)
                throw error
            }
            spent[path] = used + 1
        }

        // Detached on purpose. A plain `Task` inside an actor method inherits its isolation, so
        // `enterGate` would never suspend and the gate would admit everything.
        //
        // Detaching also severs cancellation, which `leaveGate` needs (a caller walking away must
        // not abandon a held slot), and awaiting `task.value` does not throw when the waiter is
        // cancelled. So the URLSession task is cancelled explicitly on the way out; the detached
        // body still owns and releases the slot.
        let sessionTask = SessionTaskBox()
        let task = Task.detached { [session] () throws -> Data in
            await self.enterGate()
            do {
                let data = try await withTaskCancellationHandler {
                    try await Self.data(from: url, session: session, box: sessionTask)
                } onCancel: {
                    sessionTask.cancel()
                }
                await self.leaveGate()
                return data
            } catch let error as BaiduMapsError {
                // Rethrown as it is, so `record` sees an HTTP failure and holds the endpoint off.
                await self.leaveGate()
                throw error
            } catch {
                await self.leaveGate()
                throw BaiduMapsError.service(status: -1, message: error.localizedDescription)
            }
        }
        coalescing[key] = (task, sessionTask)
        defer { coalescing[key] = nil }
        sessionTask.addWaiter()
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                sessionTask.removeWaiter()
            }
        } catch {
            record(error, for: path)
            throw error
        }
    }

    /// `URLSession.data(from:)` with a handle on the underlying task, so a caller that has given up
    /// waiting can stop the transfer rather than merely stop listening to it.
    private static func data(from url: URL, session: URLSession, box: SessionTaskBox) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // A gateway error or a captive portal answers with no error and an HTML body.
                // Checked, and held off in `record`, or it decodes as malformed and spends the
                // endpoint's whole launch budget on a page that was never JSON.
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: BaiduMapsError.malformedResponse)
                    return
                }
                guard http.statusCode == 200 else {
                    continuation.resume(throwing: BaiduMapsError.http(status: http.statusCode))
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
            box.adopt(task)
            task.resume()
        }
    }

    /// Waits until this request is allowed to start, by concurrency and then by rate.
    private func enterGate() async {
        if inFlightRequests >= Self.maximumConcurrentRequests {
            // The slot is handed over directly by `leaveGate`, not released and re-taken, so a
            // third caller cannot slip in between.
            await withCheckedContinuation { waiting.append($0) }
        } else {
            inFlightRequests += 1
        }

        // The slot is reserved before the sleep: an actor releases its lock across an await, and
        // reading the next free instant, sleeping, then writing would let every waiter read the
        // same instant and wake together. There is no suspension point between these two lines.
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
        case .http(let status):
            summary = "HTTP \(status)"
            // Held off like one of Baidu's own refusals: a gateway error or intercepted response
            // does not clear within a second.
            refusedUntil[path] = ContinuousClock.now.advanced(by: Self.refusalHoldOff)
        case .budgetExhausted: summary = "this launch's own budget for this endpoint"
        case .refusedRecently: summary = "held off after a recent refusal"
        case .service(let status, let message):
            summary = message.isEmpty ? "status \(status)" : "\(status) \(message)"
            // Baidu's own refusals, not a transport failure (-1, which may succeed next time): 302
            // daily quota, 401 concurrency, 240 service disabled, 210/211 referer or IP rejected.
            if Self.refusalStatuses.contains(status) {
                refusedUntil[path] = ContinuousClock.now.advanced(by: Self.refusalHoldOff)
            }
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

/// A coordinate as Baidu returns it, requested as GCJ-02 on every endpoint, so nothing is converted
/// on arrival.
///
/// The parameter that asks for it differs per endpoint (`coord_type=gcj02` on directions,
/// `coord_type=2` on place search, `coordtype=gcj02ll` on reverse geocoding), each verified against
/// the live API: a wrong one returns plausible BD-09 a few hundred metres off, not an error.
struct BaiduCoordinate: Decodable, Sendable {
    let lat: Double
    let lng: Double
}
