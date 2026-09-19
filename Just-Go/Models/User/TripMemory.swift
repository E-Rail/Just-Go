import Foundation

struct TripRecord: Identifiable, Codable, Equatable {
    let id: String
    let originName: String
    let destinationName: String
    let cityID: String
    let plannedDuration: TimeInterval
    let walkingDistance: Double
    let transferCount: Int
    let strategy: RoutePreference
    let warningMessages: [String]
    let createdAt: Date
    var completedAt: Date?
    var note: String?
    /// Where the trip starts and ends on the ground, so it can be planned again from the same two
    /// places. Nil on rows saved before these existed; those re-plan from their names instead.
    var originCoordinate: CodableCoordinate?
    var destinationCoordinate: CodableCoordinate?

    var isCompleted: Bool {
        completedAt != nil
    }
}
