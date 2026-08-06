import Foundation

struct SearchHistory: Identifiable, Codable {
    var searchID: String
    var id: String { searchID }
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

    enum CodingKeys: String, CodingKey {
        case searchID
        case legacyID = "id"
        case stationID
        case stationName
        case cityID
        case searchDate
        case searchCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.searchID = try container.decodeIfPresent(String.self, forKey: .searchID)
            ?? container.decodeIfPresent(String.self, forKey: .legacyID)
            ?? UUID().uuidString
        self.stationID = try container.decode(String.self, forKey: .stationID)
        self.stationName = try container.decode(String.self, forKey: .stationName)
        self.cityID = try container.decode(String.self, forKey: .cityID)
        self.searchDate = try container.decodeIfPresent(Date.self, forKey: .searchDate) ?? .now
        self.searchCount = try container.decodeIfPresent(Int.self, forKey: .searchCount) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(searchID, forKey: .searchID)
        try container.encode(stationID, forKey: .stationID)
        try container.encode(stationName, forKey: .stationName)
        try container.encode(cityID, forKey: .cityID)
        try container.encode(searchDate, forKey: .searchDate)
        try container.encode(searchCount, forKey: .searchCount)
    }
}
