import CoreLocation
import Foundation

/// Layouts in metres east and north of a station at 39.9° N, where `InterchangePlacement` works.
private let base = CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4)
private let metresPerDegreeLatitude = Double.pi / 180 * 6_371_000
private let metresPerDegreeLongitude = metresPerDegreeLatitude * cos(base.latitude * .pi / 180)

private func at(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: base.latitude + north / metresPerDegreeLatitude,
        longitude: base.longitude + east / metresPerDegreeLongitude
    )
}

private func offset(of coordinate: CLLocationCoordinate2D) -> (east: Double, north: Double) {
    (
        (coordinate.longitude - base.longitude) * metresPerDegreeLongitude,
        (coordinate.latitude - base.latitude) * metresPerDegreeLatitude
    )
}

private func line(_ points: (Double, Double)...) -> [[CLLocationCoordinate2D]] {
    [points.map { at($0.0, $0.1) }]
}

@main
@MainActor
struct InterchangePlacementTests {
    private static var failures = 0

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    private static func expect(
        _ placement: InterchangePlacement.Placement,
        is kind: InterchangePlacement.Kind,
        near east: Double,
        _ north: Double,
        _ name: String
    ) {
        let (x, y) = offset(of: placement.coordinate)
        let miss = ((x - east) * (x - east) + (y - north) * (y - north)).squareRoot()
        expect(placement.kind == kind, "\(name): kind \(placement.kind), expected \(kind)")
        expect(miss < 0.5, "\(name): placed at (\(x), \(y)), expected (\(east), \(north))")
    }

    static func main() throws {
        if let index = CommandLine.arguments.firstIndex(of: "--networks"),
           CommandLine.arguments.count > index + 1 {
            try survey(CommandLine.arguments[index + 1])
            return
        }

        // Two lines crossing 40 m east and 30 m south of the station's point: the crossing.
        expect(
            InterchangePlacement.place(station: base, lineTracks: [
                line((40, -500), (40, 500)),
                line((-500, -30), (500, -30))
            ]),
            is: .crossing, near: 40, -30, "perpendicular crossing"
        )

        // Side by side 15 m apart, the station between them: it already is where they meet.
        expect(
            InterchangePlacement.place(station: base, lineTracks: [
                line((-7.5, -500), (-7.5, 500)),
                line((7.5, -500), (7.5, 500))
            ]),
            is: .unmoved, near: 0, 0, "side by side, station between"
        )

        // Side by side 15 m apart and both east of the station: between them.
        expect(
            InterchangePlacement.place(station: base, lineTracks: [
                line((20, -500), (20, 500)),
                line((35, -500), (35, 500))
            ]),
            is: .sideBySide, near: 27.5, 0, "side by side, station to one side"
        )

        // Side by side through the station, crossing 280 m on (郭公庄): not the crossing.
        expect(
            InterchangePlacement.place(station: base, lineTracks: [
                line((-6, -500), (-6, 270), (6, 290), (6, 500)),
                line((6, -500), (6, 270), (-6, 290), (-6, 500))
            ]),
            is: .unmoved, near: 0, 0, "shallow crossing beyond the platforms"
        )

        // 270 m apart and never meeting (前门): no point between them is a junction.
        expect(
            InterchangePlacement.place(station: base, lineTracks: [
                line((-500, 0), (500, 0)),
                line((-500, 270), (500, 270))
            ]),
            is: .unmoved, near: 0, 0, "lines that never meet"
        )

        // One track under two line IDs: on it, at the point nearest the station. Collinear segments
        // have no single crossing; the two tracks are side by side at no distance at all.
        let shared = line((-500, 20), (0, 20), (500, 20))
        expect(
            InterchangePlacement.place(station: base, lineTracks: [shared, shared]),
            is: .sideBySide, near: 0, 20, "shared track"
        )

        // Only one line has track near the station.
        expect(
            InterchangePlacement.place(station: base, lineTracks: [
                line((40, -500), (40, 500)),
                line((-500, 400), (500, 400))
            ]),
            is: .untracked, near: 0, 0, "second line out of reach"
        )

        // Both lines pass within reach (200 m and 250 m), but they cross 320 m away.
        expect(
            InterchangePlacement.place(station: base, lineTracks: [
                line((-500, -200), (500, -200)),
                line((250, -500), (250, 500))
            ]),
            is: .unmoved, near: 0, 0, "crossing out of reach"
        )

        // Three lines meeting pairwise in a small triangle: on the crossing nearest all three, the
        // third line passing 28 m from it.
        expect(
            InterchangePlacement.place(station: base, lineTracks: [
                line((30, -500), (30, 500)),
                line((-500, -20), (500, -20)),
                line((-500, -510), (500, 490))
            ]),
            is: .crossing, near: 30, -20, "three lines"
        )

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("interchange placement: all cases passed")
    }

    // MARK: - Every bundled network, for comparing with the design measurements and timing it

    private struct Network: Decodable {
        struct Coordinate: Decodable {
            let latitude: Double
            let longitude: Double
        }

        struct Line: Decodable {
            let id: String
            let paths: [[Coordinate]]
        }

        struct Station: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let lineIDs: [String]
        }

        let cityID: String
        let lines: [Line]
        let stations: [Station]
    }

    private static func survey(_ folder: String) throws {
        let urls = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var counts: [String: Int] = [:]
        var moves: [Double] = []
        var slowest: [(city: String, milliseconds: Double, interchanges: Int)] = []
        for url in urls {
            let network = try JSONDecoder().decode(Network.self, from: Data(contentsOf: url))
            let tracks = Dictionary(
                network.lines.map { line in
                    (line.id, line.paths.map { $0.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } })
                },
                uniquingKeysWith: { first, _ in first }
            )
            let interchanges = network.stations.filter { Set($0.lineIDs).count > 1 }
            let start = Date()
            for station in interchanges {
                var seen = Set<String>()
                let ids = station.lineIDs.filter { seen.insert($0).inserted }
                let point = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
                let placement = InterchangePlacement.place(station: point, lineTracks: ids.compactMap { tracks[$0] })
                counts["\(placement.kind)", default: 0] += 1
                if placement.kind == .crossing || placement.kind == .sideBySide {
                    let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
                    moves.append(location.distance(from: CLLocation(
                        latitude: placement.coordinate.latitude,
                        longitude: placement.coordinate.longitude
                    )))
                }
                if network.cityID == "1100", ["东四", "王府井", "崇文门", "国贸", "郭公庄", "西二旗", "前门", "三元桥", "西苑"].contains(station.name) {
                    print("  \(station.name): \(placement.kind)")
                }
            }
            slowest.append((network.cityID, Date().timeIntervalSince(start) * 1000, interchanges.count))
        }
        moves.sort()
        print("by kind: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        if !moves.isEmpty {
            let percentile = { (q: Double) in Int(moves[Int((q * Double(moves.count - 1)).rounded())].rounded()) }
            print("moved: p50 \(percentile(0.5)) m, p90 \(percentile(0.9)) m, max \(Int(moves.last!.rounded())) m")
        }
        for entry in slowest.sorted(by: { $0.milliseconds > $1.milliseconds }).prefix(3) {
            print(String(format: "  %@: %.1f ms for %d interchanges", entry.city, entry.milliseconds, entry.interchanges))
        }
    }
}
