import CryptoKit
import Foundation

/// Credentials and endpoint for Baidu's Web Service API.
///
/// The 服务端 (server) key type is deliberate. The alternative — an iOS-type key with Baidu's
/// native SDK — would bind the key to the bundle ID, which is better for key safety, but it also
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
    /// must build and run without one — a missing key is a normal state, not an error.
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
    /// PHP's `urlencode`, which is what Baidu's reference implementations use — note space becomes
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
    /// Baidu answered, and said no. `status` is its own code — 302/210 are quota and permission.
    case service(status: Int, message: String)
    case malformedResponse
    /// This launch has already made as many calls to that endpoint as it is allowed. Local, so it
    /// costs no round trip, and indistinguishable to every caller from having no key at all.
    case budgetExhausted(path: String)
}

/// Every Baidu Web Service response carries this envelope, and a non-zero `status` means the
/// payload is absent or meaningless — so it is checked before anything is decoded.
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

    let configuration: BaiduMapsConfiguration
    private let session: URLSession
    private var spent: [String: Int] = [:]

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

        // Checked before the request is built, so an exhausted budget costs nothing at all. Every
        // caller already treats a throw as "no answer" and falls back, so this needs no new
        // handling anywhere: it degrades the app to what it is with no key.
        if let ceiling = RequestBudget.ceilings[path] {
            let used = spent[path, default: 0]
            guard used < ceiling else { throw BaiduMapsError.budgetExhausted(path: path) }
            spent[path] = used + 1
        }

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

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw BaiduMapsError.service(status: -1, message: error.localizedDescription)
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw BaiduMapsError.malformedResponse
        }
        guard decoded.status == 0 else {
            throw BaiduMapsError.service(status: decoded.status, message: decoded.message ?? "")
        }
        return decoded
    }
}

/// A coordinate as Baidu returns it. Requested as GCJ-02 on every endpoint, which is the frame the
/// rest of this app draws and measures in, so nothing needs converting on arrival.
///
/// Note the parameter that asks for it differs per endpoint — `coord_type=gcj02` on directions,
/// `coord_type=2` on place search, `coordtype=gcj02ll` on reverse geocoding. They were each
/// verified against the live API rather than inferred, because a wrong one is not an error: it
/// returns BD-09 that looks plausible and lands a few hundred metres away.
struct BaiduCoordinate: Decodable, Sendable {
    let lat: Double
    let lng: Double
}
