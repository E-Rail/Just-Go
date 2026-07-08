import Foundation

/// User-assigned place tag on a favorite station. Assigned only in Personal → My Stations;
/// the route planner surfaces tagged favorites as one-tap fill chips but offers no set flow.
enum FavoriteStationTag: Codable, Equatable, Hashable {
    case home
    case work
    case custom(String)

    var title: String {
        switch self {
        case .home:
            return AppLocalization.localized("Home")
        case .work:
            return AppLocalization.text(english: "Work", simplified: "公司", traditional: "公司")
        case .custom(let label):
            return label
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "building.2.fill"
        case .custom: return "tag.fill"
        }
    }
}

struct FavoriteStation: Identifiable, Codable {
    let id: String
    let stationID: String
    let name: String
    let nameEn: String?
    let latitude: Double
    let longitude: Double
    let cityID: String
    // var: repairable via withCityMetadata — rows favorited from another city's context
    // were historically stamped with the selected city's name.
    var cityName: String
    var cityNameEn: String?
    let lineNames: [String]
    let lineNamesEn: [String]?
    let lineIDs: [String]?
    let lineColorsHex: [String]?
    // Optional so favorites persisted before tags existed decode as untagged.
    var tag: FavoriteStationTag?

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
        self.tag = nil
    }

    func withCityMetadata(cityName: String, cityNameEn: String?) -> FavoriteStation {
        var repaired = self
        repaired.cityName = cityName
        repaired.cityNameEn = cityNameEn
        return repaired
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
