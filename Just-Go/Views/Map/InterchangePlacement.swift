import CoreLocation
import Foundation

/// Where an interchange's symbol is drawn: where its lines meet, rather than on the station's own
/// point. OpenStreetMap puts an interchange's point in the middle of the station complex, often tens
/// of metres off every line it joins, while an ordinary stop's point sits on its track. Only the
/// drawing moves: the station's coordinate, its doors and every walk to it are unchanged.
///
/// Free of app types, so `Scripts/test_interchange_placement.sh` compiles it alone.
enum InterchangePlacement {
    /// How far a line's track may pass from the station's point and still count, and how far a
    /// crossing may be from it and still be this station's.
    static let reach: Double = 300

    /// Two tracks whose nearest points to the station are this close run side by side through it, as
    /// at a cross-platform interchange, and the symbol goes between them.
    static let sideBySide: Double = 50

    /// What a metre away from the station's own point costs, against a metre away from one of its
    /// lines. Under 1, so a crossing beats the station's point; at 0.25 it does so only where the
    /// lines meet at more than about 14°. Shallower than that they run alongside each other, and a
    /// crossing further on is not the station: 郭公庄's two lines share its platforms and cross 282 m
    /// beyond them.
    static let stationPull: Double = 0.25

    enum Kind: Equatable {
        /// Fewer than two of the lines have track within `reach`: nothing to place against.
        case untracked
        /// The station's own point scores best: its lines do not meet near it (前门's two lines stay
        /// 270 m apart), or it already sits between them.
        case unmoved
        /// On a crossing of two of its lines.
        case crossing
        /// Between two lines running side by side.
        case sideBySide
    }

    struct Placement {
        let coordinate: CLLocationCoordinate2D
        let kind: Kind
    }

    /// - Parameters:
    ///   - station: The station's own point.
    ///   - lineTracks: One entry per line through the station, each the line's drawn paths.
    static func place(
        station: CLLocationCoordinate2D,
        lineTracks: [[[CLLocationCoordinate2D]]]
    ) -> Placement {
        let untracked = Placement(coordinate: station, kind: .untracked)
        // A plane in metres around the station; over `reach` its error is far under a metre.
        let metresPerDegreeLatitude = Double.pi / 180 * 6_371_000
        let metresPerDegreeLongitude = metresPerDegreeLatitude * cos(station.latitude * .pi / 180)
        guard metresPerDegreeLongitude > 0 else { return untracked }
        func project(_ coordinate: CLLocationCoordinate2D) -> Point {
            Point(
                x: (coordinate.longitude - station.longitude) * metresPerDegreeLongitude,
                y: (coordinate.latitude - station.latitude) * metresPerDegreeLatitude
            )
        }

        let origin = Point(x: 0, y: 0)
        let lines: [[Segment]] = lineTracks.compactMap { paths in
            var segments: [Segment] = []
            for path in paths where path.count >= 2 {
                var previous = project(path[0])
                for coordinate in path.dropFirst() {
                    let next = project(coordinate)
                    let segment = Segment(a: previous, b: next)
                    if segment.nearestPoint(to: origin).length <= reach {
                        segments.append(segment)
                    }
                    previous = next
                }
            }
            return segments.isEmpty ? nil : segments
        }
        guard lines.count >= 2 else { return untracked }

        let nearest = lines.map { segments in
            segments.map { $0.nearestPoint(to: origin) }.min { $0.length < $1.length } ?? origin
        }
        var candidates: [(point: Point, kind: Kind)] = [(origin, .unmoved)]
        for first in lines.indices {
            for second in lines.indices where second > first {
                for segment in lines[first] {
                    for other in lines[second] {
                        if let crossing = segment.intersection(with: other), crossing.length <= reach {
                            candidates.append((crossing, .crossing))
                        }
                    }
                }
                if (nearest[first] - nearest[second]).length <= sideBySide {
                    candidates.append(((nearest[first] + nearest[second]) * 0.5, .sideBySide))
                }
            }
        }

        func score(_ point: Point) -> Double {
            var total = stationPull * point.length
            for segments in lines {
                total += segments.map { ($0.nearestPoint(to: point) - point).length }.min() ?? 0
            }
            return total
        }
        // The station's point is first, so a tie keeps the symbol where it was.
        var best = candidates[0]
        var bestScore = score(best.point)
        for candidate in candidates.dropFirst() {
            let candidateScore = score(candidate.point)
            if candidateScore < bestScore {
                best = candidate
                bestScore = candidateScore
            }
        }
        // Under a metre is the same place at every zoom.
        guard best.kind != .unmoved, best.point.length >= 1 else {
            return Placement(coordinate: station, kind: .unmoved)
        }
        return Placement(
            coordinate: CLLocationCoordinate2D(
                latitude: station.latitude + best.point.y / metresPerDegreeLatitude,
                longitude: station.longitude + best.point.x / metresPerDegreeLongitude
            ),
            kind: best.kind
        )
    }

    private struct Point {
        var x: Double
        var y: Double

        var length: Double { (x * x + y * y).squareRoot() }

        static func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
        static func - (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
        static func * (lhs: Point, rhs: Double) -> Point { Point(x: lhs.x * rhs, y: lhs.y * rhs) }
    }

    private struct Segment {
        let a: Point
        let b: Point

        func nearestPoint(to point: Point) -> Point {
            let along = b - a
            let lengthSquared = along.x * along.x + along.y * along.y
            guard lengthSquared > 0 else { return a }
            let t = ((point.x - a.x) * along.x + (point.y - a.y) * along.y) / lengthSquared
            return a + along * min(max(t, 0), 1)
        }

        /// Where the two cross, ends included. Parallel segments, overlapping ones among them, have
        /// no single crossing; two lines sharing track still meet at the vertices they share.
        func intersection(with other: Segment) -> Point? {
            let r = b - a
            let s = other.b - other.a
            let denominator = r.x * s.y - r.y * s.x
            guard abs(denominator) > 1e-9 else { return nil }
            let offset = other.a - a
            let t = (offset.x * s.y - offset.y * s.x) / denominator
            let u = (offset.x * r.y - offset.y * r.x) / denominator
            let tolerance = 1e-9
            guard t >= -tolerance, t <= 1 + tolerance, u >= -tolerance, u <= 1 + tolerance else { return nil }
            return a + r * t
        }
    }
}
