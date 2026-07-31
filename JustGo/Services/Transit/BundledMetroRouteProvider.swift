import CoreLocation
import MapKit

actor BundledMetroRouteProvider: TransitRouteProviding {
    private let metroNetworks: MetroNetworkProviding
    let walkingRoutes: WalkingRouteProviding
    private var graphs: [String: MetroRoutingGraph] = [:]

    init(
        metroNetworks: MetroNetworkProviding,
        walkingRoutes: WalkingRouteProviding = MapKitWalkingRouteProvider()
    ) {
        self.metroNetworks = metroNetworks
        self.walkingRoutes = walkingRoutes
    }

    func routes(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter
    ) async throws -> [Route] {
        // Bounds-only pass first — decoding and permanently caching all ~46 supported cities'
        // full station/line/polyline data on every search (via networks()) just to compare
        // bounding boxes was the dominant cost of a cold route search. Only the (typically 0-2)
        // cities that actually pass the bounds check get their full network loaded below.
        let summaries = await metroNetworks.networkSummaries()
        let candidateCityIDs = summaries.filter {
            $0.bounds.distance(to: origin.routeCoordinate) <= 25_000 &&
                $0.bounds.distance(to: destination.routeCoordinate) <= 25_000
        }.map(\.cityID)

        var candidates: [MetroRouteContext] = []
        for cityID in candidateCityIDs {
            guard let network = await metroNetworks.network(for: cityID),
                  let context = routeContext(network: network, origin: origin.routeCoordinate, destination: destination.routeCoordinate) else {
                continue
            }
            candidates.append(context)
        }
        guard let context = candidates.min(by: { $0.accessDistance < $1.accessDistance }) else {
            throw RoutePlanningError.outsideSubwayCoverage
        }
        let graph = routingGraph(for: context.network)

        let preferences: [MetroSearchPreference] = [.fastest, .fewestTransfers, .leastWalking]
        var seen = Set<String>()
        var uniquePaths: [(order: Int, path: MetroPath, preference: MetroSearchPreference)] = []
        for preference in preferences {
            guard let path = shortestPath(in: context, graph: graph, preference: preference) else { continue }
            let key = path.edges.map { "\($0.fromStationID)>\($0.toStationID)@\($0.lineID)" }.joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            uniquePaths.append((uniquePaths.count, path, preference))
        }
        guard !uniquePaths.isEmpty else { throw RoutePlanningError.noRouteFound }

        // Each makeRoute call fetches its own walking directions over the network — running
        // the (up to 3) candidates one after another multiplied route-search latency by the
        // number of alternatives. They're independent, so fetch them concurrently instead.
        let results: [Route] = await withTaskGroup(of: (Int, Route).self) { group in
            for entry in uniquePaths {
                group.addTask {
                    let route = await self.makeRoute(
                        path: entry.path,
                        context: context,
                        graph: graph,
                        origin: origin,
                        destination: destination,
                        preference: entry.preference
                    )
                    return (entry.order, route)
                }
            }
            var collected: [(Int, Route)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return results
    }

    private func routeContext(
        network: MetroNetwork,
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> MetroRouteContext? {
        let originStations = nearestStations(to: origin, in: network)
        let destinationStations = nearestStations(to: destination, in: network)
        guard let originDistance = originStations.first?.distance,
              let destinationDistance = destinationStations.first?.distance,
              originDistance <= 25_000,
              destinationDistance <= 25_000 else {
            return nil
        }
        return MetroRouteContext(
            network: network,
            originStations: originStations,
            destinationStations: destinationStations,
            accessDistance: originDistance + destinationDistance
        )
    }

    private func nearestStations(to coordinate: CLLocationCoordinate2D, in network: MetroNetwork) -> [MetroStationCandidate] {
        // Keep only the 4 nearest in a single linear pass (sorted ascending) instead of
        // sorting every station (O(N) vs O(N log N)); ties preserve input order to match
        // the previous stable-sort behaviour.
        var nearest: [MetroStationCandidate] = []
        nearest.reserveCapacity(5)
        for station in network.stations {
            let distance = coordinate.distance(to: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude))
            if nearest.count == 4, distance >= nearest[3].distance { continue }
            let insertionIndex = nearest.firstIndex { distance < $0.distance } ?? nearest.count
            nearest.insert(MetroStationCandidate(station: station, distance: distance), at: insertionIndex)
            if nearest.count > 4 { nearest.removeLast() }
        }
        return nearest
    }

    private func routingGraph(for network: MetroNetwork) -> MetroRoutingGraph {
        let key = "\(network.cityID):\(network.version)"
        if let graph = graphs[key] {
            return graph
        }
        // Tolerate duplicated ids in a data pack (keep the first) instead of trapping —
        // a single malformed pack entry must not crash route search.
        let stationsByID = Dictionary(network.stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let linesByID = Dictionary(network.lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var adjacency: [String: [MetroGraphEdge]] = [:]
        var edgeGeometries: [MetroGraphEdgeKey: [CodableCoordinate]] = [:]
        var seenEdges = Set<MetroGraphEdgeKey>()
        for line in network.lines {
            for pattern in line.servicePatterns {
                for pair in pattern.adjacentPairs {
                    guard let from = stationsByID[pair.0], let to = stationsByID[pair.1] else { continue }
                    let distance = from.coordinate.distance(to: to.coordinate)
                    let edge = MetroGraphEdge(fromStationID: from.id, toStationID: to.id, lineID: line.id, distance: distance)
                    guard seenEdges.insert(edge.key).inserted else { continue }
                    let reversed = edge.reversed
                    seenEdges.insert(reversed.key)
                    adjacency[from.id, default: []].append(edge)
                    adjacency[to.id, default: []].append(reversed)

                    let geometry = edgeGeometry(edge, stations: stationsByID, line: line)
                    edgeGeometries[edge.key] = geometry
                    edgeGeometries[reversed.key] = Array(geometry.reversed())
                }
            }
        }
        let graph = MetroRoutingGraph(
            stationsByID: stationsByID,
            linesByID: linesByID,
            adjacency: adjacency,
            edgeGeometries: edgeGeometries
        )
        graphs[key] = graph
        return graph
    }

    func releaseMemory() {
        graphs.removeAll()
    }

    private func shortestPath(in context: MetroRouteContext, graph: MetroRoutingGraph, preference: MetroSearchPreference) -> MetroPath? {
        var distances: [MetroSearchState: Double] = [:]
        var previous: [MetroSearchState: MetroPreviousStep] = [:]
        var heap = MetroMinHeap()
        for candidate in context.originStations {
            let state = MetroSearchState(stationID: candidate.station.id, lineID: nil)
            let cost = walkingCost(candidate.distance, preference: preference)
            distances[state] = cost
            heap.insert(MetroQueueItem(state: state, cost: cost))
        }

        let destinationsByID = Dictionary(
            context.destinationStations.map { ($0.station.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var best: (state: MetroSearchState, destination: MetroStationCandidate, cost: Double)?
        while let item = heap.removeMin() {
            guard item.cost <= distances[item.state, default: .infinity] else { continue }

            if item.state.lineID != nil, let destination = destinationsByID[item.state.stationID] {
                let total = item.cost + walkingCost(destination.distance, preference: preference)
                if total < (best?.cost ?? .infinity) {
                    best = (item.state, destination, total)
                }
            }
            if let best, item.cost >= best.cost { break }

            for edge in graph.adjacency[item.state.stationID, default: []] {
                let transfer = item.state.lineID != nil && item.state.lineID != edge.lineID
                let next = MetroSearchState(stationID: edge.toStationID, lineID: edge.lineID)
                let cost = item.cost + trainCost(edge.distance) + (transfer ? preference.transferPenalty : 0)
                if cost < distances[next, default: .infinity] {
                    distances[next] = cost
                    previous[next] = MetroPreviousStep(state: item.state, edge: edge)
                    heap.insert(MetroQueueItem(state: next, cost: cost))
                }
            }
        }

        guard let best else { return nil }

        var edges: [MetroGraphEdge] = []
        var state = best.state
        while let step = previous[state] {
            edges.append(step.edge)
            state = step.state
        }
        edges.reverse()
        guard let originCandidate = context.originStations.first(where: { $0.station.id == state.stationID }),
              !edges.isEmpty else {
            return nil
        }
        return MetroPath(origin: originCandidate, destination: best.destination, edges: edges)
    }

    private func walkingCost(_ distance: Double, preference: MetroSearchPreference) -> Double {
        distance / 1.25 * preference.walkingWeight
    }

    func trainCost(_ distance: Double) -> Double {
        max(60, distance / 9.7 + 30)
    }

    /// A station's closest point ON a path's polyline (not its closest vertex): the point,
    /// how far the station sits from the track, and the point's arc-length offset from the
    /// path start — which is what the slicer walks by.
    private struct PathProjection {
        let point: CLLocationCoordinate2D
        let distance: Double
        let pathOffset: Double
    }

    private func edgeGeometry(_ edge: MetroGraphEdge, stations: [String: MetroStation], line: MetroLine) -> [CodableCoordinate] {
        guard let from = stations[edge.fromStationID], let to = stations[edge.toStationID] else { return [] }
        let fromCoordinate = from.coordinate
        let toCoordinate = to.coordinate
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
            guard let fromProjection = projection(of: fromCoordinate, onto: points, cumulative: cumulative),
                  let toProjection = projection(of: toCoordinate, onto: points, cumulative: cumulative) else {
                return nil
            }
            return (path, cumulative, fromProjection, toProjection)
        }
        guard let match = matches.min(by: { ($0.from.distance + $0.to.distance) < ($1.from.distance + $1.to.distance) }),
              match.from.distance + match.to.distance < 2_000 else {
            return []
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
            // duplicated closing vertex meets the first vertex at the seam — dedup it.
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

        // A slice grossly longer than the stations' straight-line separation is a bad
        // match (wrong path variant, self-approaching geometry) — better to return
        // nothing and let the renderer draw its station-to-station straight fallback.
        guard slice.count >= 2, arcLength(slice) <= max(2.5 * edge.distance, edge.distance + 1_500) else {
            return []
        }
        return slice.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Nearest point on the polyline to `coordinate`, via point-to-segment projection in a
    /// small local planar frame (metres-per-degree at the segment; exact enough at station
    /// scale, and far cheaper than geodesic projection).
    private func projection(
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

    private func arcLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var total: Double = 0
        for index in 1..<coordinates.count {
            total += coordinates[index - 1].distance(to: coordinates[index])
        }
        return total
    }
}
