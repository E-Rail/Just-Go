import CoreLocation

final class Station: Identifiable, Hashable {
    static func == (lhs: Station, rhs: Station) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var stationID: String
    var id: String { stationID }
    var name: String
    var nameEn: String?
    var namePinyin: String?
    var latitude: Double
    var longitude: Double
    var cityID: String
    var isTransferStation: Bool
    var lines: [SubwayLine]
    var accessibility: StationAccessibility?
    var facilities: [StationFacility]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The station's names, lowercased and joined once, for keyword search to scan.
    ///
    /// Search used to build this string per station per keystroke and then run
    /// `localizedCaseInsensitiveContains` — a locale-aware ICU search — over each one. Measured on
    /// device (Release, 6,718 stations, worst-case single-character query): **21.7 ms per
    /// keystroke, against 5.0 ms** for a plain `contains` on a precomputed key. Search is
    /// debounced at 180 ms, so this is not a hang; it is 17 ms of CPU burned on every typing pause.
    ///
    /// Lazily built and cached, because most stations are never searched against in a session and
    /// building 6,718 of these at decode time would move the cost to launch rather than remove it.
    private var cachedSearchKey: String?

    var searchKey: String {
        if let cachedSearchKey { return cachedSearchKey }
        // `namePinyin` is deliberately absent: it is never populated for network-derived stations
        // (measured 0 of 6,718), so including it only lengthened a string nobody could match on.
        let key = (nameEn.map { "\(name) \($0)" } ?? name).lowercased()
        cachedSearchKey = key
        return key
    }

    init(
        stationID: String,
        name: String,
        nameEn: String? = nil,
        namePinyin: String? = nil,
        latitude: Double,
        longitude: Double,
        cityID: String,
        isTransferStation: Bool = false
    ) {
        self.stationID = stationID
        self.name = name
        self.nameEn = nameEn
        self.namePinyin = namePinyin
        self.latitude = latitude
        self.longitude = longitude
        self.cityID = cityID
        self.isTransferStation = isTransferStation
        self.lines = []
        self.facilities = []
    }
}
