import Foundation

struct FavoriteStation: Identifiable, Codable {
    let id: String
    let stationID: String
    let name: String
    let nameEn: String?
    let latitude: Double
    let longitude: Double
    let cityID: String
    let cityName: String
    let cityNameEn: String?
    let lineNames: [String]
    let lineNamesEn: [String]?
    let lineIDs: [String]?
    let lineColorsHex: [String]?

    init(station: Station, cityName: String, cityNameEn: String? = nil) {
        self.id = "\(station.cityID)|\(station.stationID)"
        self.stationID = station.stationID
        // Store the raw, stable source names — these are the keys the city-pack enrichment
        // looks up. Display is localized on the fly via `displayName` / `displayLineNames`.
        self.name = station.name
        self.nameEn = station.nameEn
        self.latitude = station.latitude
        self.longitude = station.longitude
        self.cityID = station.cityID
        self.cityName = cityName
        self.cityNameEn = cityNameEn
        self.lineNames = station.lines.map(\.name)
        self.lineNamesEn = station.lines.map { $0.nameEn ?? $0.name }
        self.lineIDs = station.lines.map(\.lineID)
        self.lineColorsHex = station.lines.map(\.colorHex)
    }

    private init(
        id: String,
        stationID: String,
        name: String,
        nameEn: String?,
        latitude: Double,
        longitude: Double,
        cityID: String,
        cityName: String,
        cityNameEn: String?,
        lineNames: [String],
        lineNamesEn: [String]?,
        lineIDs: [String]?,
        lineColorsHex: [String]?
    ) {
        self.id = id
        self.stationID = stationID
        self.name = name
        self.nameEn = nameEn
        self.latitude = latitude
        self.longitude = longitude
        self.cityID = cityID
        self.cityName = cityName
        self.cityNameEn = cityNameEn
        self.lineNames = lineNames
        self.lineNamesEn = lineNamesEn
        self.lineIDs = lineIDs
        self.lineColorsHex = lineColorsHex
    }

    func withCityMetadata(cityName: String, cityNameEn: String?) -> FavoriteStation {
        FavoriteStation(
            id: id,
            stationID: stationID,
            name: name,
            nameEn: nameEn,
            latitude: latitude,
            longitude: longitude,
            cityID: cityID,
            cityName: cityName,
            cityNameEn: cityNameEn,
            lineNames: lineNames,
            lineNamesEn: lineNamesEn,
            lineIDs: lineIDs,
            lineColorsHex: lineColorsHex
        )
    }

    /// Station name localized for display, derived from the stored raw identifiers so the
    /// persisted `name` stays a stable lookup key across locales. Mirrors `Station.localizedName`.
    var displayName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(name) : (nameEn ?? name)
    }

    /// Line names localized for display, mirroring `SubwayLine.localizedName`.
    var displayLineNames: [String] {
        if AppLocalization.isChinese {
            return lineNames.map { AppLocalization.chinese($0) }
        }
        if let lineNamesEn, lineNamesEn.count == lineNames.count {
            return lineNamesEn
        }
        return lineNames
    }

    var displayCityName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(cityName) : (cityNameEn ?? cityName)
    }

    func toStation() -> Station {
        let station = Station(
            stationID: stationID,
            name: name,
            nameEn: nameEn,
            latitude: latitude,
            longitude: longitude,
            cityID: cityID
        )
        let englishLineNames = lineNamesEn?.count == lineNames.count ? lineNamesEn : nil
        station.lines = lineNames.indices.map { index in
            SubwayLine(
                lineID: lineIDs?.indices.contains(index) == true ? (lineIDs?[index] ?? "") : "",
                name: lineNames[index],
                nameEn: englishLineNames?[index],
                colorHex: lineColorsHex?.indices.contains(index) == true ? (lineColorsHex?[index] ?? "#8E8E93") : "#8E8E93",
                cityID: cityID
            )
        }
        return station
    }
}
