import Foundation

enum TrainTimeSource: String, Codable {
    case liveCountdown
    case officialSchedule
    case bundledSchedule

    var statusLabel: String {
        switch self {
        case .liveCountdown:
            return AppLocalization.localized("Live countdown")
        case .officialSchedule:
            return AppLocalization.localized("Official scheduled time")
        case .bundledSchedule:
            return AppLocalization.localized("Bundled schedule")
        }
    }
}

struct RealTimeArrival: Identifiable, Codable {
    let id: UUID
    let lineName: String
    let lineColorHex: String
    let destination: String
    let minutesRemaining: Int?
    let timeText: String?
    let source: TrainTimeSource

    var formattedArrival: String {
        if let minutesRemaining {
            if minutesRemaining <= 0 { return AppLocalization.localized("Arriving") }
            return AppLocalization.minutes(minutesRemaining)
        }
        return timeText ?? AppLocalization.localized("Schedule unavailable")
    }

    var isArriving: Bool {
        minutesRemaining.map { $0 <= 1 } ?? false
    }

    var statusLabel: String {
        source.statusLabel
    }

    var hasLiveCountdown: Bool {
        source == .liveCountdown && minutesRemaining != nil
    }
}
