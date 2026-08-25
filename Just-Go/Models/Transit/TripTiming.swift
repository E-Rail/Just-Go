import Foundation

/// When the rider intends to travel. The single shared timeline that the time-aware-confidence
/// and departure-planner features both key off.
enum TripTimeAnchor: Codable, Equatable {
    case now
    case departBy(Date)
    case arriveBy(Date)

    var isExplicit: Bool {
        if case .now = self { return false }
        return true
    }
}

/// The resolved trip timeline derived from a `TripTimeAnchor` plus the route's duration.
struct TripTimeContext: Equatable {
    let anchor: TripTimeAnchor
    let totalDuration: TimeInterval
    /// "now" reference used so previews/tests can pin the clock.
    let referenceDate: Date

    init(anchor: TripTimeAnchor, totalDuration: TimeInterval, referenceDate: Date = Date()) {
        self.anchor = anchor
        self.totalDuration = totalDuration
        self.referenceDate = referenceDate
    }

    var isExplicit: Bool { anchor.isExplicit }

    var departureDate: Date {
        switch anchor {
        case .now:
            return referenceDate
        case .departBy(let date):
            return date
        case .arriveBy(let arrival):
            return arrival.addingTimeInterval(-totalDuration)
        }
    }

    var arrivalDate: Date {
        departureDate.addingTimeInterval(totalDuration)
    }

    var arrivalDetail: String { approximateArrivalText(arrivalDate) }
}

/// "Arrive about 14:37" — the only wording an arrival from this app can honestly carry.
///
/// Ride time is `distance / 9.7 + 30` per hop (`BundledMetroRouteProvider.trainCost`) and every
/// change is a flat five minutes. Nothing in the model waits for a train: no headway, no first-train
/// wait, no variation by time of day, because no bundled pack carries a timetable and inventing one
/// from station spacing is the inference this project exists to refuse. A total built that way is
/// honest as a duration and dishonest as a clock time, so the clock time says "about".
///
/// One function because two screens each hand-rolled the unhedged version while building the very
/// `TripTimeContext` that already knew how to word it, and the Chinese strings had carried 约/約 the
/// whole time — only the English had quietly dropped the hedge.
func approximateArrivalText(_ date: Date) -> String {
    let clock = ChinaClock.clockText(date)
    return AppLocalization.text(
        english: "Arrive about \(clock)",
        simplified: "约 \(clock) 到达",
        traditional: "約 \(clock) 抵達"
    )
}

/// Whether the subway is actually running for this route at the planned departure
/// moment, captured at plan time and stored on `Route` so confidence/feasibility stay synchronous.
enum RouteServiceStatus: Equatable {
    case running
    case lastTrainSoon(minutesRemaining: Int)
    case serviceEndedToday
    case notYetStarted(startsAtText: String?)
    case unknown

    /// The warning type to surface on the route, if any.
    var warningType: RouteWarning.WarningType? {
        switch self {
        case .lastTrainSoon: return .lastTrainSoon
        case .serviceEndedToday: return .serviceEnded
        case .notYetStarted: return .serviceNotStarted
        case .running, .unknown: return nil
        }
    }

    /// How bad this is for the rider, so a trip made of several rides can report its worst leg.
    /// `running` and `unknown` share the floor deliberately, neither is a problem to report, and
    /// which of the two a whole trip deserves is a question about certainty, not severity, decided
    /// by the caller.
    var severity: Int {
        switch self {
        case .running, .unknown: return 0
        case .lastTrainSoon: return 1
        case .notYetStarted: return 2
        case .serviceEndedToday: return 3
        }
    }
}

extension RouteServiceStatus {
    /// Whether a rider standing on the platform at this moment cannot get on a train.
    ///
    /// `.lastTrainSoon` is deliberately not one of these: there *is* still a train, and hurrying
    /// for it is a decision the rider gets to make. `.unknown` is not one either — nobody checked,
    /// and demoting a route on the strength of a question nobody answered would be a guess.
    var blocksBoarding: Bool {
        switch self {
        case .serviceEndedToday: return true
        case .notYetStarted: return true
        case .running, .lastTrainSoon, .unknown: return false
        }
    }

    /// Pattern matching on `.notYetStarted` needs its associated text spelled out at every site,
    /// which reads as noise wherever the question is only "is it shut".
    var isNotYetStarted: Bool {
        if case .notYetStarted = self { return true }
        return false
    }
}

extension RouteServiceStatus: Codable {
    private enum CodingKeys: String, CodingKey { case kind, minutes, startsAt }
    private enum Kind: String, Codable { case running, lastTrainSoon, serviceEndedToday, notYetStarted, unknown }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? container.decode(Kind.self, forKey: .kind)) ?? .unknown {
        case .running:
            self = .running
        case .lastTrainSoon:
            self = .lastTrainSoon(minutesRemaining: (try? container.decode(Int.self, forKey: .minutes)) ?? 0)
        case .serviceEndedToday:
            self = .serviceEndedToday
        case .notYetStarted:
            self = .notYetStarted(startsAtText: try? container.decode(String.self, forKey: .startsAt))
        case .unknown:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running:
            try container.encode(Kind.running, forKey: .kind)
        case .lastTrainSoon(let minutes):
            try container.encode(Kind.lastTrainSoon, forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
        case .serviceEndedToday:
            try container.encode(Kind.serviceEndedToday, forKey: .kind)
        case .notYetStarted(let startsAt):
            try container.encode(Kind.notYetStarted, forKey: .kind)
            try container.encodeIfPresent(startsAt, forKey: .startsAt)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}

extension RouteServiceStatus {
    /// Localized banner text for the alerting states. `nil` when there is nothing to surface.
    var bannerText: String? {
        switch self {
        case .running, .unknown:
            return nil
        case .lastTrainSoon(let minutes):
            return AppLocalization.text(
                english: "Last train in about \(minutes) min. Leave soon.",
                simplified: "末班车约\(minutes)分钟后，请尽快出发。",
                traditional: "末班車約\(minutes)分鐘後，請盡快出發。"
            )
        case .serviceEndedToday:
            return AppLocalization.text(
                english: "Service has ended for today",
                simplified: "今日运营已结束",
                traditional: "今日營運已結束"
            )
        case .notYetStarted(let startsAt):
            if let startsAt {
                return AppLocalization.text(
                    english: "Service starts at \(startsAt)",
                    simplified: "运营 \(startsAt) 开始",
                    traditional: "營運 \(startsAt) 開始"
                )
            }
            return AppLocalization.text(
                english: "Service has not started yet",
                simplified: "运营尚未开始",
                traditional: "營運尚未開始"
            )
        }
    }

    /// Short reason string for the confidence breakdown.
    var confidenceReason: String? {
        switch self {
        case .running:
            return AppLocalization.text(english: "Within service hours", simplified: "在运营时间内", traditional: "在營運時間內")
        case .lastTrainSoon:
            return AppLocalization.text(english: "Close to the last train", simplified: "接近末班车", traditional: "接近末班車")
        case .serviceEndedToday:
            return AppLocalization.text(english: "Service has ended for today", simplified: "今日运营已结束", traditional: "今日營運已結束")
        case .notYetStarted:
            return AppLocalization.text(english: "Service has not started yet", simplified: "运营尚未开始", traditional: "營運尚未開始")
        case .unknown:
            return nil
        }
    }
}

/// Whether the rider can still catch the last train given the planned departure.
enum LastTrainStatus: Equatable {
    case unknown
    case ok
    case tight(marginMinutes: Int)
    case missed
    case notStarted(startsAtText: String?)
}

/// A computed "leave by / arrive by" plan. Recomputed per render from `TripTimeContext`
/// so the countdown stays current; intentionally not stored on `Route`.
struct DeparturePlan: Equatable {
    let anchor: TripTimeAnchor
    let leaveByDate: Date
    let arrivalDate: Date
    let referenceDate: Date
    let lastTrainStatus: LastTrainStatus

    var minutesUntilLeave: Int {
        Int((leaveByDate.timeIntervalSince(referenceDate) / 60).rounded())
    }

    var isExplicit: Bool { anchor.isExplicit }

    var leaveByText: String {
        ChinaClock.clockText(leaveByDate)
    }

    var arriveByText: String {
        ChinaClock.clockText(arrivalDate)
    }

    var leaveByHeadline: String {
        let clock = leaveByText
        let minutes = minutesUntilLeave
        if !isExplicit { return AppLocalization.text(english: "Leave when ready", simplified: "准备好即可出发", traditional: "準備好即可出發") }
        if minutes <= 0 {
            return AppLocalization.text(
                english: "Leave now (by \(clock))",
                simplified: "现在出发（不晚于 \(clock)）",
                traditional: "現在出發（不晚於 \(clock)）"
            )
        }
        return AppLocalization.text(
            english: "Leave by \(clock), in \(minutes) min",
            simplified: "请于 \(clock) 前出发，还有 \(minutes) 分钟",
            traditional: "請於 \(clock) 前出發，還有 \(minutes) 分鐘"
        )
    }

    var arriveByDetail: String { approximateArrivalText(arrivalDate) }

    var lastTrainDetail: String? {
        switch lastTrainStatus {
        case .unknown:
            return nil
        case .ok:
            return AppLocalization.text(english: "Comfortably within the last train", simplified: "距末班车时间充裕", traditional: "距末班車時間充裕")
        case .tight(let margin):
            return AppLocalization.text(
                english: "Only ~\(margin) min before the last train",
                simplified: "距末班车仅约 \(margin) 分钟",
                traditional: "距末班車僅約 \(margin) 分鐘"
            )
        case .missed:
            return AppLocalization.text(english: "The last train has already departed", simplified: "末班车已开走", traditional: "末班車已開走")
        case .notStarted(let startsAt):
            if let startsAt {
                return AppLocalization.text(
                    english: "Service starts at \(startsAt)",
                    simplified: "运营 \(startsAt) 开始",
                    traditional: "營運 \(startsAt) 開始"
                )
            }
            return AppLocalization.text(english: "Service has not started yet", simplified: "运营尚未开始", traditional: "營運尚未開始")
        }
    }
}

extension Route {
    /// "Leave by / arrive by" plan for an explicit anchor, derived from the plan-time
    /// `serviceStatus` so the route list and the detail screen always agree. `nil` for `.now`.
    func departurePlan(anchor: TripTimeAnchor) -> DeparturePlan? {
        guard anchor.isExplicit else { return nil }
        let context = TripTimeContext(anchor: anchor, totalDuration: totalDuration)
        let lastTrain: LastTrainStatus
        switch serviceStatus {
        case .unknown: lastTrain = .unknown
        case .running: lastTrain = .ok
        case .lastTrainSoon(let minutes): lastTrain = .tight(marginMinutes: minutes)
        case .serviceEndedToday: lastTrain = .missed
        case .notYetStarted(let startsAtText): lastTrain = .notStarted(startsAtText: startsAtText)
        }
        return DeparturePlan(
            anchor: anchor,
            leaveByDate: context.departureDate,
            arrivalDate: context.arrivalDate,
            referenceDate: context.referenceDate,
            lastTrainStatus: lastTrain
        )
    }
}
