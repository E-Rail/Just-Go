import Foundation

struct TransferPoint: Identifiable, Codable {
    let id: UUID
    let stationName: String
    let stationID: String
    let fromLine: String
    let toLine: String
    let walkingDuration: TimeInterval
    let distance: Double
    let isAccessible: Bool
    let hasElevator: Bool
    let hasEscalator: Bool
    let instructions: [String]

    var formattedDuration: String {
        let minutes = Int(walkingDuration / 60)
        return "\(minutes) min walk"
    }
}
