import Foundation

struct RealTimeArrival: Identifiable, Codable {
    let id: UUID
    let lineName: String
    let lineColorHex: String
    let destination: String
    let arrivalTime: Date
    let minutesRemaining: Int
    let isAccessible: Bool
    let platformNumber: String?

    var formattedArrival: String {
        if minutesRemaining <= 0 { return "Arriving" }
        if minutesRemaining == 1 { return "1 min" }
        return "\(minutesRemaining) min"
    }

    var isArriving: Bool {
        minutesRemaining <= 1
    }
}
