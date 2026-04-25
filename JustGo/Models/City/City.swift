import Foundation
import CoreLocation

struct City: Identifiable, Codable {
    let id: String
    let name: String
    let nameEn: String
    let namePinyin: String
    let latitude: Double
    let longitude: Double
    let stationCount: Int
    let lineCount: Int
    let offlinePackSizeMB: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayImage: String {
        "city_\(id)"
    }
}

struct CitySubwaySystem: Codable {
    let cityID: String
    let version: String
    let lastUpdated: Date
    let lines: [SubwayLineData]
    let stations: [StationData]
}

struct SubwayLineData: Codable {
    let lineID: String
    let name: String
    let nameEn: String?
    let colorHex: String
    let stationIDs: [String]
}

struct StationData: Codable {
    let stationID: String
    let name: String
    let nameEn: String?
    let namePinyin: String?
    let latitude: Double
    let longitude: Double
    let isTransferStation: Bool
    let floorCount: Int
    let lineIDs: [String]
    let exits: [StationExitData]?
    let accessibility: AccessibilityData?
}

struct StationExitData: Codable {
    let exitID: String
    let name: String
    let nameEn: String?
    let hasElevator: Bool
    let hasEscalator: Bool
    let hasWheelchairRamp: Bool
    let isAccessible: Bool
    let nearbyLandmarks: [String]?
}

struct AccessibilityData: Codable {
    let hasElevator: Bool?
    let hasEscalator: Bool?
    let hasWheelchairRamp: Bool?
    let isFullyAccessible: Bool?
    let elevatorLocations: [String]?
    let accessibleEntrances: [String]?
    let wheelchairBoardingAssistance: Bool?
    let hasTactilePath: Bool?
    let hasBrailleSigns: Bool?
    let hasAudioAnnouncement: Bool?
    let tactilePathCoverage: Double?
    let hasVisualAnnouncement: Bool?
    let hasHearingLoop: Bool?
    let hasSignLanguageDisplay: Bool?
    let hasSimplifiedSignage: Bool?
    let hasColorCoding: Bool?
    let hasPictograms: Bool?
}
