import SwiftData

@Model
final class SearchHistory {
    @Attribute(.unique) var searchID: String
    var stationID: String
    var stationName: String
    var cityID: String
    var searchDate: Date
    var searchCount: Int

    init(
        searchID: String = UUID().uuidString,
        stationID: String,
        stationName: String,
        cityID: String
    ) {
        self.searchID = searchID
        self.stationID = stationID
        self.stationName = stationName
        self.cityID = cityID
        self.searchDate = .now
        self.searchCount = 1
    }
}
