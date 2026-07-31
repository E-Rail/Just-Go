import Foundation

/// The Sendable slice of an official schedule row that crosses the
/// `OfficialCityPackService` actor boundary. Shared by time-aware-confidence
/// and departure-planner.
struct StationServiceWindow: Sendable, Codable, Equatable {
    let lineName: String
    let direction: String?
    let firstTime: String?
    let lastTime: String?
}

/// Pure, synchronous resolver that turns first/last-train rows into a
/// `RouteServiceStatus` for a given departure moment. Owns all the midnight-wrap
/// and line-matching logic so it lives in exactly one place.
struct ServiceHoursResolver {
    /// "Last train soon" fires when the last train departs within this many minutes.
    var lastTrainSoonThresholdMinutes = 20

    func status(boardingLineName: String?, windows: [StationServiceWindow], at departure: Date) -> RouteServiceStatus {
        guard !windows.isEmpty else { return .unknown }

        let matched = matchingWindows(lineName: boardingLineName, windows: windows)
        let pool = matched.isEmpty ? windows : matched

        // City packs pack multiple branch/direction times into one string with " / ",
        // e.g. "23:45 / 0:06". Split so every value is considered.
        let firstMinutes = pool.flatMap { Self.times($0.firstTime) }
        let lastMinutes = pool.flatMap { Self.times($0.lastTime) }
        guard let firstMin = firstMinutes.min() else { return .unknown }
        // Pick the service-latest last train: a value before the first train wrapped past
        // midnight (e.g. 0:06 is *after* 23:45), so order by service-day minutes then fold back.
        guard let lastMin = lastMinutes
            .map({ $0 >= firstMin ? $0 : $0 + 1440 })
            .max()
            .map({ $0 % 1440 }) else { return .unknown }

        let nowMin = ChinaClock.minutesOfDay(of: departure)
        let running: Bool
        if firstMin <= lastMin {
            running = nowMin >= firstMin && nowMin <= lastMin
        } else {
            running = nowMin >= firstMin || nowMin <= lastMin
        }

        if running {
            let minutesToLast = (lastMin - nowMin + 1440) % 1440
            if minutesToLast <= lastTrainSoonThresholdMinutes {
                return .lastTrainSoon(minutesRemaining: minutesToLast)
            }
            return .running
        }

        // Distinguish "service ended" from "not yet started" for both window shapes.
        // Non-wrap [first, last]: ended once past last.
        // Wrap window (last < first, last train past midnight): the off-service gap is
        // (last, first). Split at the gap midpoint so the early half is "ended" and the
        // late half is "not yet started" — otherwise notYetStarted is unreachable for all
        // midnight-wrap services (e.g. at 4:55 AM before a 5:00 first train).
        let ended = firstMin <= lastMin
            ? nowMin > lastMin
            : nowMin > lastMin && nowMin < (lastMin + firstMin) / 2
        if ended {
            return .serviceEndedToday
        }
        return .notYetStarted(startsAtText: ChinaClock.clockText(minutes: firstMin))
    }

    /// Parses a possibly multi-value ("23:45 / 0:06") time field into minutes-of-day.
    private static func times(_ field: String?) -> [Int] {
        (field ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/／"))
            .compactMap { ChinaClock.minutesOfDay(from: $0) }
    }

    private func matchingWindows(lineName: String?, windows: [StationServiceWindow]) -> [StationServiceWindow] {
        guard let lineName, !lineName.isEmpty else { return [] }
        let targetFull = fullTransitLineName(lineName)
        let targetRefs = transitLineReferences(lineName)
        return windows.filter { window in
            fullTransitLineName(window.lineName) == targetFull ||
                !transitLineReferences(window.lineName).isDisjoint(with: targetRefs)
        }
    }
}

/// Stateless builder that turns a `Route` into an ordered Live "Go" plan using
/// only `route.segments` (no schedule/time data needed).
struct LiveGoTripBuilder {
    func plan(for route: Route) -> LiveTripPlan {
        var steps: [TripStep] = []
        for (index, segment) in route.segments.enumerated() {
            switch segment.type {
            case .walking:
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
                    segmentIndex: index
                ))
            case .transfer:
                // The transfer segment's own stationStops is always empty by construction —
                // the transfer station's coordinate instead lives on stationStops.first of the
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
