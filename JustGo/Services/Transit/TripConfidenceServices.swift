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

/// Parses a crowd-control window string ("07:30-09:30", "07:30–09:30", "7:30~9:30",
/// "07:30至09:30", "07:30 to 09:30") into start/end minutes-of-day. City packs may pack
/// several windows into one string with "|", e.g. "7:00-9:00|17:45-19:15".
enum CrowdControlWindow {
    /// All windows contained in a string, splitting the "|" multi-window form first.
    static func parseAll(_ text: String) -> [(start: Int, end: Int)] {
        text.components(separatedBy: CharacterSet(charactersIn: "|;；"))
            .compactMap { parse($0) }
    }

    static func parse(_ text: String) -> (start: Int, end: Int)? {
        let normalized = text
            .replacingOccurrences(of: "至", with: "-")
            .replacingOccurrences(of: "to", with: "-", options: [.caseInsensitive])
        let separators = CharacterSet(charactersIn: "-–—~")
        let parts = normalized
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2,
              let start = ChinaClock.minutesOfDay(from: parts[0]),
              let end = ChinaClock.minutesOfDay(from: parts[1]) else { return nil }
        return (start, end)
    }
}

/// Pure, synchronous crowding forecast from captured crowd-control windows + a
/// weekday rush-hour heuristic. Heuristic-only signals are capped at `.moderate`;
/// `.busy` is reserved for an active official crowd-control window.
final class ComfortForecastService {
    private struct RushWindow { let start: Int; let end: Int; let label: String }

    private let rushWindows = [
        RushWindow(start: 7 * 60 + 30, end: 9 * 60 + 30, label: "7:30–9:30"),
        RushWindow(start: 17 * 60, end: 19 * 60 + 30, label: "17:00–19:30")
    ]

    func forecast(for crowdControl: RouteCrowdControl, tripTime: Date) -> RouteComfortForecast {
        // No official crowd-control data → no comfort signal at all, so confidence,
        // feasibility, ranking and UI are unchanged for routes/cities without city-pack
        // crowding data (the common case). The rush-hour heuristic only refines a route
        // that already has official crowd data.
        guard !crowdControl.isEmpty else { return .none }

        let nowMin = ChinaClock.minutesOfDay(of: tripTime)
        let isWeekday = ChinaClock.isWeekday(tripTime)

        var active: [ComfortStationFlag] = []
        for station in crowdControl.stations {
            for windowText in station.windows {
                let isActive = CrowdControlWindow.parseAll(windowText).contains {
                    ChinaClock.isWithin(minute: nowMin, start: $0.start, end: $0.end)
                }
                guard isActive else { continue }
                active.append(ComfortStationFlag(stationName: station.stationName, windowText: windowText))
            }
        }

        var rushLabel: String?
        if isWeekday {
            for window in rushWindows where ChinaClock.isWithin(minute: nowMin, start: window.start, end: window.end) {
                rushLabel = window.label
                break
            }
        }
        let isRush = rushLabel != nil

        let level: RouteComfortLevel
        if !active.isEmpty {
            level = .busy
        } else if isRush {
            level = .moderate
        } else {
            level = .comfortable
        }

        return RouteComfortForecast(
            level: level,
            isWeekdayRushHour: isRush,
            rushHourLabel: rushLabel,
            activeCrowdControl: active,
            dataConfidence: .official
        )
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
                    walkingPathCoordinates: segment.polylineCoordinates
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
                    transferCoordinate: transferStop?.coordinate
                ))
            case .subway, .transit:
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
                    exitHint: arrivalExit(for: segment.toStationName, in: route)
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
