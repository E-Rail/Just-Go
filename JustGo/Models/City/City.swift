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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
    let amapLineIDs: [String]?
    let polyline: [CodableCoordinate]?
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
    let poiIDs: [String]?
    let exits: [StationExitData]?
    let accessibility: AccessibilityData?
    let platformCount: Int?
    let firstTrainTime: String?
    let lastTrainTime: String?
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
