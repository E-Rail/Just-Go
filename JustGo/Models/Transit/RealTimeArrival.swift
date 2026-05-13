import Foundation

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
}
