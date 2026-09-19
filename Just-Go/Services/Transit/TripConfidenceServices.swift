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
                    notes: segment.accessibilityNotes,
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

    /// The recommended exit at a ride step's alight station, from the route's per-station guidance.
    private func arrivalExit(for stationName: String?, in route: Route) -> String? {
        guard let stationName else { return nil }
        return route.stationGuidance.first {
            $0.stationName == stationName && ($0.role == .arrival || $0.role == .transfer)
        }?.exit?.namedDoor
    }
}
