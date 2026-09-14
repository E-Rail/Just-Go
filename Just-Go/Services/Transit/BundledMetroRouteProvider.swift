import CoreLocation
import MapKit

actor BundledMetroRouteProvider: TransitRouteProviding {
    private let metroNetworks: MetroNetworkProviding
    let walkingRoutes: WalkingRouteProviding
    /// Built routing graphs, newest use last, keyed on the set of networks a trip spans (anything
    /// within 25 km of either end, so {4401}, {4401,4406} and {4401,4406,4419} are three keys).
    /// Three kept: home city, a neighbour, one more. A miss rebuilds from data already in memory.
    private var graphs: [String: MetroRoutingGraph] = [:]
    private var graphOrder: [String] = []
    private static let maximumGraphs = 3

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
        accessibilityFilter: AccessibilityFilter,
        excludingServices: Set<ClosedServiceDirection>
    ) async throws -> [Route] {
        // Bounds first, so only the cities that pass the check have their full networks loaded.
        let summaries = await metroNetworks.networkSummaries()
        // Near either end, not both: a pack that reaches only one end is the pack carrying the
        // corridor out (Suzhou's pack is 34.9 km from central Shanghai, and 花桥 sits in both packs,
        // 60 m apart).
        let candidateCityIDs = summaries.filter {
            $0.bounds.distance(to: origin.routeCoordinate) <= 25_000 ||
                $0.bounds.distance(to: destination.routeCoordinate) <= 25_000
        }.map(\.cityID)

        var networks: [MetroNetwork] = []
        for cityID in candidateCityIDs {
            guard let network = await metroNetworks.network(for: cityID) else { continue }
            networks.append(network)
        }
        // Every network the trip can reach, searched as one: Foshan metro → intercity → Guangzhou
        // metro needs both packs.
        guard let context = routeContext(
            networks: networks,
            origin: origin.routeCoordinate,
            destination: destination.routeCoordinate
        ) else {
            throw RoutePlanningError.outsideSubwayCoverage
        }
        let graph = routingGraph(for: context.networks)
        let bannedHops = Self.bannedHops(for: excludingServices, graph: graph)

        let preferences: [MetroSearchPreference] = [.fastest, .fewestTransfers, .leastWalking]
        var seen = Set<String>()
        var uniquePaths: [(order: Int, path: MetroPath, preference: MetroSearchPreference)] = []
        for preference in preferences {
            guard let path = shortestPath(
                in: context,
                graph: graph,
                preference: preference,
                excludingHops: bannedHops
            ) else { continue }
            let key = path.edges.map { "\($0.fromStationID)>\($0.toStationID)@\($0.lineID)" }.joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            uniquePaths.append((uniquePaths.count, path, preference))
        }
        guard !uniquePaths.isEmpty else { throw RoutePlanningError.noRouteFound }

        // Each candidate fetches its own walking directions, independently, so they run
        // concurrently.
        let results: [Route] = await withTaskGroup(of: (Int, Route).self) { group in
            for entry in uniquePaths {
                group.addTask {
                    let route = await self.makeRoute(
                        path: entry.path,
                        context: context,
                        graph: graph,
                        origin: origin,
                        destination: destination,
                        preference: entry.preference,
                        accessibilityFilter: accessibilityFilter
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
        networks: [MetroNetwork],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> MetroRouteContext? {
        guard !networks.isEmpty else { return nil }
        // Nearest across all packs together, so boarding and alighting stations can come from
        // different packs.
        let originStations = nearestStations(to: origin, in: networks)
        let destinationStations = nearestStations(to: destination, in: networks)
        guard let originDistance = originStations.first?.distance,
              let destinationDistance = destinationStations.first?.distance,
              originDistance <= 25_000,
              destinationDistance <= 25_000 else {
            return nil
        }
        return MetroRouteContext(
            networks: networks,
            originStations: originStations,
            destinationStations: destinationStations,
            directDistance: origin.distance(to: destination)
        )
    }

    private func nearestStations(to coordinate: CLLocationCoordinate2D, in networks: [MetroNetwork]) -> [MetroStationCandidate] {
        // Resolved first so duplicate copies of one station (shipped by up to three packs) do not
        // fill the candidate slots. Duplicates are identical normalized name **and** colocation,
        // never distance alone: 体育西路 and 天河南 are 281 m apart and different stations.
        let canonical = canonicalStationIDs(across: networks)
        var seen = Set<String>()
        var stations: [MetroStation] = []
        for network in networks {
            for station in network.stations where canonical[station.id] == nil {
                guard seen.insert(station.id).inserted else { continue }
                stations.append(station)
            }
        }
        return nearestStations(to: coordinate, among: stations)
    }

    private func nearestStations(to coordinate: CLLocationCoordinate2D, among stations: [MetroStation]) -> [MetroStationCandidate] {
        // Keep the 4 nearest in one linear pass; ties keep input order.
        var nearest: [MetroStationCandidate] = []
        nearest.reserveCapacity(5)
        for station in stations {
            let distance = coordinate.distance(to: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude))
            if nearest.count == 4, distance >= nearest[3].distance { continue }
            let insertionIndex = nearest.firstIndex { distance < $0.distance } ?? nearest.count
            nearest.insert(MetroStationCandidate(station: station, distance: distance), at: insertionIndex)
            if nearest.count > 4 { nearest.removeLast() }
        }
        return nearest
    }

    /// Which duplicate copies of a line collapse onto which surviving one. Adjacent packs each
    /// carry the intercity corridor they share; without this, identical-cost copies of one line
    /// make one trip appear as several "different" plans.
    ///
    /// Identity is identical name **and** identical canonical station set. Guangzhou's 1号线 and
    /// Dongguan's 1号线 share a name and no station; the three copies of 广州东环-琶莲-佛莞城际 share all 18.
    /// Resolved here, not in the packs: each pack stays independently valid and licensed.
    private func canonicalLineIDs(
        across networks: [MetroNetwork],
        canonicalStationIDs canonical: [String: String]
    ) -> [String: String] {
        guard networks.count > 1 else { return [:] }

        struct LineIdentity {
            let id: String
            let stationIDs: Set<String>
        }
        var byName: [String: [LineIdentity]] = [:]
        for network in networks {
            for line in network.lines {
                let stationIDs = Set(line.servicePatterns.flatMap { $0 }.map { canonical[$0] ?? $0 })
                guard !stationIDs.isEmpty else { continue }
                byName[line.name, default: []].append(LineIdentity(id: line.id, stationIDs: stationIDs))
            }
        }

        var canonicalLines: [String: String] = [:]
        for (_, group) in byName where group.count > 1 {
            var clusters: [[LineIdentity]] = []
            for line in group {
                let index = clusters.firstIndex { $0[0].stationIDs == line.stationIDs }
                if let index {
                    clusters[index].append(line)
                } else {
                    clusters.append([line])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                // Lowest id wins: the copies serve the same stations, so this only keeps the choice
                // stable between runs.
                let winner = cluster.map(\.id).min()!
                for line in cluster where line.id != winner {
                    canonicalLines[line.id] = winner
                }
            }
        }
        return canonicalLines
    }

    private func canonicalStationIDs(across networks: [MetroNetwork]) -> [String: String] {
        guard networks.count > 1 else { return [:] }

        var byName: [String: [MetroStation]] = [:]
        for network in networks {
            for station in network.stations {
                byName[normalizedStationName(station.name), default: []].append(station)
            }
        }

        var canonical: [String: String] = [:]
        for (_, group) in byName where group.count > 1 {
            var clusters: [[MetroStation]] = []
            for station in group {
                let index = clusters.firstIndex { cluster in
                    cluster.contains { $0.coordinate.distance(to: station.coordinate) <= 250 }
                }
                if let index {
                    clusters[index].append(station)
                } else {
                    clusters.append([station])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                // The copy that knows the most lines survives (the one the importer merged the
                // metro service into); the id only keeps the choice stable.
                let winner = cluster.sorted {
                    $0.lineIDs.count != $1.lineIDs.count
                        ? $0.lineIDs.count > $1.lineIDs.count
                        : $0.id < $1.id
                }[0]
                for station in cluster where station.id != winner.id {
                    canonical[station.id] = winner.id
                }
            }
        }
        return canonical
    }

    private func routingGraph(for networks: [MetroNetwork]) -> MetroRoutingGraph {
        let key = networks.map { "\($0.cityID):\($0.version)" }.sorted().joined(separator: "|")
        if let graph = graphs[key] {
            graphOrder.removeAll { $0 == key }
            graphOrder.append(key)
            return graph
        }

        let canonical = canonicalStationIDs(across: networks)
        func resolve(_ stationID: String) -> String { canonical[stationID] ?? stationID }
        let canonicalLine = canonicalLineIDs(across: networks, canonicalStationIDs: canonical)

        // Tolerate duplicated ids in a pack (keep the first): one malformed entry must not crash
        // route search.
        var stationsByID: [String: MetroStation] = [:]
        var linesByID: [String: MetroLine] = [:]
        var cityIDByStationID: [String: String] = [:]
        for network in networks {
            for station in network.stations where canonical[station.id] == nil {
                guard stationsByID[station.id] == nil else { continue }
                stationsByID[station.id] = station
                cityIDByStationID[station.id] = network.cityID
            }
            for line in network.lines where canonicalLine[line.id] == nil && linesByID[line.id] == nil {
                linesByID[line.id] = line
            }
        }

        var adjacency: [String: [MetroGraphEdge]] = [:]
        var edgeGeometries: [MetroGraphEdgeKey: [CodableCoordinate]] = [:]
        var seenEdges = Set<MetroGraphEdgeKey>()
        for network in networks {
            for line in network.lines where canonicalLine[line.id] == nil {
                for pattern in line.servicePatterns {
                    // Resolved for the whole pattern at once, so each hop continues from where the
                    // previous ended; see `MetroTrackGeometry.pattern`.
                    let ordered = pattern.map { stationsByID[resolve($0)] }
                    let geometries = MetroTrackGeometry.pattern(stations: ordered, line: line)
                    for (index, pair) in pattern.adjacentPairs.enumerated() {
                        guard let from = stationsByID[resolve(pair.0)],
                              let to = stationsByID[resolve(pair.1)],
                              from.id != to.id else { continue }
                        let distance = from.coordinate.distance(to: to.coordinate)
                        let edge = MetroGraphEdge(fromStationID: from.id, toStationID: to.id, lineID: line.id, distance: distance)
                        guard seenEdges.insert(edge.key).inserted else { continue }
                        let reversed = edge.reversed
                        seenEdges.insert(reversed.key)
                        adjacency[from.id, default: []].append(edge)
                        adjacency[to.id, default: []].append(reversed)

                        let geometry = index < geometries.count ? geometries[index] : []
                        edgeGeometries[edge.key] = geometry
                        edgeGeometries[reversed.key] = Array(geometry.reversed())
                    }
                }
            }
        }
        // Interchange links, both kinds: `outOfStation` is two gated stations and a street walk,
        // `inStation` two stations in one paid area. Either needs an edge, or the two are
        // unreachable however close they sit.
        for network in networks {
            for link in network.interchanges {
                let fromID = resolve(link.fromStationID)
                let toID = resolve(link.toStationID)
                guard let from = stationsByID[fromID], let to = stationsByID[toID], from.id != to.id else { continue }
                let edge = MetroGraphEdge(
                    fromStationID: from.id,
                    toStationID: to.id,
                    lineID: metroInterchangeLineID,
                    distance: link.walkingDistanceMeters,
                    interchange: link
                )
                guard seenEdges.insert(edge.key).inserted else { continue }
                seenEdges.insert(edge.reversed.key)
                adjacency[from.id, default: []].append(edge)
                adjacency[to.id, default: []].append(edge.reversed)
                let geometry = [
                    CodableCoordinate(latitude: from.latitude, longitude: from.longitude),
                    CodableCoordinate(latitude: to.latitude, longitude: to.longitude)
                ]
                edgeGeometries[edge.key] = geometry
                edgeGeometries[edge.reversed.key] = Array(geometry.reversed())
            }
        }

        let graph = MetroRoutingGraph(
            stationsByID: stationsByID,
            linesByID: linesByID,
            adjacency: adjacency,
            edgeGeometries: edgeGeometries,
            cityIDByStationID: cityIDByStationID,
            canonicalLineIDs: canonicalLine
        )
        graphs[key] = graph
        graphOrder.removeAll { $0 == key }
        graphOrder.append(key)
        while graphOrder.count > Self.maximumGraphs {
            let evicted = graphOrder.removeFirst()
            graphs[evicted] = nil
        }
        return graph
    }

    func releaseMemory() {
        graphs.removeAll()
        graphOrder.removeAll()
    }

    /// The hops every shut service covers, for this search only. Never folded into the graph:
    /// `routingGraph(for:)` memoises on `cityID:version`, and a graph built without a line at 23:50
    /// would still lack it at 08:00.
    private static func bannedHops(
        for services: Set<ClosedServiceDirection>,
        graph: MetroRoutingGraph
    ) -> Set<DirectedServiceHop> {
        guard !services.isEmpty else { return [] }
        return services.reduce(into: Set<DirectedServiceHop>()) { hops, service in
            guard let line = graph.linesByID[service.lineID] else { return }
            hops.formUnion(directedHops(
                lineID: service.lineID,
                from: service.fromStationID,
                to: service.toStationID,
                patterns: line.servicePatterns,
                identify: { graph.qualifiedID(for: $0) }
            ))
        }
    }

    /// Takes the banned hops as a parameter for the same reason: per-search state belongs to the
    /// search, not the memoised graph.
    private func shortestPath(
        in context: MetroRouteContext,
        graph: MetroRoutingGraph,
        preference: MetroSearchPreference,
        excludingHops: Set<DirectedServiceHop>
    ) -> MetroPath? {
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

            // A ride, not merely an interchange walk: arriving on foot is the direct-walk route's
            // job, not a journey the graph offers.
            let hasRidden = item.state.lineID != nil && item.state.lineID != metroInterchangeLineID
            if hasRidden, let destination = destinationsByID[item.state.stationID],
               !movesAwayFromDestination(destination, in: context) {
                let total = item.cost + walkingCost(destination.distance, preference: preference)
                if total < (best?.cost ?? .infinity),
                   !revisitsAStation(endingAt: item.state, previous: previous) {
                    best = (item.state, destination, total)
                }
            }
            if let best, item.cost >= best.cost { break }

            for edge in graph.adjacency[item.state.stationID, default: []] {
                // An interchange walk is never excluded: it is the corridor between two platforms,
                // walkable whatever has stopped running.
                if edge.interchange == nil,
                   excludingHops.contains(DirectedServiceHop(
                       lineID: edge.lineID,
                       fromStationID: edge.fromStationID,
                       toStationID: edge.toStationID
                   )) {
                    continue
                }
                // An interchange link is the transfer: it pays the penalty and the boarding beyond
                // it does not, or one change prices as two.
                let arrivedByInterchange = item.state.lineID == metroInterchangeLineID
                let transfer = !arrivedByInterchange &&
                    item.state.lineID != nil &&
                    item.state.lineID != edge.lineID
                let next = MetroSearchState(stationID: edge.toStationID, lineID: edge.lineID)
                let step = edge.interchange == nil
                    ? trainCost(edge.distance) + (transfer ? preference.transferPenalty : 0)
                    : walkingCost(edge.distance, preference: preference) + preference.transferPenalty
                let cost = item.cost + step
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

    /// Whether alighting here leaves the rider no better off than never boarding: the walking still
    /// required plus the walking already done, against walking the whole way. A route from 岗顶 to 岗顶
    /// would otherwise ride one stop and walk 827 m back, calling at each station once. Rejected
    /// here, the search settles on a real alternative.
    private func movesAwayFromDestination(
        _ destination: MetroStationCandidate,
        in context: MetroRouteContext
    ) -> Bool {
        let nearestOriginWalk = context.originStations.first?.distance ?? 0
        return nearestOriginWalk + destination.distance >= context.directDistance
    }

    /// Whether the path ending here already called at one of its own stations. A destination is
    /// accepted only after riding at least one edge, so to a station the rider is standing next to
    /// the cheapest legal path is out one stop and back. Rejected at acceptance, so the search
    /// continues to a genuine alternative.
    private func revisitsAStation(
        endingAt state: MetroSearchState,
        previous: [MetroSearchState: MetroPreviousStep]
    ) -> Bool {
        var seen = Set<String>()
        var cursor: MetroSearchState? = state
        while let current = cursor {
            guard seen.insert(current.stationID).inserted else { return true }
            cursor = previous[current]?.state
        }
        return false
    }

    private func walkingCost(_ distance: Double, preference: MetroSearchPreference) -> Double {
        distance / 1.25 * preference.walkingWeight
    }

    func trainCost(_ distance: Double) -> Double {
        max(60, distance / 9.7 + 30)
    }

}
