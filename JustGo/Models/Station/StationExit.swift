import SwiftData

@Model
final class StationExit: Identifiable {
    var exitID: String
    var stationID: String
    var id: String { exitID }
    var name: String
    var nameEn: String?
    var hasElevator: Bool
    var hasEscalator: Bool
    var hasWheelchairRamp: Bool
    var isAccessible: Bool
    var nearbyLandmarks: [String]

    init(
        exitID: String,
        stationID: String,
        name: String,
        nameEn: String? = nil,
        hasElevator: Bool = false,
        hasEscalator: Bool = false,
        hasWheelchairRamp: Bool = false,
        isAccessible: Bool = false,
        nearbyLandmarks: [String] = []
    ) {
        self.exitID = exitID
        self.stationID = stationID
        self.name = name
        self.nameEn = nameEn
        self.hasElevator = hasElevator
        self.hasEscalator = hasEscalator
        self.hasWheelchairRamp = hasWheelchairRamp
        self.isAccessible = isAccessible
        self.nearbyLandmarks = nearbyLandmarks
    }
}
