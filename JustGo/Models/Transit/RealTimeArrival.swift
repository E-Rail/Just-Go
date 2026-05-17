import Foundation

enum TrainTimeSource: String, Codable {
    case liveCountdown
    case amapSchedule
    case bundledSchedule

    var statusLabel: String {
        switch self {
        case .liveCountdown:
            return AppLocalization.localized("Live countdown")
        case .amapSchedule:
            return AppLocalization.localized("First/last train from AMap")
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
    let arrivalTime: Date?
    let minutesRemaining: Int?
    let timeText: String?
    let isAccessible: Bool
    let platformNumber: String?
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
        minutesRemaining != nil
    }
}
