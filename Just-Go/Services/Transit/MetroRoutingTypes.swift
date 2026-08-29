import CoreLocation
import MapKit

struct MetroRouteContext {
    /// Every pack the trip can use, not the single closest one. A trip from Foshan's metro to
    /// Guangzhou's crosses two packs and calls at an intercity corridor carried by both; picking
    /// one network made that trip unplannable rather than merely badly planned.
    let networks: [MetroNetwork]
    let originStations: [MetroStationCandidate]
    let destinationStations: [MetroStationCandidate]
    /// How far apart the two ends are in a straight line. The search compares its own walking
    /// against this: a ride whose access walks already cost more than going straight there has
    /// not helped, whatever it did in between.
    let directDistance: Double
}

struct MetroRoutingGraph {
    let stationsByID: [String: MetroStation]
    let linesByID: [String: MetroLine]
    let adjacency: [String: [MetroGraphEdge]]
    let edgeGeometries: [MetroGraphEdgeKey: [CodableCoordinate]]
    /// Which pack each station came from. The graph spans several, and every rider-facing station
    /// ID is `network-<city>-<station>`, so the city is a property of the station now, not of the
    /// search.
    let cityIDByStationID: [String: String]
    /// Duplicate copies of one line, mapped onto the copy that survived. A station's own `lineIDs`
    /// name its pack's copies, so anything counting a station's lines has to come through here or
    /// it undercounts: an interchange onto a shared intercity corridor would read as one line.
    let canonicalLineIDs: [String: String]

    func cityID(for stationID: String) -> String {
        cityIDByStationID[stationID] ?? ""
    }

    /// How many of the graph's lines call at this station. The test for "this is an interchange".
    func lineCount(for station: MetroStation) -> Int {
        Set(station.lineIDs.map { canonicalLineIDs[$0] ?? $0 }.filter { linesByID[$0] != nil }).count
    }

    /// The `network-<city>-<station>` identifier the rest of the app indexes stations by.
    func qualifiedID(for stationID: String) -> String {
        MetroStationIdentifier.qualified(cityID: cityID(for: stationID), stationID: stationID)
    }
}

struct MetroStationCandidate {
    let station: MetroStation
    let distance: Double
}

struct MetroGraphEdge {
    let fromStationID: String
    let toStationID: String
    let lineID: String
    let distance: Double
    /// nil for a ride between two stops. Set to the declared link between two stations riders
    /// treat as one interchange, which is walked rather than ridden and belongs to no line.
    var interchange: MetroInterchange? = nil

    var reversed: MetroGraphEdge {
        MetroGraphEdge(
            fromStationID: toStationID,
            toStationID: fromStationID,
            lineID: lineID,
            distance: distance,
            interchange: interchange
        )
    }

    var key: MetroGraphEdgeKey {
        MetroGraphEdgeKey(fromStationID: fromStationID, toStationID: toStationID, lineID: lineID)
    }
}

struct MetroGraphEdgeKey: Hashable {
    let fromStationID: String
    let toStationID: String
    let lineID: String
}

/// The synthetic line an interchange link rides on. Interchange links belong to no real line, and
/// the route assembly chunks by line. Giving them their own identifier is what keeps them from
/// being folded into the ride on either side of them.
let metroInterchangeLineID = "__interchange__"


struct MetroPath {
    let origin: MetroStationCandidate
    let destination: MetroStationCandidate
    let edges: [MetroGraphEdge]
}

struct MetroSearchState: Hashable {
    let stationID: String
    let lineID: String?
}

struct MetroPreviousStep {
    let state: MetroSearchState
    let edge: MetroGraphEdge
}

enum MetroSearchPreference {
    case fastest
    case fewestTransfers
    case leastWalking

    var transferPenalty: Double {
        self == .fewestTransfers ? 1_200 : 300
    }

    var walkingWeight: Double {
        self == .leastWalking ? 3 : 1
    }

    var strategy: RouteStrategy {
        switch self {
        case .fastest: return .fastest
        case .fewestTransfers: return .fewestTransfers
        case .leastWalking: return .leastWalking
        }
    }
}

struct MetroQueueItem {
    let state: MetroSearchState
    let cost: Double
}

struct MetroMinHeap {
    private var values: [MetroQueueItem] = []

    mutating func insert(_ value: MetroQueueItem) {
        values.append(value)
        var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard values[index].cost < values[parent].cost else { break }
            values.swapAt(index, parent)
            index = parent
        }
    }

    mutating func removeMin() -> MetroQueueItem? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]
        values[0] = values.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            let right = left + 1
            var smallest = index
            if left < values.count && values[left].cost < values[smallest].cost { smallest = left }
            if right < values.count && values[right].cost < values[smallest].cost { smallest = right }
            guard smallest != index else { break }
            values.swapAt(index, smallest)
            index = smallest
        }
        return result
    }
}

/// Where the ride between two adjacent stations is drawn.
///
/// One resolver, used wherever track is drawn, because the alternative is what shipped: the route
/// map sliced OSM ways per edge while the browse map drew the raw way, so the same corridor could
/// be continuous on one screen and broken on the other.
enum MetroTrackGeometry {
    /// The track between two adjacent stations. The line's own geometry, clipped to this hop, and
    /// **never** empty.
    ///
    /// Returning nothing was the old answer whenever the way could not be sliced sensibly, and it
    /// left a hole rather than a straight line: a leg's polyline is the concatenation of its edges,
    /// so one empty edge in the middle stops the drawn line dead. 深井 → 琶洲 did exactly that, and
    /// the Guangzhou intercity leg ended 5.5 km short of the station it claimed to reach while the
    /// leg as a whole still had 44 points, so no "this segment has no shape" fallback could fire.
    /// A straight chord says "these two are connected, the shape is unknown"; a gap says nothing.
    ///
    /// The ends are the stations' **projections onto the track**, not the stations themselves.
    /// This is where the train runs, and a station node can sit a few hundred metres off it. What
    /// closes that gap is a grey connector drawn by `TransitMapView`, not a detour bolted onto the
    /// coloured line; see `addStationConnectors`.
    static func edge(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        separation: Double,
        line: MetroLine
    ) -> [CodableCoordinate] {
        let chord = [from, to]
        // Project each station onto the polyline itself, never snap to vertices: OSM ways
        // can run kilometres between vertices (Beijing Line 2's whole ring is 48 points),
        // so the nearest VERTEX can sit 1km+ past the station and the drawn ride overshoots
        // or stops short by that much.
        let matches = line.paths.compactMap { path -> (path: [MetroCoordinate], cumulative: [Double], from: PathProjection, to: PathProjection)? in
            guard path.count >= 2 else { return nil }
            let points = path.map(\.coordinate)
            var cumulative: [Double] = [0]
            cumulative.reserveCapacity(points.count)
            for index in 1..<points.count {
                cumulative.append(cumulative[index - 1] + points[index - 1].distance(to: points[index]))
            }
            guard let fromProjection = projection(of: from, onto: points, cumulative: cumulative),
                  let toProjection = projection(of: to, onto: points, cumulative: cumulative) else {
                return nil
            }
            return (path, cumulative, fromProjection, toProjection)
        }
        guard let match = matches.min(by: { ($0.from.distance + $0.to.distance) < ($1.from.distance + $1.to.distance) }),
              match.from.distance + match.to.distance < 2_000 else {
            return chord.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        }

        let points = match.path.map(\.coordinate)
        let total = match.cumulative[match.cumulative.count - 1]
        let isRing = points.count >= 3 && points[0].distance(to: points[points.count - 1]) < 5
        let lowOffset = min(match.from.pathOffset, match.to.pathOffset)
        let highOffset = max(match.from.pathOffset, match.to.pathOffset)
        let reversed = match.from.pathOffset > match.to.pathOffset
        let lowPoint = reversed ? match.to.point : match.from.point
        let highPoint = reversed ? match.from.point : match.to.point

        var slice: [CLLocationCoordinate2D]
        if !isRing || highOffset - lowOffset <= total - (highOffset - lowOffset) {
            // Direct arc: projected endpoint, the vertices strictly between the two
            // offsets, projected endpoint.
            slice = [lowPoint]
            for index in points.indices where match.cumulative[index] > lowOffset && match.cumulative[index] < highOffset {
                slice.append(points[index])
            }
            slice.append(highPoint)
        } else {
            // Closed ring where the seam-crossing arc is shorter: walk from the higher
            // offset forward off the end of the array and back in at the start. The ring's
            // duplicated closing vertex meets the first vertex at the seam. Dedup it.
            slice = [highPoint]
            for index in points.indices where match.cumulative[index] > highOffset {
                slice.append(points[index])
            }
            for index in points.indices where match.cumulative[index] < lowOffset {
                if let last = slice.last, last.distance(to: points[index]) < 1 { continue }
                slice.append(points[index])
            }
            slice.append(lowPoint)
            slice.reverse()
        }
        if reversed {
            slice.reverse()
        }

        // A slice grossly longer than the stations' straight-line separation is a bad match (wrong
        // path variant, self-approaching geometry). 广州东环-琶莲-佛莞城际 ships as one 187.5 km way
        // whose point order does not follow the service order, which puts 琶洲 and 深井 59.3 km
        // apart along a hop that is 5.5 km across.
        guard slice.count >= 2, arcLength(slice) <= max(2.5 * separation, separation + 1_500) else {
            return chord.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        }
        // The track and nothing else: the line's own geometry, clipped to this hop.
        //
        // This used to prepend `from` and append `to`, so that a station sitting off its way kept
        // "both facts". Drawn, that is a spike from the platform out to the rail and back, and at
        // a station far enough off it reads as a rectangle bolted to the route: 顺义 sits 272 m
        // from 15号线's track and 366 m from 市郊铁路通密线's, and both lines drew the detour, at
        // right angles, over each other. 339 of 8,108 station-on-line pairs are more than 60 m off
        // their own track, so this is not one bad node.
        //
        // The train does not go to the station building; it goes along the track. Drawing the
        // track is the true statement, and it makes the ride identical to what the browse map
        // draws for the same stretch, which is the point. Two maps, one geometry.
        //
        // Joints still land: consecutive hops on one leg share a station projected onto the *same*
        // path, so they meet exactly. Where two legs meet at a change, the transfer segment now
        // carries the platform-to-platform link that covers the offset (see `interchangeSegment`
        // and the in-station transfer in `transitSegments`).
        var joined: [CLLocationCoordinate2D] = []
        for point in slice where (joined.last.map { $0.distance(to: point) >= 1 } ?? true) {
            joined.append(point)
        }
        guard joined.count >= 2 else { return chord.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) } }
        return joined.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// A station's closest point ON a path's polyline (not its closest vertex): the point,
    /// how far the station sits from the track, and the point's arc-length offset from the
    /// path start, which is what the slicer walks by.
    private struct PathProjection {
        let point: CLLocationCoordinate2D
        let distance: Double
        let pathOffset: Double
    }

    /// Nearest point on the polyline to `coordinate`, via point-to-segment projection in a
    /// small local planar frame (metres-per-degree at the segment; exact enough at station
    /// scale, and far cheaper than geodesic projection).
    private static func projection(
        of coordinate: CLLocationCoordinate2D,
        onto points: [CLLocationCoordinate2D],
        cumulative: [Double]
    ) -> PathProjection? {
        guard points.count >= 2 else { return nil }
        var best: PathProjection?
        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            let metersPerDegreeLongitude = 111_320.0 * cos(a.latitude * .pi / 180)
            let metersPerDegreeLatitude = 110_540.0
            let ax = a.longitude * metersPerDegreeLongitude, ay = a.latitude * metersPerDegreeLatitude
            let bx = b.longitude * metersPerDegreeLongitude, by = b.latitude * metersPerDegreeLatitude
            let px = coordinate.longitude * metersPerDegreeLongitude, py = coordinate.latitude * metersPerDegreeLatitude
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
            let projected = CLLocationCoordinate2D(
                latitude: (ay + t * dy) / metersPerDegreeLatitude,
                longitude: (ax + t * dx) / metersPerDegreeLongitude
            )
            let distance = coordinate.distance(to: projected)
            if best == nil || distance < best!.distance {
                let segmentLength = cumulative[index + 1] - cumulative[index]
                best = PathProjection(
                    point: projected,
                    distance: distance,
                    pathOffset: cumulative[index] + t * segmentLength
                )
            }
        }
        return best
    }

    private static func arcLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var total: Double = 0
        for index in 1..<coordinates.count {
            total += coordinates[index - 1].distance(to: coordinates[index])
        }
        return total
    }
}

extension MetroStation {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MetroCoordinate {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Array {
    var adjacentPairs: [(Element, Element)] {
        zip(self, dropFirst()).map { ($0, $1) }
    }

    func chunked(where belongsTogether: (Element, Element) -> Bool) -> [[Element]] {
        guard let first else { return [] }
        var chunks = [[first]]
        for item in dropFirst() {
            if let previous = chunks.last?.last, belongsTogether(previous, item) {
                chunks[chunks.count - 1].append(item)
            } else {
                chunks.append([item])
            }
        }
        return chunks
    }
}

extension Array where Element: Equatable {
    var consecutiveUnique: [Element] {
        reduce(into: []) { result, item in
            if result.last != item { result.append(item) }
        }
    }
}

extension MKPolyline {
    var routeCoordinates: [CLLocationCoordinate2D] {
        var values = Array(repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&values, range: NSRange(location: 0, length: pointCount))
        return values
    }
}
