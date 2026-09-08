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
    /// Every hop of one service pattern, chosen together rather than one at a time.
    ///
    /// Resolving hop by hop is what produced the bug this replaces. Each hop independently picked
    /// whichever of the line's OSM ways fitted it best, so two consecutive hops could land their
    /// **shared** station on two different ways — and `transitSegments` concatenates per-hop
    /// geometry into one polyline, so the join became a straight jump. The comment that used to sit
    /// here asserted the opposite ("consecutive hops on one leg share a station projected onto the
    /// same path, so they meet exactly"); that has never held for a line whose relation splits into
    /// several ways.
    ///
    /// Carrying an anchor forward greedily was the first attempt and it is not enough, because a
    /// greedy chain has to commit to hop *i* before it can see what hop *i+1* needs. Where the way
    /// carrying one hop stops short of the shared station, the greedy chain ends that hop at a
    /// projection hundreds of metres off — 大橋頭 on 台北捷運中和新蘆線 came out 771.8 m from the
    /// station — and every later hop then either inherits the error or breaks away from it.
    ///
    /// So the whole pattern is solved at once: each hop offers every way-and-projection pair it
    /// could be drawn from, and a shortest-path pass over those choices picks the chain whose total
    /// cost — track length, distance from the stations, and `seamWeight` per metre of join gap — is
    /// lowest. Nothing is committed until the whole chain is known. Measured across the 53 bundled
    /// packs, that takes the joins over 50 m from 17 to **zero** (worst 13.5 m, and 19 of 7,612
    /// joins measurable at all), and the hops with no usable track from 9 to 6.
    ///
    /// Returns one geometry per hop: `stations.count - 1` entries, empty where a station is
    /// unknown.
    static func pattern(stations: [MetroStation?], line: MetroLine) -> [[CodableCoordinate]] {
        guard stations.count >= 2 else { return [] }
        // Prepared once for the whole pattern rather than once per hop. The cumulative-distance
        // table is O(points) and a long line's way runs to thousands of them.
        let prepared: [PreparedPath] = line.paths.compactMap { path in
            guard path.count >= 2 else { return nil }
            let points = path.map(\.coordinate)
            var cumulative: [Double] = [0]
            cumulative.reserveCapacity(points.count)
            for index in 1..<points.count {
                cumulative.append(cumulative[index - 1] + points[index - 1].distance(to: points[index]))
            }
            return PreparedPath(points: points, cumulative: cumulative)
        }

        var result = [[CodableCoordinate]](repeating: [], count: stations.count - 1)
        // An unknown station breaks the chain rather than the pattern: the runs either side of it
        // are still each continuous, and are still worth solving.
        var index = 0
        while index < stations.count {
            guard stations[index] != nil else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < stations.count, stations[end + 1] != nil { end += 1 }
            if end > index {
                let run = (index...end).compactMap { stations[$0]?.coordinate }
                for (offset, geometry) in resolve(coordinates: run, paths: prepared).enumerated() {
                    result[index + offset] = geometry.map {
                        CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude)
                    }
                }
            }
            index = end + 1
        }
        return result
    }

    private struct PreparedPath {
        let points: [CLLocationCoordinate2D]
        let cumulative: [Double]
    }

    /// One way this hop could be drawn, and what drawing it that way costs.
    private struct HopCandidate {
        let head: CLLocationCoordinate2D
        let tail: CLLocationCoordinate2D
        let coordinates: [CLLocationCoordinate2D]
        let cost: Double
    }

    /// The cheapest chain that ends with one particular candidate for one particular hop.
    private struct ChainState {
        let cost: Double
        let tail: CLLocationCoordinate2D
        let coordinates: [CLLocationCoordinate2D]
        /// Index into the previous hop's (already pruned) states.
        let previous: Int
    }

    /// What a metre of join gap costs against a metre of track.
    ///
    /// Deliberately steep. A seam is a straight line drawn through a station the train does not
    /// travel through, so almost any amount of extra track is preferable to any amount of seam; the
    /// weight only has to stop short of buying continuity with geometry that is plainly wrong,
    /// which the arc ceiling already refuses. Measured from 30 to 400 the visible-join count is
    /// zero throughout, and only the sub-metre rounding count moves.
    private static let seamWeight: Double = 120
    /// Two candidate points closer together than this are the same place.
    private static let seedSeparation: Double = 25
    /// How many places one station may be considered to sit at on a single way.
    private static let stationCandidateLimit = 6
    /// How many chains to carry forward between hops. Measured across all 53 packs, 16 already
    /// gives the same answer as 160 — the beam exists to bound the worst case, not to shape it.
    private static let chainBeam = 48

    /// Picks the chain of hop geometries with the lowest total cost.
    ///
    /// A shortest path through a layered graph: one layer per hop, one node per way this hop could
    /// be drawn along, and an edge between consecutive layers weighted by the gap it would leave at
    /// the station they share. The per-hop candidate lists are built once and are the expensive
    /// part; the pass over them is arithmetic.
    private static func resolve(
        coordinates: [CLLocationCoordinate2D],
        paths: [PreparedPath]
    ) -> [[CLLocationCoordinate2D]] {
        guard coordinates.count >= 2 else { return [] }
        let perStation = coordinates.map { stationCandidates(of: $0, paths: paths) }

        var layers: [[ChainState]] = []
        layers.reserveCapacity(coordinates.count - 1)
        for index in 0..<(coordinates.count - 1) {
            let candidates = hopCandidates(
                from: coordinates[index],
                to: coordinates[index + 1],
                fromCandidates: perStation[index],
                toCandidates: perStation[index + 1],
                paths: paths
            )
            var layer: [ChainState] = []
            layer.reserveCapacity(candidates.count)
            if let previous = layers.last {
                for candidate in candidates {
                    var bestCost = Double.infinity
                    var bestIndex = 0
                    for (stateIndex, state) in previous.enumerated() {
                        let reached = state.cost + seamWeight * state.tail.distance(to: candidate.head)
                        if reached < bestCost {
                            bestCost = reached
                            bestIndex = stateIndex
                        }
                    }
                    layer.append(ChainState(
                        cost: bestCost + candidate.cost,
                        tail: candidate.tail,
                        coordinates: candidate.coordinates,
                        previous: bestIndex
                    ))
                }
            } else {
                for candidate in candidates {
                    layer.append(ChainState(
                        cost: candidate.cost,
                        tail: candidate.tail,
                        coordinates: candidate.coordinates,
                        previous: 0
                    ))
                }
            }
            if layer.count > chainBeam {
                layer = Array(layer.sorted { $0.cost < $1.cost }.prefix(chainBeam))
            }
            layers.append(layer)
        }

        var chain = [[CLLocationCoordinate2D]](repeating: [], count: layers.count)
        guard var stateIndex = layers[layers.count - 1].indices.min(by: {
            layers[layers.count - 1][$0].cost < layers[layers.count - 1][$1].cost
        }) else { return chain }
        for layerIndex in stride(from: layers.count - 1, through: 0, by: -1) {
            let state = layers[layerIndex][stateIndex]
            chain[layerIndex] = state.coordinates
            stateIndex = state.previous
        }
        return chain
    }

    /// Where one station could sit on each of the line's ways.
    ///
    /// A station's own projections are not enough. Where two ways of one line meet, the way that
    /// carries the next hop may pass the station further off than the way that carried the last
    /// one, and the point the two share is a projection *of a projection* — so every way's view of
    /// the station seeds every other way's list. Without that the chain has no continuous choice to
    /// make and the solver picks the least discontinuous one instead.
    private static func stationCandidates(
        of coordinate: CLLocationCoordinate2D,
        paths: [PreparedPath]
    ) -> [[PathProjection]] {
        var perPath = paths.map {
            projections(of: coordinate, onto: $0.points, cumulative: $0.cumulative)
        }
        var seeds: [CLLocationCoordinate2D] = []
        for candidates in perPath {
            for candidate in candidates
            where !seeds.contains(where: { $0.distance(to: candidate.point) < seedSeparation }) {
                seeds.append(candidate.point)
            }
        }

        for (pathIndex, path) in paths.enumerated() {
            var candidates = perPath[pathIndex]
            for seed in seeds {
                for carried in projections(of: seed, onto: path.points, cumulative: path.cumulative) {
                    // Two tests, both required. Offset alone throws away exactly the candidate this
                    // seeding exists to find: at a branch the seam point and the station's own
                    // projection sit on the same stretch of way, well inside `candidateSeparation`
                    // of offset and still up to that far apart on the ground — which left 红庄 on
                    // 苏州4号线 with a 67 m join. Position alone merges a ring's start and end,
                    // which are one point at opposite ends of the offset scale, and loses the wrap.
                    let duplicate = candidates.contains {
                        abs($0.pathOffset - carried.pathOffset) < candidateSeparation
                            && $0.point.distance(to: carried.point) < 5
                    }
                    guard !duplicate else { continue }
                    // A seeded candidate is still a claim about where *this* station sits, so it
                    // answers to the same cap. Without it the chain station → seed → reprojection
                    // compounds two 900 m allowances and put 馬場 1.7 km down the East Rail main
                    // line.
                    let distance = coordinate.distance(to: carried.point)
                    guard distance <= candidateDistanceCap else { continue }
                    candidates.append(PathProjection(
                        point: carried.point,
                        distance: distance,
                        pathOffset: carried.pathOffset
                    ))
                }
            }
            if candidates.count > stationCandidateLimit {
                candidates = Array(candidates.sorted { $0.distance < $1.distance }.prefix(stationCandidateLimit))
            }
            perPath[pathIndex] = candidates
        }
        return perPath
    }

    /// Every way this one hop could be drawn along.
    private static func hopCandidates(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromCandidates: [[PathProjection]],
        toCandidates: [[PathProjection]],
        paths: [PreparedPath]
    ) -> [HopCandidate] {
        let separation = from.distance(to: to)
        // A slice grossly longer than the stations' straight-line separation is a bad match (wrong
        // path variant, self-approaching geometry). 广州东环-琶莲-佛莞城际 ships as one 187.5 km way
        // whose point order does not follow the service order, which puts 琶洲 and 深井 59.3 km
        // apart along a hop that is 5.5 km across.
        let ceiling = max(2.5 * separation, separation + 1_500)
        // And a floor, because two projections that landed on the same short stretch of a way
        // which passes the pair twice are not the track either.
        //
        // Measured against `arc + fromDistance + toDistance`, not `arc` alone. `separation` is
        // between the two **station nodes** while `arc` is between their **projections onto the
        // track**, and a station may sit up to `candidateDistanceCap` off its own line — so
        // `arc < 0.75 × separation` is a perfectly ordinary outcome, not evidence of a bad match.
        // Comparing the bare arc threw away six real hops, among them 金鐘 → 中環, the busiest
        // pair in Hong Kong. The sum below is a lower bound on any route from one station to the
        // other via the track, so it is the like-for-like comparison.
        let floor = 0.75 * separation

        var track: [HopCandidate] = []
        for (pathIndex, path) in paths.enumerated() {
            let heads = fromCandidates[pathIndex]
            let tails = toCandidates[pathIndex]
            guard !heads.isEmpty, !tails.isEmpty else { continue }
            for fromProjection in heads {
                for toProjection in tails {
                    let candidate = slice(
                        points: path.points,
                        cumulative: path.cumulative,
                        from: fromProjection,
                        to: toProjection
                    )
                    guard candidate.count >= 2 else { continue }
                    let arc = arcLength(candidate)
                    guard arc <= ceiling,
                          arc + fromProjection.distance + toProjection.distance >= floor else { continue }
                    let joined = deduplicated(candidate)
                    guard joined.count >= 2, let head = joined.first, let tail = joined.last else { continue }
                    track.append(HopCandidate(
                        head: head,
                        tail: tail,
                        coordinates: joined,
                        cost: arc + 3 * (fromProjection.distance + toProjection.distance)
                    ))
                }
            }
        }
        if !track.isEmpty { return track }

        // No way on this line reaches both stations, so this hop is drawn as a straight line and
        // the only question left is where to draw it from. Not "the from-station's projection onto
        // some way that happens to hold the to-station too" — that way need not be the one the
        // previous hop ran along, and starting the chord anywhere else leaves a second break beside
        // the one already being admitted. Offering every point either station could sit at, the
        // station itself included, lets the chain begin the chord exactly where its known track ran
        // out. 馬場 → 沙田 on 港鐵東鐵綫 is the case: a racecourse spur no through way covers, which
        // used to tear a 639 m hole in the East Rail line either side of it.
        var chords: [HopCandidate] = []
        let heads = chordEnds(of: from, candidates: fromCandidates)
        let tails = chordEnds(of: to, candidates: toCandidates)
        for head in heads {
            for tail in tails {
                chords.append(HopCandidate(
                    head: head.point,
                    tail: tail.point,
                    coordinates: [head.point, tail.point],
                    cost: head.point.distance(to: tail.point) + 3 * (head.distance + tail.distance)
                ))
            }
        }
        return chords
    }

    private static func chordEnds(
        of coordinate: CLLocationCoordinate2D,
        candidates: [[PathProjection]]
    ) -> [PathProjection] {
        var ends = [PathProjection(point: coordinate, distance: 0, pathOffset: 0)]
        for list in candidates {
            for candidate in list
            where !ends.contains(where: { $0.point.distance(to: candidate.point) < seedSeparation }) {
                ends.append(candidate)
            }
        }
        return ends
    }

    /// Consecutive points closer than a metre are one point. OSM ways carry duplicated nodes at
    /// way boundaries and a projected endpoint often lands on a vertex.
    private static func deduplicated(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var joined: [CLLocationCoordinate2D] = []
        joined.reserveCapacity(coordinates.count)
        for point in coordinates where (joined.last.map { $0.distance(to: point) >= 1 } ?? true) {
            joined.append(point)
        }
        return joined
    }

    /// The stretch of `points` lying between two projections, in travel order.
    private static func slice(
        points: [CLLocationCoordinate2D],
        cumulative: [Double],
        from: PathProjection,
        to: PathProjection
    ) -> [CLLocationCoordinate2D] {
        let total = cumulative[cumulative.count - 1]
        let isRing = points.count >= 3 && points[0].distance(to: points[points.count - 1]) < 5
        let lowOffset = min(from.pathOffset, to.pathOffset)
        let highOffset = max(from.pathOffset, to.pathOffset)
        let reversed = from.pathOffset > to.pathOffset
        let lowPoint = reversed ? to.point : from.point
        let highPoint = reversed ? from.point : to.point

        var slice: [CLLocationCoordinate2D]
        if !isRing || highOffset - lowOffset <= total - (highOffset - lowOffset) {
            // Direct arc: projected endpoint, the vertices strictly between the two
            // offsets, projected endpoint.
            slice = [lowPoint]
            for index in points.indices where cumulative[index] > lowOffset && cumulative[index] < highOffset {
                slice.append(points[index])
            }
            slice.append(highPoint)
        } else {
            // Closed ring where the seam-crossing arc is shorter: walk from the higher
            // offset forward off the end of the array and back in at the start. The ring's
            // duplicated closing vertex meets the first vertex at the seam. Dedup it.
            slice = [highPoint]
            for index in points.indices where cumulative[index] > highOffset {
                slice.append(points[index])
            }
            for index in points.indices where cumulative[index] < lowOffset {
                if let last = slice.last, last.distance(to: points[index]) < 1 { continue }
                slice.append(points[index])
            }
            slice.append(lowPoint)
            slice.reverse()
        }
        if reversed {
            slice.reverse()
        }
        return slice
    }

    /// A station's closest point ON a path's polyline (not its closest vertex): the point,
    /// how far the station sits from the track, and the point's arc-length offset from the
    /// path start, which is what the slicer walks by.
    private struct PathProjection {
        let point: CLLocationCoordinate2D
        let distance: Double
        let pathOffset: Double
    }

    /// How far off its own track a station may sit and still be considered on it.
    private static let candidateDistanceCap: Double = 900
    /// How many passes of one way to consider per station. Measured across all 53 bundled packs:
    /// three is already enough to resolve every hop that four does.
    private static let candidateLimit = 4
    /// Two candidates closer together than this along the way are the same pass.
    private static let candidateSeparation: Double = 100

    /// **Every** local minimum of the station-to-track distance, nearest first — not just the
    /// global one.
    ///
    /// The global minimum is what shipped, and it is wrong wherever a relation concatenates the
    /// outbound and return runs into one way: the way then passes each station twice, each station
    /// picks whichever pass happens to be a metre nearer, and a pair that picks *different* passes
    /// gets sliced the long way round the whole line. 荃灣 → 大窩口 is 812 m apart and was sliced at
    /// 30.1 km, so the arc-length guard rejected it and the hop was drawn as a straight line
    /// between the two stations. 166 of 8,015 bundled hops drew that way, 67 of them in Hong Kong
    /// alone, where a fifth of the network was straight lines. Offering the caller each pass and
    /// letting it take the shortest plausible slice fixes 154 of the 166.
    private static func projections(
        of coordinate: CLLocationCoordinate2D,
        onto points: [CLLocationCoordinate2D],
        cumulative: [Double]
    ) -> [PathProjection] {
        guard points.count >= 2 else { return [] }
        var perSegment: [PathProjection] = []
        perSegment.reserveCapacity(points.count - 1)
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
            let segmentLength = cumulative[index + 1] - cumulative[index]
            perSegment.append(PathProjection(
                point: projected,
                distance: coordinate.distance(to: projected),
                pathOffset: cumulative[index] + t * segmentLength
            ))
        }

        var minima: [PathProjection] = []
        for index in perSegment.indices {
            let current = perSegment[index].distance
            let previous = index > 0 ? perSegment[index - 1].distance : .infinity
            let next = index < perSegment.count - 1 ? perSegment[index + 1].distance : .infinity
            if current <= previous, current <= next, current <= candidateDistanceCap {
                minima.append(perSegment[index])
            }
        }
        // A way whose distance profile never dips — a single straight run past the station — has
        // no interior minimum at all, so fall back to its nearest point.
        if minima.isEmpty, let nearest = perSegment.min(by: { $0.distance < $1.distance }),
           nearest.distance <= candidateDistanceCap {
            minima = [nearest]
        }

        // Distinct passes only. A plateau of equal distances yields a run of neighbouring
        // "minima" that are all the same place, and keeping four of those would crowd out the
        // second pass this exists to find.
        var kept: [PathProjection] = []
        for candidate in minima.sorted(by: { $0.distance < $1.distance }) {
            guard !kept.contains(where: { abs($0.pathOffset - candidate.pathOffset) < candidateSeparation }) else { continue }
            kept.append(candidate)
            if kept.count == candidateLimit { break }
        }
        return kept
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
