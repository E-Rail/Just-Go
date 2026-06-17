import CoreLocation
import MapKit

extension BundledMetroRouteProvider {
    func makeRoute(
        path: MetroPath,
        context: MetroRouteContext,
        graph: MetroRoutingGraph,
        origin: TransitPlace,
        destination: TransitPlace,
        preference: MetroSearchPreference
    ) async -> Route {
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
        segments.append(contentsOf: transitSegments(
            path.edges,
            cityID: context.network.cityID,
            graph: graph
        ))
        if let walk = await destinationWalk { segments.append(walk) }

        let walkingDistance = segments.filter { $0.type == .walking }.reduce(0) { $0 + $1.distance }
        var warnings: [RouteWarning] = []
        if walkingDistance >= 800 {
            warnings.append(RouteWarning(type: .longWalk, message: AppLocalization.localized("Long walking segment"), affectedStationID: nil))
        }
        let hasStairs = segments.contains { ($0.walkingDirections ?? []).contains(where: \.hasStairs) }
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

    func transitSegments(
        _ edges: [MetroGraphEdge],
        cityID: String,
        graph: MetroRoutingGraph
    ) -> [RouteSegment] {
        var segments: [RouteSegment] = []
        let groups = edges.chunked { $0.lineID == $1.lineID }
        for (index, group) in groups.enumerated() {
            guard let first = group.first,
                  let last = group.last,
                  let line = graph.linesByID[first.lineID],
                  let from = graph.stationsByID[first.fromStationID],
                  let to = graph.stationsByID[last.toStationID] else {
                continue
            }
            if index > 0 {
                segments.append(RouteSegment(
                    id: UUID(),
                    type: .transfer,
                    lineName: line.name,
                    lineColorHex: line.colorHex,
                    fromStationName: from.name,
                    toStationName: from.name,
                    fromStationID: "network-\(cityID)-\(from.id)",
                    toStationID: "network-\(cityID)-\(from.id)",
                    duration: 300,
                    distance: 0,
                    stops: 0,
                    stationStops: [],
                    polylineCoordinates: [],
                    walkingDirections: nil,
                    accessibilityNotes: []
                ))
            }
            let stationIDs = [first.fromStationID] + group.map(\.toStationID)
            let stops = stationIDs.compactMap { id -> RouteStationStop? in
                guard let station = graph.stationsByID[id] else { return nil }
                let lineCount = Set(station.lineIDs.filter { graph.linesByID[$0] != nil }).count
                return RouteStationStop(
                    stationID: "network-\(cityID)-\(station.id)",
                    name: station.name,
                    lineName: line.name,
                    lineColorHex: line.colorHex,
                    coordinate: CodableCoordinate(latitude: station.latitude, longitude: station.longitude),
                    arrivalTimeText: nil,
                    isTransfer: lineCount > 1
                )
            }
            let coordinates = group.flatMap { graph.edgeGeometries[$0.key] ?? [] }.consecutiveUnique
            segments.append(RouteSegment(
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
            ))
        }
        return segments
    }

    func walkingSegment(
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
        let mapRoute: MKRoute?
        do {
            mapRoute = try await MKDirections(request: request).calculate().routes.first
        } catch {
            AppLog.routing.info("Walking directions unavailable, using straight-line estimate: \(error)")
            mapRoute = nil
        }
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
