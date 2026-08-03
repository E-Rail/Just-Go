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
            originStationID: graph.qualifiedID(for: originStation.id),
            destinationStationID: graph.qualifiedID(for: destinationStation.id),
            strategy: preference.strategy,
            segments: segments,
            totalDuration: segments.reduce(0) { $0 + $1.duration },
            walkingDistance: walkingDistance,
            totalStops: path.edges.count,
            // Count line changes, which is what a transfer is. The interchange link's synthetic
            // line ID is dropped first: it sits between two different real lines by construction
            // (the importer rejects a pair that shares one), so the change is already counted —
            // adding the link itself priced one change as two.
            transferCount: max(0, path.edges.map(\.lineID).filter { $0 != metroInterchangeLineID }.consecutiveUnique.count - 1),
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
        graph: MetroRoutingGraph
    ) -> [RouteSegment] {
        var segments: [RouteSegment] = []
        // Also split on `interchange`, so two interchange links that happen to sit next to each
        // other stay two legs rather than being folded into one by their shared synthetic line.
        let groups = edges.chunked { $0.lineID == $1.lineID && $0.interchange == $1.interchange }
        for (index, group) in groups.enumerated() {
            if let first = group.first, let kind = first.interchange {
                segments.append(contentsOf: group.compactMap { interchangeSegment($0, kind: kind, graph: graph) })
                continue
            }
            guard let first = group.first,
                  let last = group.last,
                  let line = graph.linesByID[first.lineID],
                  let from = graph.stationsByID[first.fromStationID],
                  let to = graph.stationsByID[last.toStationID] else {
                continue
            }
            let currentContext = transitLegContext(
                group: group,
                line: line,
                graph: graph
            )
            // `index > 0`, but not straight after an interchange link: that link *is* the
            // change, and appending a second zero-length transfer on top of it listed the same
            // change twice — "walk 广安门内 → 牛街" followed by "transfer at 牛街".
            let followsInterchange = index > 0 && groups[index - 1].first?.interchange != nil
            if index > 0, !followsInterchange {
                // `lineName` below is the outgoing line (correct for "Transfer to X" display
                // text) — the incoming line, for resolving a real indoor transfer path, is the
                // *previous* group's line, only available here, not reconstructable later.
                let previousGroup = groups[index - 1]
                let previousLine = previousGroup.last.flatMap { graph.linesByID[$0.lineID] }
                let incomingContext = previousLine.map {
                    transitLegContext(group: previousGroup, line: $0, graph: graph)
                }
                segments.append(RouteSegment(
                    id: UUID(),
                    type: .transfer,
                    lineName: line.name,
                    lineColorHex: line.colorHex,
                    fromStationName: from.name,
                    toStationName: from.name,
                    fromStationID: graph.qualifiedID(for: from.id),
                    toStationID: graph.qualifiedID(for: from.id),
                    duration: 300,
                    distance: 0,
                    stops: 0,
                    stationStops: [],
                    polylineCoordinates: [],
                    walkingDirections: nil,
                    accessibilityNotes: [],
                    transferContext: incomingContext.map {
                        TransferContext(
                            cityID: graph.cityID(for: from.id),
                            stationID: graph.qualifiedID(for: from.id),
                            stationName: from.name,
                            incoming: $0,
                            outgoing: currentContext
                        )
                    },
                    incomingLineName: previousLine?.name,
                    incomingLineColorHex: previousLine?.colorHex
                ))
            }
            let stationIDs = [first.fromStationID] + group.map(\.toStationID)
            let stops = stationIDs.compactMap { id -> RouteStationStop? in
                guard let station = graph.stationsByID[id] else { return nil }
                let lineCount = Set(station.lineIDs.filter { graph.linesByID[$0] != nil }).count
                return RouteStationStop(
                    stationID: graph.qualifiedID(for: station.id),
                    name: station.name,
                    lineName: line.name,
                    lineColorHex: line.colorHex,
                    coordinate: CodableCoordinate(latitude: station.latitude, longitude: station.longitude),
                    arrivalTimeText: nil,
                    isTransfer: lineCount > 1,
                    lineID: line.id
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
                fromStationID: graph.qualifiedID(for: from.id),
                toStationID: graph.qualifiedID(for: to.id),
                duration: group.reduce(0) { $0 + trainCost($1.distance) },
                distance: group.reduce(0) { $0 + $1.distance },
                stops: group.count,
                stationStops: stops,
                polylineCoordinates: coordinates,
                walkingDirections: nil,
                accessibilityNotes: [],
                transitContext: currentContext
            ))
        }
        return segments
    }

    /// The leg where the rider walks from one station to the other one riders treat as the same
    /// interchange. A `.transfer` either way — it is a change of train, not a journey — but an
    /// `outOfStation` link says so, because leaving the paid area costs a second fare and the
    /// rider needs to know before they tap out.
    private func interchangeSegment(
        _ edge: MetroGraphEdge,
        kind: MetroInterchange.Kind,
        graph: MetroRoutingGraph
    ) -> RouteSegment? {
        guard let from = graph.stationsByID[edge.fromStationID],
              let to = graph.stationsByID[edge.toStationID] else { return nil }
        let note = kind == .outOfStation
            ? AppLocalization.text(
                english: "Leaves the paid area — a second fare applies",
                simplified: "需出站换乘，将重新计费",
                traditional: "需出站換乘，將重新計費"
            )
            : AppLocalization.text(
                english: "Inside the paid area — no need to tap out",
                simplified: "站内换乘，无需出闸",
                traditional: "站內換乘，無需出閘"
            )
        return RouteSegment(
            id: UUID(),
            type: .transfer,
            lineName: to.name,
            lineColorHex: nil,
            fromStationName: from.name,
            toStationName: to.name,
            fromStationID: graph.qualifiedID(for: from.id),
            toStationID: graph.qualifiedID(for: to.id),
            // Walking pace, plus the same fixed allowance an in-station change already carries.
            duration: edge.distance / 1.25 + 300,
            distance: edge.distance,
            stops: 0,
            stationStops: [],
            polylineCoordinates: graph.edgeGeometries[edge.key] ?? [],
            walkingDirections: nil,
            accessibilityNotes: [note]
        )
    }

    private func transitLegContext(
        group: [MetroGraphEdge],
        line: MetroLine,
        graph: MetroRoutingGraph
    ) -> TransitLegContext {
        let first = group.first!
        let last = group.last!
        let next = graph.stationsByID[first.toStationID]
        let previous = graph.stationsByID[last.fromStationID]
        let terminal = directionTerminal(for: first, line: line, graph: graph)
        return TransitLegContext(
            lineID: line.id,
            lineName: line.name,
            boardingStationID: graph.qualifiedID(for: first.fromStationID),
            alightingStationID: graph.qualifiedID(for: last.toStationID),
            directionNextStationID: next.map { graph.qualifiedID(for: $0.id) },
            directionNextStationName: next?.name,
            arrivalPreviousStationID: previous.map { graph.qualifiedID(for: $0.id) },
            arrivalPreviousStationName: previous?.name,
            directionTerminalStationID: terminal.map { graph.qualifiedID(for: $0.id) },
            directionTerminalStationName: terminal?.name
        )
    }

    private func directionTerminal(
        for edge: MetroGraphEdge,
        line: MetroLine,
        graph: MetroRoutingGraph
    ) -> MetroStation? {
        for pattern in line.servicePatterns where pattern.count > 1 && pattern.first != pattern.last {
            if pattern.adjacentPairs.contains(where: { $0.0 == edge.fromStationID && $0.1 == edge.toStationID }),
               let terminalID = pattern.last {
                return graph.stationsByID[terminalID]
            }
            if pattern.adjacentPairs.contains(where: { $0.0 == edge.toStationID && $0.1 == edge.fromStationID }),
               let terminalID = pattern.first {
                return graph.stationsByID[terminalID]
            }
        }
        return nil
    }

    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        await walkingRoutes.walkingSegment(from: from, to: to, fromName: fromName, toName: toName)
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
