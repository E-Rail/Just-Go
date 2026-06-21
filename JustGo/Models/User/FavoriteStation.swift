import Foundation

struct FavoriteStation: Identifiable, Codable {
    let id: String
    let stationID: String
    let name: String
    let latitude: Double
    let longitude: Double
    let cityID: String
    let cityName: String
    let lineNames: [String]

    init(station: Station, cityName: String) {
        self.id = "\(station.cityID)|\(station.stationID)"
        self.stationID = station.stationID
        self.name = station.name
        self.latitude = station.latitude
        self.longitude = station.longitude
        self.cityID = station.cityID
        self.cityName = cityName
        self.lineNames = station.lines.map(\.name)
    }

    func toStation() -> Station {
        let station = Station(
            stationID: stationID,
            name: name,
            latitude: latitude,
            longitude: longitude,
            cityID: cityID
        )
        station.lines = lineNames.map { lineName in
            SubwayLine(lineID: "", name: lineName, colorHex: "#8E8E93", cityID: cityID)
        }
        return station
    }
}
