import CoreLocation
import MapKit

extension BundledMetroRouteProvider {
    func makeRoute(
        path: MetroPath,
        context: MetroRouteContext,
        graph: MetroRoutingGraph,
        origin: TransitPlace,
        destination: TransitPlace,
        preference: MetroSearchPreference,
        accessibilityFilter: AccessibilityFilter
    ) async -> Route {
        let originStation = path.origin.station
        let destinationStation = path.destination.station
        // How each end is covered is decided once, here, by straight-line distance: the mode must
        // be chosen before there is a route to measure.
        let limit = accessibilityFilter.maxWalkingDistance
        let originMode = AccessLegMode.forDistance(
            origin.routeCoordinate.distance(to: originStation.coordinate),
            walkingLimit: limit
        )
        let destinationMode = AccessLegMode.forDistance(
            destinationStation.coordinate.distance(to: destination.routeCoordinate),
            walkingLimit: limit
        )
        async let originWalk = accessSegment(
            from: origin.routeCoordinate,
            to: originStation.coordinate,
            fromName: origin.name,
            toName: originStation.name,
            mode: originMode
        )
        async let destinationWalk = accessSegment(
            from: destinationStation.coordinate,
            to: destination.routeCoordinate,
            fromName: destinationStation.name,
            toName: destination.name,
            mode: destinationMode
        )

        var segments: [RouteSegment] = []
        if let walk = await originWalk { segments.append(walk) }
        segments.append(contentsOf: transitSegments(
            path.edges,
            graph: graph
        ))
        if let walk = await destinationWalk { segments.append(walk) }

        let walkingDistance = segments.filter { $0.type.isOnFoot }.reduce(0) { $0 + $1.distance }
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
            // Count line changes. The interchange link's synthetic line ID is dropped first: it
            // sits between two different real lines by construction, so counting it prices one
            // change as two.
            transferCount: max(0, path.edges.map(\.lineID).filter { $0 != metroInterchangeLineID }.consecutiveUnique.count - 1),
            isFullyAccessible: false,
            stepFreeAssessment: hasStairs ? .barrierDetected : .unknown,
            warnings: warnings,
            accessGuidance: [
                // `isAccessLeg`, not `== .walking`: a first mile long enough to cycle or drive is
                // where naming the right door matters most.
                accessGuide(kind: .origin, place: origin, station: originStation, walk: segments.first?.type.isAccessLeg == true ? segments.first : nil),
                accessGuide(kind: .destination, place: destination, station: destinationStation, walk: segments.last?.type.isAccessLeg == true ? segments.last : nil)
            ],
            dataCoverage: .unknown
        )
    }

    func transitSegments(
        _ edges: [MetroGraphEdge],
        graph: MetroRoutingGraph
    ) -> [RouteSegment] {
        var segments: [RouteSegment] = []
        // Also split on `interchange`, so two adjacent interchange links stay two legs.
        let groups = edges.chunked { $0.lineID == $1.lineID && $0.interchange == $1.interchange }
        for (index, group) in groups.enumerated() {
            if group.first?.interchange != nil {
                segments.append(contentsOf: group.compactMap { edge in
                    edge.interchange.flatMap { interchangeSegment(edge, link: $0, graph: graph) }
                })
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
            // Not straight after an interchange link: that link is the change, and a transfer on
            // top of it lists one change twice.
            let followsInterchange = index > 0 && groups[index - 1].first?.interchange != nil
            if index > 0, !followsInterchange {
                // `lineName` below is the outgoing line; the incoming one is the previous group's,
                // which only this loop still knows.
                let previousLine = groups[index - 1].last.flatMap { graph.linesByID[$0.lineID] }
                let street = graph.streetTransfers[from.id]
                segments.append(RouteSegment(
                    id: UUID(),
                    type: .transfer,
                    lineName: line.name,
                    lineColorHex: line.colorHex,
                    fromStationName: from.name,
                    toStationName: from.name,
                    fromStationID: graph.qualifiedID(for: from.id),
                    toStationID: graph.qualifiedID(for: from.id),
                    duration: RouteSegment.changeoverAllowance + (street?.walkingDistanceMeters ?? 0) / 1.25,
                    distance: street?.walkingDistanceMeters ?? 0,
                    stops: 0,
                    stationStops: [],
                    // A change at one station draws nothing: each ride's track is tied to the
                    // station node by a grey connector, so the path reads platform → concourse →
                    // platform. A direct line between tracks would cut a corner nobody walks.
                    polylineCoordinates: [],
                    walkingDirections: nil,
                    accessibilityNotes: street.map { interchangeNotes($0, walkingTo: nil) } ?? [],
                    transferContext: previousLine.map { _ in
                        TransferContext(
                            cityID: graph.cityID(for: from.id),
                            stationID: graph.qualifiedID(for: from.id),
                            stationName: from.name
                        )
                    },
                    incomingLineName: previousLine?.name
                ))
            }
            let stationIDs = [first.fromStationID] + group.map(\.toStationID)
            let stops = stationIDs.compactMap { id -> RouteStationStop? in
                guard let station = graph.stationsByID[id] else { return nil }
                let lineCount = graph.lineCount(for: station)
                return RouteStationStop(
                    stationID: graph.qualifiedID(for: station.id),
                    name: station.name,
                    lineName: line.name,
                    lineColorHex: line.colorHex,
                    coordinate: CodableCoordinate(latitude: station.latitude, longitude: station.longitude),
                    arrivalTimeText: nil,
                    isTransfer: lineCount > 1,
                    lineID: line.id,
                    city: station.localizedCity
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
                // Named, because the results card lists it away from the leg.
                accessibilityNotes: line.fare == .premium ? [AppLocalization.text(
                    english: "\(line.localizedName) charges its own, higher fare",
                    simplified: "\(line.localizedName)单独计费，票价高于普通地铁",
                    traditional: "\(line.localizedName)單獨計費，票價高於普通地鐵"
                )] : [],
                transitContext: currentContext
            ))
        }
        return segments
    }

    /// What an interchange walk is, and what the fare does only where that has been checked;
    /// neither follows from `kind` (Beijing's out-of-station 虚拟换乘 bills as one trip, Guangzhou's
    /// shared concourse needs two tickets). `walkingTo` is nil for a change of line at one station.
    private func interchangeNotes(_ link: MetroInterchange, walkingTo destination: String?) -> [String] {
        var notes = [
            link.kind == .inStation
                ? AppLocalization.text(
                    english: "Connected inside the station",
                    simplified: "站内通道直接连通",
                    traditional: "站內通道直接連通"
                )
                : destination.map {
                    AppLocalization.text(
                        english: "Leave the station and walk to \($0)",
                        simplified: "需出站步行至\($0)",
                        traditional: "需出站步行至\($0)"
                    )
                } ?? AppLocalization.text(
                    english: "Out-of-station transfer: leave through the gates and re-enter",
                    simplified: "出站换乘：需出闸后步行，再进站",
                    traditional: "出站換乘：需出閘後步行，再進站"
                )
        ]
        // Silence where the fare is unknown: the rider can read the gates, and a wrong statement
        // sends them through the wrong one.
        if link.fare == .continuous {
            notes.append(AppLocalization.text(
                english: "Counts as one trip, with no second fare",
                simplified: "虚拟换乘，计为一次行程，不重复计费",
                traditional: "虛擬換乘，計為一次行程，不重複計費"
            ))
        }
        return notes
    }

    /// The walk from one station to the other that riders treat as the same interchange: a
    /// `.transfer`, a change of train, not a journey.
    private func interchangeSegment(
        _ edge: MetroGraphEdge,
        link: MetroInterchange,
        graph: MetroRoutingGraph
    ) -> RouteSegment? {
        guard let from = graph.stationsByID[edge.fromStationID],
              let to = graph.stationsByID[edge.toStationID] else { return nil }
        return RouteSegment(
            id: UUID(),
            type: .transfer,
            // No line: this leg is a walk between stations, and `TripStep.title` renders a line
            // name as "Transfer to …".
            lineName: nil,
            lineColorHex: nil,
            fromStationName: from.name,
            toStationName: to.name,
            fromStationID: graph.qualifiedID(for: from.id),
            toStationID: graph.qualifiedID(for: to.id),
            // Walking pace, plus the same fixed allowance an in-station change already carries.
            duration: edge.distance / 1.25 + RouteSegment.changeoverAllowance,
            distance: edge.distance,
            stops: 0,
            stationStops: [],
            polylineCoordinates: graph.edgeGeometries[edge.key] ?? [],
            walkingDirections: nil,
            accessibilityNotes: interchangeNotes(link, walkingTo: to.name)
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
        let onward = onwardStationIDs(for: group, line: line)
        let terminal = onward?.last.flatMap { graph.stationsByID[$0] }
        return TransitLegContext(
            lineID: line.id,
            lineName: line.name,
            boardingStationID: graph.qualifiedID(for: first.fromStationID),
            directionNextStationID: next.map { graph.qualifiedID(for: $0.id) },
            directionNextStationName: next?.name,
            arrivalPreviousStationName: previous?.name,
            directionTerminalStationName: terminal?.name,
            onwardStationNames: onward?.compactMap { graph.stationsByID[$0]?.name }
        )
    }

    /// The stations ahead of the rider on the train they board, to the end of its run, in travel
    /// order; the last is the terminus the platform sign names.
    ///
    /// The pattern must contain the boarding and alighting stations in that order, which picks the
    /// branch the rider rides (24 bundled lines branch, and a first-hop match fits every branch
    /// sharing the trunk). Where qualifying patterns still disagree, the answer is none: naming one
    /// branch would be a guess dressed as instruction.
    private func onwardStationIDs(for group: [MetroGraphEdge], line: MetroLine) -> [String]? {
        guard let boarding = group.first?.fromStationID, let alighting = group.last?.toStationID else { return nil }

        var candidates: [[String]] = []
        for pattern in line.servicePatterns where pattern.count > 1 && pattern.first != pattern.last {
            guard let start = pattern.firstIndex(of: boarding),
                  let end = pattern.firstIndex(of: alighting),
                  start != end else { continue }
            // A pattern is stored in one arbitrary direction and trains run both ways: with its
            // order the far end is ahead, against it the near end is.
            let onward = start < end
                ? Array(pattern[start...])
                : Array(pattern[...start].reversed())
            if !candidates.contains(onward) { candidates.append(onward) }
        }
        // Branches that disagree about where this train ends cannot both be right, and picking one
        // would hand the rider the other arm's terminus and last train.
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        await walkingRoutes.walkingSegment(from: from, to: to, fromName: fromName, toName: toName)
    }

    func accessSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String,
        mode: AccessLegMode
    ) async -> RouteSegment? {
        await walkingRoutes.accessSegment(
            from: from,
            to: to,
            fromName: fromName,
            toName: toName,
            mode: mode
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
