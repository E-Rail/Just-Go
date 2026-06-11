import CoreLocation
import MapKit

actor BundledMetroRouteProvider: TransitRouteProviding {
    private let metroNetworks: MetroNetworkProviding

    init(metroNetworks: MetroNetworkProviding) {
        self.metroNetworks = metroNetworks
    }

    func routes(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter
    ) async throws -> [Route] {
        let networks = await metroNetworks.networks()
        let candidates = networks.compactMap {
            routeContext(network: $0, origin: origin.routeCoordinate, destination: destination.routeCoordinate)
        }
        guard let context = candidates.min(by: { $0.accessDistance < $1.accessDistance }) else {
            throw RoutePlanningError.outsideSubwayCoverage
        }

        let preferences: [SearchPreference] = [.fastest, .fewestTransfers, .leastWalking]
        var seen = Set<String>()
        var results: [Route] = []
        for preference in preferences {
            guard let path = shortestPath(in: context, preference: preference) else { continue }
            let key = path.edges.map { "\($0.fromStationID)>\($0.toStationID)@\($0.lineID)" }.joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            results.append(await makeRoute(
                path: path,
                context: context,
                origin: origin,
                destination: destination,
                preference: preference,
                accessibilityFilter: accessibilityFilter
            ))
        }
        guard !results.isEmpty else { throw RoutePlanningError.noRouteFound }
        return results
    }

    private func routeContext(
        network: MetroNetwork,
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> RouteContext? {
        let originStations = nearestStations(to: origin, in: network)
        let destinationStations = nearestStations(to: destination, in: network)
        guard let originDistance = originStations.first?.distance,
              let destinationDistance = destinationStations.first?.distance,
              originDistance <= 25_000,
              destinationDistance <= 25_000 else {
            return nil
        }
        return RouteContext(
            network: network,
            originStations: originStations,
            destinationStations: destinationStations,
            accessDistance: originDistance + destinationDistance
        )
    }

    private func nearestStations(to coordinate: CLLocationCoordinate2D, in network: MetroNetwork) -> [StationCandidate] {
        network.stations.map {
            StationCandidate(
                station: $0,
                distance: coordinate.distance(to: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
            )
        }
        .sorted { $0.distance < $1.distance }
        .prefix(4)
        .map { $0 }
    }

    private func shortestPath(in context: RouteContext, preference: SearchPreference) -> MetroPath? {
        let stationsByID = Dictionary(uniqueKeysWithValues: context.network.stations.map { ($0.id, $0) })
        let linesByID = Dictionary(uniqueKeysWithValues: context.network.lines.map { ($0.id, $0) })
        var adjacency: [String: [GraphEdge]] = [:]
        for line in context.network.lines {
            for pattern in line.servicePatterns {
                for pair in pattern.adjacentPairs {
                    guard let from = stationsByID[pair.0], let to = stationsByID[pair.1] else { continue }
                    let distance = from.coordinate.distance(to: to.coordinate)
                    let edge = GraphEdge(fromStationID: from.id, toStationID: to.id, lineID: line.id, distance: distance)
                    adjacency[from.id, default: []].append(edge)
                    adjacency[to.id, default: []].append(edge.reversed)
                }
            }
        }

        var distances: [SearchState: Double] = [:]
        var previous: [SearchState: PreviousStep] = [:]
        var heap = MinHeap()
        for candidate in context.originStations {
            let state = SearchState(stationID: candidate.station.id, lineID: nil)
            let cost = walkingCost(candidate.distance, preference: preference)
            distances[state] = cost
            heap.insert(QueueItem(state: state, cost: cost))
        }

        while let item = heap.removeMin() {
            guard item.cost <= distances[item.state, default: .infinity] else { continue }
            for edge in adjacency[item.state.stationID, default: []] {
                let transfer = item.state.lineID != nil && item.state.lineID != edge.lineID
                let next = SearchState(stationID: edge.toStationID, lineID: edge.lineID)
                let cost = item.cost + trainCost(edge.distance) + (transfer ? preference.transferPenalty : 0)
                if cost < distances[next, default: .infinity] {
                    distances[next] = cost
                    previous[next] = PreviousStep(state: item.state, edge: edge)
                    heap.insert(QueueItem(state: next, cost: cost))
                }
            }
        }

        var best: (state: SearchState, destination: StationCandidate, cost: Double)?
        for candidate in context.destinationStations {
            for lineID in linesByID.keys {
                let state = SearchState(stationID: candidate.station.id, lineID: lineID)
                guard let distance = distances[state] else { continue }
                let total = distance + walkingCost(candidate.distance, preference: preference)
                if best == nil || total < best!.cost {
                    best = (state, candidate, total)
                }
            }
        }
        guard let best else { return nil }

        var edges: [GraphEdge] = []
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

    private func walkingCost(_ distance: Double, preference: SearchPreference) -> Double {
        distance / 1.25 * preference.walkingWeight
    }

    private func trainCost(_ distance: Double) -> Double {
        max(60, distance / 9.7 + 30)
    }

    private func makeRoute(
        path: MetroPath,
        context: RouteContext,
        origin: TransitPlace,
        destination: TransitPlace,
        preference: SearchPreference,
        accessibilityFilter: AccessibilityFilter
    ) async -> Route {
        let stations = Dictionary(uniqueKeysWithValues: context.network.stations.map { ($0.id, $0) })
        let lines = Dictionary(uniqueKeysWithValues: context.network.lines.map { ($0.id, $0) })
        let originStation = path.origin.station
        let destinationStation = path.destination.station
        async let originWalk = walkingSegment(
            from: origin.routeCoordinate,
            to: originStation.coordinate,
            fromName: origin.name,
            toName: originStation.name
        )
        async let destinationWalk = walkingSegment(
            from: destinationStation.coordinate,
            to: destination.routeCoordinate,
            fromName: destinationStation.name,
            toName: destination.name
        )

        var segments: [RouteSegment] = []
        if let walk = await originWalk { segments.append(walk) }
        segments.append(contentsOf: transitSegments(path.edges, cityID: context.network.cityID, stations: stations, lines: lines))
        if let walk = await destinationWalk { segments.append(walk) }

        let walkingDistance = segments.filter { $0.type == .walking }.reduce(0) { $0 + $1.distance }
        var warnings: [RouteWarning] = []
        if walkingDistance >= 800 {
            warnings.append(RouteWarning(type: .longWalk, message: AppLocalization.localized("Long walking segment"), affectedStationID: nil))
        }
        let hasStairs = segments.flatMap { $0.walkingDirections ?? [] }.contains(where: \.hasStairs)
        if hasStairs {
            warnings.append(RouteWarning(type: .stairsDetected, message: AppLocalization.localized("Stairs mentioned in Apple Maps directions"), affectedStationID: nil))
        }

        return Route(
            id: UUID(),
            origin: origin.name,
            destination: destination.name,
            originStationID: "network-\(context.network.cityID)-\(originStation.id)",
            destinationStationID: "network-\(context.network.cityID)-\(destinationStation.id)",
            strategy: preference.strategy,
            segments: segments,
            totalDuration: segments.reduce(0) { $0 + $1.duration },
            walkingDistance: walkingDistance,
            totalStops: path.edges.count,
            transferCount: max(0, path.edges.map(\.lineID).consecutiveUnique.count - 1),
            accessibilityScore: hasStairs ? 0.35 : 0.7,
            isFullyAccessible: false,
            stepFreeAssessment: hasStairs ? .barrierDetected : .unknown,
            warnings: warnings,
            accessGuidance: [
                accessGuide(kind: .origin, place: origin, station: originStation, walk: segments.first?.type == .walking ? segments.first : nil),
                accessGuide(kind: .destination, place: destination, station: destinationStation, walk: segments.last?.type == .walking ? segments.last : nil)
            ],
            dataCoverage: .unknown
        )
    }

    private func transitSegments(
        _ edges: [GraphEdge],
        cityID: String,
        stations: [String: MetroStation],
        lines: [String: MetroLine]
    ) -> [RouteSegment] {
        edges.chunked { $0.lineID == $1.lineID }.compactMap { group in
            guard let first = group.first,
                  let last = group.last,
                  let line = lines[first.lineID],
                  let from = stations[first.fromStationID],
                  let to = stations[last.toStationID] else {
                return nil
            }
            let stationIDs = [first.fromStationID] + group.map(\.toStationID)
            let stops = stationIDs.compactMap { id -> RouteStationStop? in
                guard let station = stations[id] else { return nil }
                return RouteStationStop(
                    stationID: "network-\(cityID)-\(station.id)",
                    name: station.name,
                    lineName: line.name,
                    lineColorHex: line.colorHex,
                    coordinate: CodableCoordinate(latitude: station.latitude, longitude: station.longitude),
                    arrivalTimeText: nil,
                    isTransfer: Set(station.lineIDs).count > 1
                )
            }
            let coordinates = group.flatMap { edgeGeometry($0, stations: stations, line: line) }.deduplicatedCoordinates
            return RouteSegment(
                id: UUID(),
                type: .subway,
                lineName: line.name,
                lineColorHex: line.colorHex,
                fromStationName: from.name,
                toStationName: to.name,
                fromStationID: "network-\(cityID)-\(from.id)",
                toStationID: "network-\(cityID)-\(to.id)",
                duration: group.reduce(0) { $0 + trainCost($1.distance) },
                distance: group.reduce(0) { $0 + $1.distance },
                stops: group.count,
                stationStops: stops,
                polylineCoordinates: coordinates,
                walkingDirections: nil,
                accessibilityNotes: []
            )
        }
    }

    private func edgeGeometry(_ edge: GraphEdge, stations: [String: MetroStation], line: MetroLine) -> [CodableCoordinate] {
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
            return [CodableCoordinate(latitude: from.latitude, longitude: from.longitude), CodableCoordinate(latitude: to.latitude, longitude: to.longitude)]
        }
        let slice = match.from <= match.to
            ? Array(match.path[match.from...match.to])
            : Array(match.path[match.to...match.from].reversed())
        return slice.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        let directDistance = from.distance(to: to)
        guard directDistance >= 10 else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .walking
        let mapRoute = try? await MKDirections(request: request).calculate().routes.first
        let distance = mapRoute?.distance ?? directDistance
        let duration = mapRoute?.expectedTravelTime ?? distance / 1.25
        let steps = mapRoute?.steps.filter { $0.distance >= 10 || !$0.instructions.isEmpty }.map {
            WalkingStep(
                instruction: $0.instructions,
                distance: $0.distance,
                duration: max(1, duration * ($0.distance / max(distance, 1))),
                isAccessible: !$0.instructions.localizedCaseInsensitiveContains("stairs"),
                road: nil,
                action: nil,
                assistantAction: nil,
                walkType: nil
            )
        } ?? [WalkingStep(
            instruction: AppLocalization.text(
                english: "Walk from \(fromName) to \(toName)",
                simplified: "从\(fromName)步行至\(toName)",
                traditional: "從\(fromName)步行至\(toName)"
            ),
            distance: distance,
            duration: duration,
            isAccessible: true,
            road: nil,
            action: nil,
            assistantAction: nil,
            walkType: nil
        )]
        return RouteSegment(
            id: UUID(),
            type: .walking,
            lineName: nil,
            lineColorHex: nil,
            fromStationName: fromName,
            toStationName: toName,
            fromStationID: nil,
            toStationID: nil,
            duration: duration,
            distance: distance,
            stops: 0,
            stationStops: [],
            polylineCoordinates: mapRoute?.polyline.routeCoordinates.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) } ?? [],
            walkingDirections: steps,
            accessibilityNotes: mapRoute == nil ? [AppLocalization.localized("Walking distance is estimated")] : []
        )
    }

    private func accessGuide(kind: RouteAccessKind, place: TransitPlace, station: MetroStation, walk: RouteSegment?) -> RouteAccessGuide {
        RouteAccessGuide(
            id: UUID(),
            kind: kind,
            placeName: place.name,
            stationName: station.name,
            accessPoint: RouteAccessPoint(
                id: station.id,
                name: station.name,
                coordinate: CodableCoordinate(latitude: station.latitude, longitude: station.longitude),
                isWheelchairLikely: false,
                hasElevatorHint: false,
                source: .stationPOI
            ),
            walkingDistance: walk?.distance ?? 0,
            walkingDuration: walk?.duration ?? 0,
            walkingSteps: walk?.walkingDirections ?? [],
            accessibilityNotes: [AppLocalization.localized("Specific entrance or exit is unavailable")]
        )
    }
}

private struct RouteContext {
    let network: MetroNetwork
    let originStations: [StationCandidate]
    let destinationStations: [StationCandidate]
    let accessDistance: Double
}

private struct StationCandidate {
    let station: MetroStation
    let distance: Double
}

private struct GraphEdge {
    let fromStationID: String
    let toStationID: String
    let lineID: String
    let distance: Double

    var reversed: GraphEdge {
        GraphEdge(fromStationID: toStationID, toStationID: fromStationID, lineID: lineID, distance: distance)
    }
}

private struct MetroPath {
    let origin: StationCandidate
    let destination: StationCandidate
    let edges: [GraphEdge]
}

private struct SearchState: Hashable {
    let stationID: String
    let lineID: String?
}

private struct PreviousStep {
    let state: SearchState
    let edge: GraphEdge
}

private enum SearchPreference {
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
        case .fastest, .fewestTransfers: return .fastest
        case .leastWalking: return .leastWalking
        }
    }
}

private struct QueueItem {
    let state: SearchState
    let cost: Double
}

private struct MinHeap {
    private var values: [QueueItem] = []

    mutating func insert(_ value: QueueItem) {
        values.append(value)
        var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard values[index].cost < values[parent].cost else { break }
            values.swapAt(index, parent)
            index = parent
        }
    }

    mutating func removeMin() -> QueueItem? {
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

private extension MetroStation {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension MetroCoordinate {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension Array {
    var adjacentPairs: [(Element, Element)] {
        guard count >= 2 else { return [] }
        return zip(self, dropFirst()).map { ($0, $1) }
    }

    func chunked(where belongsTogether: (Element, Element) -> Bool) -> [[Element]] {
        guard let first else { return [] }
        var chunks = [[first]]
        for item in dropFirst() {
            if belongsTogether(chunks[chunks.count - 1].last!, item) {
                chunks[chunks.count - 1].append(item)
            } else {
                chunks.append([item])
            }
        }
        return chunks
    }
}

private extension Array where Element: Equatable {
    var consecutiveUnique: [Element] {
        reduce(into: []) { result, item in
            if result.last != item { result.append(item) }
        }
    }
}

private extension Array where Element == CodableCoordinate {
    var deduplicatedCoordinates: [CodableCoordinate] {
        reduce(into: []) { result, coordinate in
            if result.last != coordinate { result.append(coordinate) }
        }
    }
}

private extension MKPolyline {
    var routeCoordinates: [CLLocationCoordinate2D] {
        var values = Array(repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&values, range: NSRange(location: 0, length: pointCount))
        return values
    }
}
