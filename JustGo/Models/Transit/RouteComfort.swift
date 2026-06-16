import Foundation

/// How crowded a route is likely to be at the planned travel time.
enum RouteComfortLevel: String, Codable, Comparable {
    case comfortable
    case moderate
    case busy
    case unknown

    var sortValue: Int {
        switch self {
        case .comfortable: return 0
        case .unknown: return 1
        case .moderate: return 2
        case .busy: return 3
        }
    }

    static func < (lhs: RouteComfortLevel, rhs: RouteComfortLevel) -> Bool {
        lhs.sortValue < rhs.sortValue
    }

    var localizedTitle: String {
        switch self {
        case .comfortable:
            return AppLocalization.text(english: "Likely comfortable", simplified: "预计较为舒适", traditional: "預計較為舒適")
        case .moderate:
            return AppLocalization.text(english: "Moderately busy", simplified: "中等拥挤", traditional: "中等擁擠")
        case .busy:
            return AppLocalization.text(english: "Expect crowding", simplified: "预计拥挤", traditional: "預計擁擠")
        case .unknown:
            return AppLocalization.text(english: "Crowding unknown", simplified: "拥挤情况未知", traditional: "擁擠情況未知")
        }
    }
}

/// A single crowd-control window that is active for the trip, surfaced in the comfort card.
struct ComfortStationFlag: Identifiable, Equatable {
    let stationName: String
    let windowText: String

    var id: String { "\(stationName)|\(windowText)" }
}

/// Crowd-control windows for one route station, captured from the city pack at plan time.
struct ComfortStationWindows: Codable, Equatable {
    let stationName: String
    let stationID: String?
    let windows: [String]
}

/// Crowd-control snapshot stored on `Route` (Codable, defaulted like `dataCoverage`).
struct RouteCrowdControl: Codable, Equatable {
    var stations: [ComfortStationWindows]

    static let empty = RouteCrowdControl(stations: [])

    var isEmpty: Bool { stations.isEmpty }
}

/// Computed per render from `RouteCrowdControl` + the trip time. Not stored on `Route`.
struct RouteComfortForecast: Equatable {
    let level: RouteComfortLevel
    let isWeekdayRushHour: Bool
    let rushHourLabel: String?
    let activeCrowdControl: [ComfortStationFlag]
    let dataConfidence: DataConfidence

    static let none = RouteComfortForecast(
        level: .unknown,
        isWeekdayRushHour: false,
        rushHourLabel: nil,
        activeCrowdControl: [],
        dataConfidence: .unknown
    )

    /// Nothing useful to surface unless we have a non-unknown level, rush-hour, or an active window.
    var hasSignal: Bool {
        level != .unknown || isWeekdayRushHour || !activeCrowdControl.isEmpty
    }

    var summaryTitle: String { level.localizedTitle }

    var detailLines: [String] {
        var lines: [String] = []
        if isWeekdayRushHour, let rushHourLabel {
            lines.append(AppLocalization.text(
                english: "Weekday rush hour (\(rushHourLabel))",
                simplified: "工作日高峰时段（\(rushHourLabel)）",
                traditional: "工作日尖峰時段（\(rushHourLabel)）"
            ))
        }
        for flag in activeCrowdControl {
            lines.append(AppLocalization.text(
                english: "Crowd control at \(flag.stationName): \(flag.windowText)",
                simplified: "\(flag.stationName)限流：\(flag.windowText)",
                traditional: "\(flag.stationName)限流：\(flag.windowText)"
            ))
        }
        return lines
    }
}
