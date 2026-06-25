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

    var dataCapabilities: CityDataCapabilities {
        CityDataCapabilities.forCity(id)
    }
}

struct CityDataCapabilities: Equatable {
    let accessibility: CityDataCapabilityStatus
    let stationEssentials: CityDataCapabilityStatus
    let stationMap: CityDataCapabilityStatus

    static func forCity(_ cityID: String) -> CityDataCapabilities {
        manifestCapabilities[cityID] ?? CityDataCapabilities(
            accessibility: .pending, stationEssentials: .pending, stationMap: .pending
        )
    }

    private static let manifestCapabilities: [String: CityDataCapabilities] = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: manifest.cities.map { city in
            (city.cityID, CityDataCapabilities(
                accessibility: CityDataCapabilityStatus(manifestValue: city.capabilities.accessibility),
                stationEssentials: CityDataCapabilityStatus(manifestValue: city.capabilities.schedules),
                stationMap: CityDataCapabilityStatus(manifestValue: city.capabilities.stationMaps)
            ))
        })
    }()
}

enum CityDataCapabilityStatus: String, Codable {
    case available
    case partial
    case pending

    var iconName: String {
        switch self {
        case .available:
            return "checkmark.circle.fill"
        case .partial:
            return "circle.lefthalf.filled"
        case .pending:
            return "clock"
        }
    }

    fileprivate init(manifestValue: String) {
        switch manifestValue {
        case "official_static": self = .available
        case "partial_static": self = .partial
        default: self = .pending
        }
    }
}

private struct PackManifest: Decodable {
    let cities: [PackManifestCity]
}

private struct PackManifestCity: Decodable {
    let cityID: String
    let capabilities: PackCapabilities
}

private struct PackCapabilities: Decodable {
    let accessibility: String
    let schedules: String
    let stationMaps: String
}

struct AccessibilityData: Codable {
    let source: String?
    let hasElevator: Bool?
    let hasEscalator: Bool?
    let hasWheelchairRamp: Bool?
    let hasAccessibleRestroom: Bool?
    let isFullyAccessible: Bool?
    let elevatorLocations: [String]?
    let accessibleEntrances: [String]?
    let facilityNotes: [String]?
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

    init(
        source: String? = nil,
        hasElevator: Bool? = nil,
        hasEscalator: Bool? = nil,
        hasWheelchairRamp: Bool? = nil,
        hasAccessibleRestroom: Bool? = nil,
        isFullyAccessible: Bool? = nil,
        elevatorLocations: [String]? = nil,
        accessibleEntrances: [String]? = nil,
        facilityNotes: [String]? = nil,
        wheelchairBoardingAssistance: Bool? = nil,
        hasTactilePath: Bool? = nil,
        hasBrailleSigns: Bool? = nil,
        hasAudioAnnouncement: Bool? = nil,
        tactilePathCoverage: Double? = nil,
        hasVisualAnnouncement: Bool? = nil,
        hasHearingLoop: Bool? = nil,
        hasSignLanguageDisplay: Bool? = nil,
        hasSimplifiedSignage: Bool? = nil,
        hasColorCoding: Bool? = nil,
        hasPictograms: Bool? = nil
    ) {
        self.source = source
        self.hasElevator = hasElevator
        self.hasEscalator = hasEscalator
        self.hasWheelchairRamp = hasWheelchairRamp
        self.hasAccessibleRestroom = hasAccessibleRestroom
        self.isFullyAccessible = isFullyAccessible
        self.elevatorLocations = elevatorLocations
        self.accessibleEntrances = accessibleEntrances
        self.facilityNotes = facilityNotes
        self.wheelchairBoardingAssistance = wheelchairBoardingAssistance
        self.hasTactilePath = hasTactilePath
        self.hasBrailleSigns = hasBrailleSigns
        self.hasAudioAnnouncement = hasAudioAnnouncement
        self.tactilePathCoverage = tactilePathCoverage
        self.hasVisualAnnouncement = hasVisualAnnouncement
        self.hasHearingLoop = hasHearingLoop
        self.hasSignLanguageDisplay = hasSignLanguageDisplay
        self.hasSimplifiedSignage = hasSimplifiedSignage
        self.hasColorCoding = hasColorCoding
        self.hasPictograms = hasPictograms
    }
}
