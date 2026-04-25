import SwiftData
import Foundation

@Model
final class FavoriteRoute: Identifiable {
    @Attribute(.unique) var routeID: String
    var id: String { routeID }
    var originStationID: String
    var originStationName: String
    var destinationStationID: String
    var destinationStationName: String
    var lineName: String?
    var savedDate: Date
    var usageCount: Int

    init(
        routeID: String = UUID().uuidString,
        originStationID: String,
        originStationName: String,
        destinationStationID: String,
        destinationStationName: String,
        lineName: String? = nil
    ) {
        self.routeID = routeID
        self.originStationID = originStationID
        self.originStationName = originStationName
        self.destinationStationID = destinationStationID
        self.destinationStationName = destinationStationName
        self.lineName = lineName
        self.savedDate = .now
        self.usageCount = 0
    }
}
