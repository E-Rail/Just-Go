import CoreLocation
import Foundation

/// How far a rider actually walks between two platforms, in metres.
///
/// The metres are the point. Baidu also returns a duration for the same step, and it was measured
/// across 26 interchanges to be exactly `distance ÷ 1.19 m/s` every time — standard deviation
/// 0.0075 — so it is arithmetic, not observation: no stairs, no escalators, no waiting, no crowds.
/// This app already divides by 1.25 m/s in `BundledMetroRouteProvider`, so Baidu's seconds would
/// add nothing while sounding like they had. The distance is the part the app genuinely does not
/// have: 1,153 of its interchanges are two lines meeting at one node with no geometry at all.
struct TransferGeometry: Equatable, Sendable {
    let stationName: String
    let fromLineName: String
    let toLineName: String
    let distanceMetres: Int
}

/// The port a better source of transfer geometry arrives through.
///
/// Deliberately not tied to Baidu. If an operator ever publishes real corridor lengths, or the
/// riders' own answers accumulate into something better, they implement this and nothing else moves.
protocol TransferGeometryProviding: Sendable {
    /// Every interchange Baidu describes for this trip. One call per trip, not one per transfer.
    func geometries(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> [TransferGeometry]
}

/// Reads transfer corridor lengths out of Baidu's transit routing.
///
/// There is no endpoint that answers "how far is the change at 西单 between lines 4 and 1", so the
/// distances are harvested from a route that happens to contain the interchange: ask for the trip
/// the rider is already taking, then keep the walking steps that sit between two rides.
///
/// **Nothing is written to disk.** Baidu's terms forbid storing or caching what the service
/// releases, so results live in memory for the session and are gone on relaunch. That is a real
/// cost — the app's own graph stays the offline answer and this is online enrichment on top — but
/// it is the honest reading of the licence, and `validate_runtime_data_policy.rb` enforces that no
/// Baidu-derived byte is ever committed.
actor BaiduTransferGeometryService: TransferGeometryProviding {
    private let client: BaiduMapsClient
    /// Session-scoped, in memory only. See the note above on why this is not a disk cache.
    private var cache: [String: [TransferGeometry]] = [:]

    init(client: BaiduMapsClient) {
        self.client = client
    }

    func geometries(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> [TransferGeometry] {
        let cacheKey = String(
            format: "%.4f,%.4f>%.4f,%.4f",
            origin.latitude, origin.longitude, destination.latitude, destination.longitude
        )
        if let cached = cache[cacheKey] { return cached }

        let response: BaiduTransitResponse
        do {
            response = try await client.get(
                BaiduTransitResponse.self,
                path: "/direction/v2/transit",
                parameters: [
                    (name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
                    (name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
                    (name: "coord_type", value: "gcj02"),
                    (name: "ret_coordtype", value: "gcj02")
                ]
            )
        } catch {
            AppLog.routing.info("Baidu transfer geometry unavailable: \(error)")
            return []
        }

        var found: [String: TransferGeometry] = [:]
        for route in response.result?.routes ?? [] {
            let steps = route.steps.flatMap(\.steps)
            for index in steps.indices {
                guard let geometry = Self.transferGeometry(at: index, in: steps) else { continue }
                // First writer wins: Baidu returns up to five routes and the same interchange
                // recurs across them with identical geometry.
                let key = "\(geometry.stationName)|\(geometry.fromLineName)|\(geometry.toLineName)"
                if found[key] == nil { found[key] = geometry }
            }
        }
        let geometries = Array(found.values)
        cache[cacheKey] = geometries
        return geometries
    }

    /// A transfer is a walking step with a ride on both sides. Recognising it structurally beats
    /// reading the Chinese instruction text ("站内通道换乘"), which is not present in every city.
    private static func transferGeometry(at index: Int, in steps: [BaiduStep]) -> TransferGeometry? {
        guard index > 0, index < steps.count - 1 else { return nil }
        let step = steps[index]
        guard step.isWalking, let distance = step.distance, distance > 0 else { return nil }

        let before = steps[index - 1]
        let after = steps[index + 1]
        guard before.isRail, after.isRail,
              let fromLine = before.vehicleInfo?.detail?.name,
              let toLine = after.vehicleInfo?.detail?.name,
              let station = before.vehicleInfo?.detail?.offStation else { return nil }

        return TransferGeometry(
            stationName: TransitLineMatching.normalizedStationName(station),
            fromLineName: fromLine,
            toLineName: toLine,
            distanceMetres: distance
        )
    }
}

/// Matching Baidu's line and station names onto this app's own.
///
/// Baidu says "地铁4号线大兴线" where a pack says "4号线", and "新街口站(A西北口)" where the graph
/// says "新街口". Everything here fails closed: when a name cannot be matched confidently the
/// caller gets nothing and the screen says nothing, which is the correct outcome for an app whose
/// rule is that an unverified number is worse than a blank.
enum TransitLineMatching {
    /// Buses are excluded on purpose — the product deliberately routes rail only, and Baidu returns
    /// bus interchanges freely (`84路` → `665路`) that would otherwise be silently mixed in.
    static func isRailLine(_ name: String) -> Bool {
        let railMarkers = ["地铁", "轨道", "轻轨", "磁浮", "磁悬浮", "有轨电车", "APM", "MTR"]
        if railMarkers.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return true }
        // Latin-script networks (Hong Kong, Taipei) say "Line 1" / "Tsuen Wan Line".
        return name.localizedCaseInsensitiveContains("line")
    }

    static func normalizedStationName(_ name: String) -> String {
        var trimmed = name
        if let parenthesis = trimmed.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            trimmed = String(trimmed[trimmed.startIndex..<parenthesis])
        }
        if trimmed.hasSuffix("站") { trimmed.removeLast() }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let lineNumberPattern = try! NSRegularExpression(pattern: "([0-9]+)\\s*号线")

    /// The comparable core of a line name: its number where it has one, otherwise the name with
    /// network words and direction markers stripped.
    static func normalizedLineToken(_ name: String) -> String {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        if let match = lineNumberPattern.firstMatch(in: name, range: range),
           let numberRange = Range(match.range(at: 1), in: name) {
            return String(name[numberRange])
        }
        var token = name
        for noise in ["地铁", "轨道交通", "轻轨", "内环", "外环", "上行", "下行", "Line", "line"] {
            token = token.replacingOccurrences(of: noise, with: "")
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func linesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedLineToken(lhs)
        let right = normalizedLineToken(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }
}

extension TransferGeometry {
    /// Whether this describes the same change the rider is standing in. Direction-independent: a
    /// rider going 4→1 and one going 1→4 walk the same corridor.
    func matches(_ key: TransferKey) -> Bool {
        guard TransitLineMatching.normalizedStationName(key.stationID) == stationName else { return false }
        let forward = TransitLineMatching.linesMatch(key.fromLineID, fromLineName)
            && TransitLineMatching.linesMatch(key.toLineID, toLineName)
        let reverse = TransitLineMatching.linesMatch(key.fromLineID, toLineName)
            && TransitLineMatching.linesMatch(key.toLineID, fromLineName)
        return forward || reverse
    }
}

// MARK: - Wire responses

private struct BaiduTransitResponse: BaiduResponseEnvelope {
    let status: Int
    let message: String?
    let result: Result?

    struct Result: Decodable, Sendable {
        let routes: [Route]?
    }

    struct Route: Decodable, Sendable {
        let steps: [BaiduStepGroup]
    }
}

/// Baidu nests same-city steps one level deeper than cross-city ones: an element of `steps` is
/// sometimes an object and sometimes an array of them. Codable cannot express "either" without
/// this, and assuming one shape decodes the other as a hard failure.
private struct BaiduStepGroup: Decodable, Sendable {
    let steps: [BaiduStep]

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var collected: [BaiduStep] = []
            while !unkeyed.isAtEnd {
                collected.append(try unkeyed.decode(BaiduStep.self))
            }
            steps = collected
        } else {
            steps = [try BaiduStep(from: decoder)]
        }
    }
}

private struct BaiduStep: Decodable, Sendable {
    let distance: Int?
    let duration: Int?
    let vehicleInfo: VehicleInfo?

    enum CodingKeys: String, CodingKey {
        case distance, duration
        case vehicleInfo = "vehicle_info"
    }

    /// Baidu's own encoding: 3 is a scheduled vehicle (bus or rail), 5 is walking.
    var isWalking: Bool { (vehicleInfo?.type ?? 5) == 5 }
    var isRail: Bool {
        vehicleInfo?.type == 3 && TransitLineMatching.isRailLine(vehicleInfo?.detail?.name ?? "")
    }

    struct VehicleInfo: Decodable, Sendable {
        let type: Int?
        let detail: Detail?

        struct Detail: Decodable, Sendable {
            let name: String?
            let offStation: String?

            enum CodingKeys: String, CodingKey {
                case name
                case offStation = "off_station"
            }
        }
    }
}
