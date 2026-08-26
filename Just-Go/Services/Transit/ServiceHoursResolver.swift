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

/// What the operator's timetable says about one ride, and how much of it we could actually pin to
/// the rider's own train.
struct ServiceHoursVerdict: Equatable {
    let status: RouteServiceStatus
    /// Whether this verdict is sound enough to re-plan on, as opposed to merely worth showing.
    ///
    /// Two ways to earn it. Either the window was pinned to the rider's own direction and service,
    /// or the merged window — the earliest first train and the latest last train across every
    /// direction — *already* says the line is shut. The merge is an upper bound by construction, so
    /// it can only ever over-state how long a line runs: "still running" out of it may be another
    /// direction's train and must never demote a route, while "ended" out of it means every
    /// direction has ended and is as certain as an attributed one.
    ///
    /// That second case is not a technicality. Ring lines have no terminus to order stations
    /// against, so nothing on 北京 2号线 or 10号线 can ever be attributed — and without this they
    /// would be the two lines a re-plan never fired for.
    let isDefinitive: Bool

    static let unanswered = ServiceHoursVerdict(status: .unknown, isDefinitive: false)
}

/// Pure, synchronous resolver that turns first/last-train rows into a `RouteServiceStatus` for a
/// given departure moment. Owns all the midnight-wrap, direction and service matching so it lives
/// in exactly one place.
struct ServiceHoursResolver {
    /// "Last train soon" fires when the last train departs within this many minutes.
    var lastTrainSoonThresholdMinutes = 20

    /// The last train out of this station, for this rider, in the direction they are going and on a
    /// train that gets them where they are going.
    ///
    /// All three qualifiers are load-bearing, and until now only the first was applied.
    ///
    /// **Direction.** An operator publishes one window per direction and they are not close. Across
    /// a 60-station sample of Beijing, 92 % of station/line pairs had their two directions more than
    /// 15 minutes apart and 81 % more than 30; 石门 on 15号线 differs by 110. Merging them reported
    /// 天通苑南 on 5号线 as running until 23:57 when the southbound last train goes at 22:51.
    ///
    /// **Service.** Directions subdivide again into full runs and short-turns. 花园桥 eastbound on
    /// 6号线 has a full run to 潞阳 (last 22:45) and a short-turn to 草房 (last 23:56), so the answer
    /// depends on where the rider gets off: before 草房 it is 23:56, beyond it 22:45. That is why
    /// this takes the onward stations rather than just a terminus — a terminus alone cannot tell
    /// you whether a short-turn reaches you.
    func verdict(
        boardingLineName: String?,
        onwardStationNames: [String]?,
        alightingStationName: String?,
        windows: [StationServiceWindow],
        at departure: Date
    ) -> ServiceHoursVerdict {
        guard !windows.isEmpty else { return .unanswered }

        let matched = matchingWindows(lineName: boardingLineName, windows: windows)
        let pool = matched.isEmpty ? windows : matched

        if let serving = servingWindows(in: pool, onward: onwardStationNames, alighting: alightingStationName),
           !serving.isEmpty {
            return ServiceHoursVerdict(status: status(from: serving, at: departure), isDefinitive: true)
        }
        // One window is not a merge, so there is nothing to be optimistic about; and a merge that
        // already reads as shut is an upper bound that has passed. See `isDefinitive`.
        let merged = status(from: pool, at: departure)
        return ServiceHoursVerdict(
            status: merged,
            isDefinitive: pool.count == 1 || merged == .serviceEndedToday || merged.isNotYetStarted
        )
    }

    /// The services out of this station that both go the rider's way and reach their stop.
    ///
    /// `nil` when the question cannot be asked at all — a ring, an ambiguous branch, or a station
    /// list that does not contain the alighting stop — which is different from asking it and
    /// finding nothing.
    private func servingWindows(
        in pool: [StationServiceWindow],
        onward: [String]?,
        alighting: String?
    ) -> [StationServiceWindow]? {
        guard let onward, onward.count > 1, let alighting else { return nil }
        guard let alightingIndex = onward.firstIndex(where: { stationNamesMatch($0, alighting) }) else { return nil }
        return pool.filter { window in
            guard let destination = destinationIndex(of: window, along: onward) else { return false }
            // A train that turns back before the rider's stop is not their train, however late it
            // runs. One that goes further is.
            return destination >= alightingIndex
        }
    }

    /// Where a window's service ends, as a position in the stations ahead of the rider.
    ///
    /// Operators name a service by its destination and each spells it differently: Beijing sends
    /// `terminalStationName` ("宋家庄"), Guangzhou `toStationName`, Shanghai a sentence, Baidu
    /// "潞阳方向". Rather than parse four grammars, look for any onward station named inside the
    /// text and take the furthest — which is the destination, since a service's own text never
    /// names a stop beyond where it stops.
    private func destinationIndex(of window: StationServiceWindow, along onward: [String]) -> Int? {
        guard let direction = window.direction else { return nil }
        let haystack = normalizedStationName(direction)
        guard !haystack.isEmpty else { return nil }

        if let exact = onward.lastIndex(where: { normalizedStationName($0) == haystack }) { return exact }
        // Containment is the fallback for "…方向" and full sentences. Single-character names are
        // excluded from it: with 站 stripped, 西站 becomes 西, which is inside half the network.
        return onward.lastIndex { name in
            let needle = normalizedStationName(name)
            return needle.count >= 2 && haystack.contains(needle)
        }
    }

    private func stationNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedStationName(lhs)
        let right = normalizedStationName(rhs)
        return !left.isEmpty && left == right
    }

    /// The service window these rows describe together, folded onto one service day.
    private func status(from pool: [StationServiceWindow], at departure: Date) -> RouteServiceStatus {
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
        // late half is "not yet started": otherwise notYetStarted is unreachable for all
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
