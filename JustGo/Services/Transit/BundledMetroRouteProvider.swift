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
        let networks = await metroNetworks.networks()
        let candidates = networks.filter {
            $0.bounds.distance(to: origin.routeCoordinate) <= 25_000 &&
                $0.bounds.distance(to: destination.routeCoordinate) <= 25_000
        }.compactMap {
            routeContext(network: $0, origin: origin.routeCoordinate, destination: destination.routeCoordinate)
        }
        guard let context = candidates.min(by: { $0.accessDistance < $1.accessDistance }) else {
            throw RoutePlanningError.outsideSubwayCoverage
        }
        let graph = routingGraph(for: context.network)

        let preferences: [MetroSearchPreference] = [.fastest, .fewestTransfers, .leastWalking]
        var seen = Set<String>()
        var results: [Route] = []
        for preference in preferences {
            guard let path = shortestPath(in: context, graph: graph, preference: preference) else { continue }
            let key = path.edges.map { "\($0.fromStationID)>\($0.toStationID)@\($0.lineID)" }.joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            results.append(await makeRoute(
                path: path,
                context: context,
                graph: graph,
                origin: origin,
                destination: destination,
                preference: preference
            ))
        }
        guard !results.isEmpty else { throw RoutePlanningError.noRouteFound }
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
        Array(
            network.stations.map {
                MetroStationCandidate(
                    station: $0,
                    distance: coordinate.distance(to: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
                )
            }
            .sorted { $0.distance < $1.distance }
            .prefix(4)
        )
    }

    private func routingGraph(for network: MetroNetwork) -> MetroRoutingGraph {
        let key = "\(network.cityID):\(network.version)"
        if let graph = graphs[key] {
            return graph
        }
        let stationsByID = Dictionary(uniqueKeysWithValues: network.stations.map { ($0.id, $0) })
        let linesByID = Dictionary(uniqueKeysWithValues: network.lines.map { ($0.id, $0) })
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
            uniqueKeysWithValues: context.destinationStations.map { ($0.station.id, $0) }
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
