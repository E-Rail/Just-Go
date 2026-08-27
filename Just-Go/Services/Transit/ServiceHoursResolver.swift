import Foundation

/// The Sendable slice of an official schedule row that crosses the
/// `OfficialCityPackService` actor boundary. Shared by time-aware-confidence
/// and departure-planner.
struct StationServiceWindow: Sendable, Codable, Equatable, Hashable {
    let lineName: String
    /// The direction marker a rider reads on the platform sign — Beijing's `terminalStationName`,
    /// Shanghai's `往滴水湖`, Baidu's `潞阳方向`. Names *a* way, not necessarily where this train ends.
    let direction: String?
    /// Where this individual service actually terminates, when the operator distinguishes it.
    ///
    /// Beijing publishes both and they are not the same field: at 国贸 every northbound 10号线 row
    /// carries `terminalStationName = 双井` while `destStationName` is 车道沟, 成寿寺 or 巴沟 — three
    /// services, three different last trains, 21:28 / 23:36 / 23:12. Keying only on the direction
    /// marker collapsed them into one 23:36 window, which is what told a rider bound for 车道沟 that
    /// they had two hours they did not have. Optional because most sources publish only one name,
    /// and because a cache written before this existed must still decode.
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
    /// All three qualifiers are load-bearing, and until recently only the first was applied.
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

        // No line match is no answer, not somebody else's answer. `pool` used to fall back to every
        // window at the station, so a station whose operator spells the line differently from the
        // pack — 首都机场线 against 机场线, which share no `transitLineReferences` — was judged by
        // whatever other lines call there. At 西直门 that is 2号线, 4号线 and 13号线 together, and a
        // single-row fallback was even marked definitive and could ban the rider's line on the
        // strength of a different line's last train.
        let pool = matchingWindows(lineName: boardingLineName, windows: windows)
        guard !pool.isEmpty else { return .unanswered }

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
    /// `destination` first, because where a service terminates is exactly this question; the
    /// direction marker only answers it for sources that publish one name for both.
    ///
    /// Matching is **exact, after stripping the wrapper words**, and deliberately has no substring
    /// fallback. Operators name a service plainly — Beijing `环球度假区`, Shanghai `往滴水湖`,
    /// Guangzhou `toStationName`, Baidu `潞阳方向` — so containment bought nothing and cost a great
    /// deal: `"苹果园".contains("果园")` is true, and 苹果园 and 果园 are 29 stops apart at opposite
    /// ends of Beijing's fused 1号线/八通线. An eastbound rider at 国贸 therefore had the *westbound*
    /// window admitted as their own service, and marked definitive. There are 158 such same-line
    /// pairs across 107 lines in 34 packs — `西安北站`⊃`西安站`, `火车东站`⊃`火车站`,
    /// `天通苑北`⊃`天通苑` — and `normalizedStationName` strips every `站`, which manufactures more.
    ///
    /// A name that does not resolve returns nil, which `servingWindows` reads as "not this rider's
    /// train". That is the safe direction: the trip falls back to the merged upper bound, which is
    /// shown but never acted on.
    private func destinationIndex(of window: StationServiceWindow, along onward: [String]) -> Int? {
        for text in [window.destination, window.direction] {
            guard let text else { continue }
            let needle = serviceDestinationName(text)
            guard !needle.isEmpty else { continue }
            if let match = onward.lastIndex(where: { normalizedStationName($0) == needle }) { return match }
        }
        return nil
    }

    /// A service's destination text reduced to the bare station name it contains.
    ///
    /// The wrapper words are the only variation across the five sources, so removing them and
    /// comparing exactly is enough. Anything else — a full sentence, an unrecognised grammar —
    /// simply fails to match, which is the honest outcome.
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
        // City packs pack multiple branch/direction times into one string with " / ",
        // e.g. "23:45 / 0:06". Split so every value is considered.
        let firstMinutes = pool.flatMap { Self.times($0.firstTime) }
        let lastMinutes = pool.flatMap { Self.times($0.lastTime) }
        let nowMin = ChinaClock.minutesOfDay(of: departure)

        guard let firstMin = firstMinutes.min() else {
            return statusFromLastTrainAlone(lastMinutes, at: nowMin)
        }
        // Pick the service-latest last train: a value before the first train wrapped past
        // midnight (e.g. 0:06 is *after* 23:45), so order by service-day minutes then fold back.
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

    /// What a row holding a last train and no first train can honestly say.
    ///
    /// Not much, but not nothing, and until now it said `.unknown` — withholding the single fact
    /// this whole feature exists to report. `RoutePlanningService` deliberately keeps one-sided rows
    /// (Hangzhou nulls placeholder times per field, and Beijing's own merge can leave either side
    /// empty), so they arrive here regularly.
    ///
    /// Without a first train there is no way to place `now` inside the service day, so `.running`
    /// and `.notYetStarted` are both unreachable: claiming either would be inventing the half of the
    /// window we were not given. Two things do follow:
    ///
    /// - Shortly *before* the last train, service is certainly running — no metro's first train is
    ///   twenty minutes before its last — so the countdown is sound.
    /// - Shortly *after* it, service has certainly ended. Bounded to four hours so that a query at
    ///   breakfast is not answered with last night's closure.
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
