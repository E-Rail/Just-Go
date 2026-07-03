import CoreLocation
import MapKit

actor BundledMetroRouteProvider: TransitRouteProviding {
    private let metroNetworks: MetroNetworkProviding
    private var graphs: [String: MetroRoutingGraph] = [:]

    init(metroNetworks: MetroNetworkProviding) {
        self.metroNetworks = metroNetworks
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

    private func edgeGeometry(_ edge: MetroGraphEdge, stations: [String: MetroStation], line: MetroLine) -> [CodableCoordinate] {
        guard let from = stations[edge.fromStationID], let to = stations[edge.toStationID] else { return [] }
        let fromCoordinate = from.coordinate
        let toCoordinate = to.coordinate
        let matches = line.paths.compactMap { path -> (path: [MetroCoordinate], from: Int, to: Int, score: Double)? in
            guard path.count >= 2,
                  let fromIndex = path.indices.min(by: { path[$0].coordinate.distance(to: fromCoordinate) < path[$1].coordinate.distance(to: fromCoordinate) }),
                  let toIndex = path.indices.min(by: { path[$0].coordinate.distance(to: toCoordinate) < path[$1].coordinate.distance(to: toCoordinate) }) else {
                return nil
            }
            let score = path[fromIndex].coordinate.distance(to: fromCoordinate) + path[toIndex].coordinate.distance(to: toCoordinate)
            return (path, fromIndex, toIndex, score)
        }
        guard let match = matches.min(by: { $0.score < $1.score }), match.score < 2_000 else {
            return []
        }
        let slice = match.from <= match.to
            ? Array(match.path[match.from...match.to])
            : Array(match.path[match.to...match.from].reversed())
        return slice.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }
}
