import Foundation

/// Stateless builder that turns a `Route` into an ordered Live "Go" plan using
/// only `route.segments` (no schedule/time data needed).
struct LiveGoTripBuilder {
    func plan(for route: Route) -> LiveTripPlan {
        var steps: [TripStep] = []
        for (index, segment) in route.segments.enumerated() {
            switch segment.type {
            case .walking, .cycling, .driving:
                let isOrigin = index == 0
                // The same door the plan routed to, so the screen the rider actually follows on
                // foot names the entrance the detail screen promised instead of just the station.
                let guide = isOrigin ? route.originAccessGuide : route.destinationAccessGuide
                steps.append(TripStep(
                    id: steps.count,
                    kind: isOrigin ? .walkToStation : .walkToDestination,
                    lineName: nil,
                    lineColorHex: nil,
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
                // The transfer segment's own stationStops is always empty by construction.
                // The transfer station's coordinate instead lives on stationStops.first of the
                // ride segment that immediately follows it (same station, since a transfer and
                // the ride after it always share the same starting station).
                let nextRide = route.segments.indices.contains(index + 1) ? route.segments[index + 1] : nil
                let transferStop = nextRide?.stationStops.first { $0.stationID == segment.toStationID }
                    ?? nextRide?.stationStops.first
                steps.append(TripStep(
                    id: steps.count,
                    kind: .transfer,
                    lineName: segment.lineName,
                    lineColorHex: segment.lineColorHex,
                    fromStationName: segment.fromStationName,
                    toStationName: nil,
                    stopCount: 0,
                    walkingDistance: 0,
                    duration: segment.duration,
                    transferCoordinate: transferStop?.coordinate,
                    segmentIndex: index,
                    transferContext: segment.transferContext
                ))
            case .subway:
                steps.append(TripStep(
                    id: steps.count,
                    kind: .ride,
                    lineName: segment.lineName,
                    lineColorHex: segment.lineColorHex,
                    fromStationName: segment.fromStationName,
                    toStationName: segment.toStationName,
                    stopCount: segment.stops,
                    walkingDistance: 0,
                    duration: segment.duration,
                    exitHint: arrivalExit(for: segment.toStationName, in: route),
                    segmentIndex: index
                ))
            }
        }
        if !steps.isEmpty {
            steps.append(TripStep(
                id: steps.count,
                kind: .arrive,
                lineName: nil,
                lineColorHex: nil,
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
        }?.exit?.name
    }
}
