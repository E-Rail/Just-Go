import Foundation

struct SearchHistory: Identifiable, Codable {
    var searchID: String
    var id: String { searchID }
    var stationID: String
    var stationName: String
    var cityID: String

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
    }

    enum CodingKeys: String, CodingKey {
        case searchID
        case legacyID = "id"
        case stationID
        case stationName
        case cityID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.searchID = try container.decodeIfPresent(String.self, forKey: .searchID)
            ?? container.decodeIfPresent(String.self, forKey: .legacyID)
            ?? UUID().uuidString
        self.stationID = try container.decode(String.self, forKey: .stationID)
        self.stationName = try container.decode(String.self, forKey: .stationName)
        self.cityID = try container.decode(String.self, forKey: .cityID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(searchID, forKey: .searchID)
        try container.encode(stationID, forKey: .stationID)
        try container.encode(stationName, forKey: .stationName)
        try container.encode(cityID, forKey: .cityID)
    }
}
