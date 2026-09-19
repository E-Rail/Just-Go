import Foundation

/// The Sendable slice of an official schedule row that crosses the `OfficialCityPackService` actor
/// boundary.
struct StationServiceWindow: Sendable, Codable, Equatable, Hashable {
    let lineName: String
    /// The direction marker a rider reads on the platform sign — Beijing's `terminalStationName`,
    /// Shanghai's `往滴水湖`, Baidu's `潞阳方向`. Names *a* way, not necessarily where this train ends.
    let direction: String?
    /// Where this individual service terminates, when the operator distinguishes it from the
    /// direction marker: at 国贸 every northbound 10号线 row carries `terminalStationName = 双井` while
    /// `destStationName` is 车道沟, 成寿寺 or 巴沟, with last trains 21:28, 23:36 and 23:12. Optional
    /// because most sources publish one name, and older caches must decode.
    let destination: String?

    let firstTime: String?
    let lastTime: String?

    init(
        lineName: String,
        direction: String?,
        destination: String? = nil,
        firstTime: String?,
        lastTime: String?
    ) {
        self.lineName = lineName
        self.direction = direction
        self.destination = destination
        self.firstTime = firstTime
        self.lastTime = lastTime
    }
}

/// What the operator's timetable says about one ride, and how much of it we could actually pin to
/// the rider's own train.
struct ServiceHoursVerdict: Equatable {
    let status: RouteServiceStatus
    /// Whether this verdict is sound enough to re-plan on, not merely to show. Either the window
    /// was pinned to the rider's own direction and service, or the merged window (earliest first
    /// train, latest last train across every direction) already says the line is shut. The merge is
    /// an upper bound: "still running" from it may be another direction's train and never demotes a
    /// route, but "ended" from it means every direction has ended.
    ///
    /// Ring lines need the second case: they have no terminus to order stations against, so nothing
    /// on 北京 2号线 or 10号线 can ever be attributed.
    let isDefinitive: Bool

    static let unanswered = ServiceHoursVerdict(status: .unknown, isDefinitive: false)
}

/// Pure, synchronous resolver that turns first and last train rows into a `RouteServiceStatus` for
/// a departure moment. Owns all midnight-wrap, direction and service matching.
struct ServiceHoursResolver {
    /// "Last train soon" fires when the last train departs within this many minutes.
    var lastTrainSoonThresholdMinutes = 20

    /// The last train out of this station for this rider: in the direction they are going, on a
    /// service that reaches their stop.
    ///
    /// **Direction.** The two directions are not close: across 60 Beijing stations, 92% of
    /// station/line pairs differ by more than 15 minutes (石门 on 15号线 by 110). 天通苑南 on 5号线 runs
    /// southbound until 22:51 and northbound until 23:57.
    ///
    /// **Service.** Directions split into full runs and short-turns: 花园桥 eastbound on 6号线 has a
    /// full run to 潞阳 (last 22:45) and a short-turn to 草房 (last 23:56). Before 草房 the answer is
    /// 23:56, beyond it 22:45, which is why this takes the onward stations rather than a terminus.
    func verdict(
        boardingLineName: String?,
        onwardStationNames: [String]?,
        alightingStationName: String?,
        windows: [StationServiceWindow],
        at departure: Date
    ) -> ServiceHoursVerdict {
        guard !windows.isEmpty else { return .unanswered }

        // No line match is no answer, not another line's: a station whose operator spells the line
        // differently from the pack (首都机场线 against 机场线) must not be judged by whatever else calls
        // there.
        let pool = matchingWindows(lineName: boardingLineName, windows: windows)
        guard !pool.isEmpty else { return .unanswered }

        if let serving = servingWindows(in: pool, onward: onwardStationNames, alighting: alightingStationName),
           !serving.isEmpty {
            return ServiceHoursVerdict(status: status(from: serving, at: departure), isDefinitive: true)
        }
        // One window is not a merge, so nothing about it is optimistic; a merge that already reads
        // as shut is an upper bound that has passed. See `isDefinitive`.
        let merged = status(from: pool, at: departure)
        return ServiceHoursVerdict(
            status: merged,
            isDefinitive: pool.count == 1 || merged == .serviceEndedToday || merged.isNotYetStarted
        )
    }

    /// The services out of this station that go the rider's way and reach their stop. nil when the
    /// question cannot be asked (a ring, an ambiguous branch, a station list without the alighting
    /// stop), which differs from asking and finding nothing.
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
    /// `destination` first; the direction marker answers only for sources that publish one name for
    /// both.
    ///
    /// Matching is **exact after stripping wrapper words**, with no substring fallback:
    /// `"苹果园".contains("果园")` is true, and they are 29 stops apart on Beijing's 1号线/八通线. There are
    /// 158 such same-line pairs across 34 packs (`西安北站`⊃`西安站`, `天通苑北`⊃`天通苑`). An unresolved name
    /// returns nil, "not this rider's train", which falls back to the merged upper bound: shown,
    /// never acted on.
    private func destinationIndex(of window: StationServiceWindow, along onward: [String]) -> Int? {
        for text in [window.destination, window.direction] {
            guard let text else { continue }
            let needle = serviceDestinationName(text)
            guard !needle.isEmpty else { continue }
            if let match = onward.lastIndex(where: { normalizedStationName($0) == needle }) { return match }
        }
        return nil
    }

    /// A service's destination text reduced to the bare station name. The wrapper words are the
    /// only variation across the five sources, so stripping them and comparing exactly is enough;
    /// anything else fails to match.
    private func serviceDestinationName(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["开往", "驶往", "往", "至", "终点站", "终点"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        for suffix in ["方向", "终点站", "终点"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
            break
        }
        return normalizedStationName(value)
    }

    private func stationNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedStationName(lhs)
        let right = normalizedStationName(rhs)
        return !left.isEmpty && left == right
    }

    /// The service window these rows describe together, folded onto one service day.
    private func status(from pool: [StationServiceWindow], at departure: Date) -> RouteServiceStatus {
        // City packs put several branch or direction times in one string with " / " ("23:45 /
        // 0:06"); every value is considered.
        let firstMinutes = pool.flatMap { Self.times($0.firstTime) }
        let lastMinutes = pool.flatMap { Self.times($0.lastTime) }
        let nowMin = ChinaClock.minutesOfDay(of: departure)

        guard let firstMin = firstMinutes.min() else {
            return statusFromLastTrainAlone(lastMinutes, at: nowMin)
        }
        // The service-latest last train: a value earlier than the first train has wrapped past
        // midnight (0:06 is after 23:45), so order by service-day minutes.
        guard let lastMin = lastMinutes
            .map({ $0 >= firstMin ? $0 : $0 + 1440 })
            .max()
            .map({ $0 % 1440 }) else { return .unknown }

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

        // "Service ended" against "not yet started", for both window shapes. A non-wrapping window
        // has ended once past its last train. A wrapping one (last train after midnight) is off
        // between last and first; split that gap at its midpoint, early half ended and late half
        // not yet started, or `notYetStarted` would be unreachable (4:55 before a 5:00 first
        // train).
        let ended = firstMin <= lastMin
            ? nowMin > lastMin
            : nowMin > lastMin && nowMin < (lastMin + firstMin) / 2
        if ended {
            return .serviceEndedToday
        }
        return .notYetStarted(startsAtText: ChinaClock.clockText(minutes: firstMin))
    }

    /// What a row with a last train and no first train can honestly say. Without a first train
    /// `now` cannot be placed in the service day, so `.running` and `.notYetStarted` are
    /// unreachable. Two things do follow:
    ///
    /// - Shortly *before* the last train, service is running: no metro's first train is twenty
    /// minutes before its last. - Shortly *after* it, service has ended; bounded to four hours so
    /// breakfast is not answered with last night's closure.
    ///
    /// `RoutePlanningService` keeps one-sided rows on purpose (Hangzhou nulls placeholders per
    /// field), so they arrive regularly.
    private func statusFromLastTrainAlone(_ lastMinutes: [Int], at nowMin: Int) -> RouteServiceStatus {
        guard !lastMinutes.isEmpty else { return .unknown }
        let toLast = lastMinutes.map { ($0 - nowMin + 1440) % 1440 }
        if let soonest = toLast.min(), soonest <= lastTrainSoonThresholdMinutes {
            return .lastTrainSoon(minutesRemaining: soonest)
        }
        // Every published service has gone, and recently.
        let sinceLast = lastMinutes.map { (nowMin - $0 + 1440) % 1440 }
        if let mostRecent = sinceLast.min(), (1...240).contains(mostRecent) {
            return .serviceEndedToday
        }
        return .unknown
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

/// One hop of one line, in one direction. The unit a search bans by.
struct DirectedServiceHop: Hashable, Sendable {
    let lineID: String
    let fromStationID: String
    let toStationID: String
}

/// Every hop a shut service makes, expanded from the one oriented hop observed. The search needs
/// the whole direction: any edge on the same line running the same way is the same train, equally
/// gone. Each pattern holding both stations establishes which way round they sit; patterns holding
/// only one say nothing about direction and are skipped, since guessing could ban a branch the
/// rider can still use.
///
/// `identify` bridges the caller's station identifiers to the patterns' raw IDs; the returned hops
/// use raw IDs, compared against graph edges.
func directedHops(
    lineID: String,
    from: String,
    to: String,
    patterns: [[String]],
    identify: (String) -> String
) -> Set<DirectedServiceHop> {
    var hops: Set<DirectedServiceHop> = []
    for pattern in patterns where pattern.count > 1 {
        let identified = pattern.map(identify)
        guard let start = identified.firstIndex(of: from),
              let end = identified.firstIndex(of: to),
              start != end else { continue }
        let ordered = start < end ? pattern : Array(pattern.reversed())
        for pair in zip(ordered, ordered.dropFirst()) {
            hops.insert(DirectedServiceHop(lineID: lineID, fromStationID: pair.0, toStationID: pair.1))
        }
    }
    return hops
}
