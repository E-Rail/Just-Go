import Foundation
import CoreLocation

enum StationQuickTagKind: Codable, Equatable, Hashable {
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

    var isExclusive: Bool {
        switch self {
        case .home, .work:
            return true
        case .custom:
            return false
        }
    }

    var customLabel: String? {
        if case .custom(let label) = self {
            return label
        }
        return nil
    }
}

enum QuickTagTargetType: String, Codable, Equatable {
    case station
    case place
}

struct StationQuickTag: Identifiable, Codable, Equatable {
    let id: String
    let stationID: String
    let name: String
    let nameEn: String?
    let latitude: Double
    let longitude: Double
    let cityID: String
    // var: repairable via withCityMetadata. Rows favorited from another city's context
    // were historically stamped with the selected city's name.
    var cityName: String
    var cityNameEn: String?
    let lineNames: [String]
    let lineNamesEn: [String]?
    let lineIDs: [String]?
    let lineColorsHex: [String]?
    var kind: StationQuickTagKind
    // Both nil on tags stored before place support existed; `resolvedTargetType` maps
    // that legacy shape back to `.station` so old data keeps decoding untouched.
    let targetType: QuickTagTargetType?
    let address: String?

    var resolvedTargetType: QuickTagTargetType { targetType ?? .station }

    init(station: Station, cityName: String, cityNameEn: String? = nil, kind: StationQuickTagKind) {
        self.id = "\(station.cityID)|\(station.stationID)"
        self.stationID = station.stationID
        // Store the raw, stable source names. These are the keys the city-pack enrichment
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
        self.kind = kind
        self.targetType = .station
        self.address = nil
    }

    init(place: TransitPlace, cityID: String, cityName: String, cityNameEn: String? = nil, kind: StationQuickTagKind) {
        let identifier = Self.placeIdentifier(for: place)
        self.id = "\(cityID)|\(identifier)"
        self.stationID = identifier
        self.name = place.name
        self.nameEn = nil
        self.latitude = place.coordinate.latitude
        self.longitude = place.coordinate.longitude
        self.cityID = cityID
        self.cityName = cityName
        self.cityNameEn = cityNameEn
        self.lineNames = []
        self.lineNamesEn = nil
        self.lineIDs = nil
        self.lineColorsHex = nil
        self.kind = kind
        self.targetType = .place
        self.address = place.address
    }

    /// Stable identity for a tagged map place. Reuses `TransitPlace.id` (name + rounded
    /// coordinates) under a `place|` prefix so it can never collide with a station ID.
    static func placeIdentifier(for place: TransitPlace) -> String {
        "place|\(place.id)"
    }

    func withCityMetadata(cityName: String, cityNameEn: String?) -> StationQuickTag {
        var repaired = self
        repaired.cityName = cityName
        repaired.cityNameEn = cityNameEn
        return repaired
    }

    func withKind(_ kind: StationQuickTagKind) -> StationQuickTag {
        var updated = self
        updated.kind = kind
        return updated
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

    var transitPlace: TransitPlace {
        TransitPlace(
            name: displayName,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            address: address,
            source: .quickPlace
        )
    }
}

/// Home and Work are single-slot (`isExclusive`). Saving a new one silently takes over the
/// slot, the way "set as Home" behaves elsewhere on iOS. Custom tags are unlimited.
enum StationQuickTagPolicy {
    static func inserting(
        _ quickTag: StationQuickTag,
        into currentTags: [StationQuickTag]
    ) -> [StationQuickTag] {
        var updated = currentTags.filter { tag in
            tag.id != quickTag.id &&
                !(quickTag.kind.isExclusive && tag.kind == quickTag.kind)
        }
        updated.insert(quickTag, at: 0)
        return normalized(updated)
    }

    static func normalized(_ tags: [StationQuickTag]) -> [StationQuickTag] {
        var seenStationIDs = Set<String>()
        let newestUnique = tags.filter { seenStationIDs.insert($0.id).inserted }
        let home = newestUnique.first { $0.kind == .home }
        let work = newestUnique.first { $0.kind == .work }
        let reservedIDs = Set([home?.id, work?.id].compactMap { $0 })
        let customs = newestUnique.filter { tag in
            guard !reservedIDs.contains(tag.id) else { return false }
            if case .custom = tag.kind {
                return true
            }
            return false
        }
        return [home, work].compactMap { $0 } + customs
    }
}
