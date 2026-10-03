import Foundation

/// Turns a `Route` into an ordered Live Go plan from `route.segments` alone.
struct LiveGoTripBuilder {
    func plan(for route: Route) -> LiveTripPlan {
        var steps: [TripStep] = []
        for (index, segment) in route.segments.enumerated() {
            switch segment.type {
            case .walking, .cycling, .driving:
                let isOrigin = index == 0
                // The door the plan routed to, so the step the rider follows names the entrance the
                // detail screen promised.
                let guide = isOrigin ? route.originAccessGuide : route.destinationAccessGuide
                steps.append(TripStep(
                    id: steps.count,
                    kind: isOrigin ? .walkToStation : .walkToDestination,
                    lineName: nil,
                    colorHex: segment.colorHex,
                    fromStationName: segment.fromStationName,
                    toStationName: isOrigin ? segment.toStationName : route.destination,
                    stopCount: 0,
                    walkingDistance: segment.distance,
                    duration: segment.duration,
                    exitHint: guide?.accessPoint?.namedDoor,
                    walkingPathCoordinates: segment.polylineCoordinates,
                    segmentIndex: index,
                    accessMode: segment.accessLegMode
                ))
            case .transfer:
                // A transfer segment has no stops; the transfer station's coordinate is the first
                // stop of the ride that follows it, which starts at the same station.
                let nextRide = route.segments.indices.contains(index + 1) ? route.segments[index + 1] : nil
                let transferStop = nextRide?.stationStops.first { $0.stationID == segment.toStationID }
                    ?? nextRide?.stationStops.first
                steps.append(TripStep(
                    id: steps.count,
                    kind: .transfer,
                    lineName: segment.lineName,
                    colorHex: segment.colorHex,
                    fromStationName: segment.fromStationName,
                    toStationName: nil,
                    stopCount: 0,
                    walkingDistance: 0,
                    duration: segment.duration,
                    notes: route.cityCrossings(by: index) + segment.accessibilityNotes,
                    transferCoordinate: transferStop?.coordinate,
                    segmentIndex: index,
                    transferContext: segment.transferContext
                ))
            case .subway:
                steps.append(TripStep(
                    id: steps.count,
                    kind: .ride,
                    lineName: segment.lineName,
                    colorHex: segment.colorHex,
                    fromStationName: segment.fromStationName,
                    toStationName: segment.toStationName,
                    stopCount: segment.stops,
                    walkingDistance: 0,
                    duration: segment.duration,
                    exitHint: arrivalExit(for: segment.toStationName, in: route),
                    alightAfterStationName: segment.transitContext?.arrivalPreviousStationName,
                    segmentIndex: index
                ))
            }
        }
        if !steps.isEmpty {
            steps.append(TripStep(
                id: steps.count,
                kind: .arrive,
                lineName: nil,
                colorHex: nil,
                fromStationName: nil,
                toStationName: route.destination,
                stopCount: 0,
                walkingDistance: 0
            ))
        }
        return LiveTripPlan(steps: steps, origin: route.origin, destination: route.destination)
    }

    /// The same steps as the clock and a location fix see them: one per `TripStep`, in order, so an
    /// index into one is an index into the other.
    func timelineSteps(for route: Route) -> [TimelineStep] {
        var steps: [TimelineStep] = []
        for segment in route.segments {
            switch segment.type {
            case .walking, .cycling, .driving:
                steps.append(TimelineStep(
                    kind: .access,
                    duration: segment.duration,
                    path: segment.polylineCoordinates.map(TimelinePoint.init)
                ))
            case .transfer:
                steps.append(TimelineStep(kind: .transfer, duration: segment.duration))
            case .subway:
                // A change's allowance already carries the wait for the next train. A ride reached
                // any other way, from the street or as the trip's first step, has none of its own.
                let boarding = steps.last?.kind == .transfer ? 0 : TripTimeline.boardingAllowance
                steps.append(TimelineStep(
                    kind: .ride,
                    duration: boarding + segment.duration,
                    stops: timelineStops(for: segment),
                    boarding: boarding
                ))
            }
        }
        if !steps.isEmpty {
            steps.append(TimelineStep(kind: .arrive, duration: 0))
        }
        return steps
    }

    /// A ride's stops with the time each is reached. The planner's own per-stop times where the
    /// route carries them; a trip saved before it did has the leg's duration shared out by the
    /// distance between stops, or evenly where a stop has no coordinate.
    private func timelineStops(for segment: RouteSegment) -> [TimelineStop] {
        let stops = segment.stationStops
        guard stops.count > 1 else { return [] }
        let points = stops.map { $0.coordinate.map(TimelinePoint.init) }

        let planned = stops.compactMap(\.offsetSeconds)
        let offsets: [TimeInterval]
        if planned.count == stops.count {
            offsets = planned
        } else {
            let hops: [Double] = zip(points, points.dropFirst()).map { from, to in
                guard let from, let to else { return 0 }
                return from.distance(to: to)
            }
            let total = hops.reduce(0, +)
            let even = hops.contains(0) || total <= 0
            var travelled = 0.0
            offsets = [0] + hops.enumerated().map { index, hop in
                travelled += hop
                return segment.duration * (even ? Double(index + 1) / Double(hops.count) : travelled / total)
            }
        }
        return zip(stops, zip(points, offsets)).map { stop, rest in
            TimelineStop(name: stop.name, point: rest.0, offset: rest.1)
        }
    }

    /// The recommended exit at a ride step's alight station, from the route's per-station guidance.
    private func arrivalExit(for stationName: String?, in route: Route) -> String? {
        guard let stationName else { return nil }
        return route.stationGuidance.first {
            $0.stationName == stationName && ($0.role == .arrival || $0.role == .transfer)
        }?.exit?.namedDoor
    }
}

extension TimelinePoint {
    init(_ coordinate: CodableCoordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
