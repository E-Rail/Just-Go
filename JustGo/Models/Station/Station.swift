import CoreLocation

final class Station: Identifiable {
    var stationID: String
    var id: String { stationID }
    var name: String
    var nameEn: String?
    var namePinyin: String?
    var latitude: Double
    var longitude: Double
    var cityID: String
    var isTransferStation: Bool
    var floorCount: Int
    var sortOrder: Int
    var poiIDs: [String]
    var lines: [SubwayLine]
    var accessibility: StationAccessibility?
    var exits: [StationExit]
    var facilities: [StationFacility]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(
        stationID: String,
        name: String,
        nameEn: String? = nil,
        namePinyin: String? = nil,
        latitude: Double,
        longitude: Double,
        cityID: String,
        isTransferStation: Bool = false,
        floorCount: Int = 1,
        sortOrder: Int = 0
    ) {
        self.stationID = stationID
        self.name = name
        self.nameEn = nameEn
        self.namePinyin = namePinyin
        self.latitude = latitude
        self.longitude = longitude
        self.cityID = cityID
        self.isTransferStation = isTransferStation
        self.floorCount = floorCount
        self.sortOrder = sortOrder
        self.poiIDs = []
        self.lines = []
        self.exits = []
        self.facilities = []
    }
}
