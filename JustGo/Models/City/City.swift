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
        switch cityID {
        case "1100":
            return CityDataCapabilities(accessibility: .available, stationEssentials: .available, stationMap: .available)
        case "3100", "4401":
            return CityDataCapabilities(accessibility: .available, stationEssentials: .available, stationMap: .pending)
        case "3301":
            return CityDataCapabilities(accessibility: .available, stationEssentials: .partial, stationMap: .pending)
        case "4403", "5101":
            return CityDataCapabilities(accessibility: .pending, stationEssentials: .pending, stationMap: .pending)
        default:
            return CityDataCapabilities(accessibility: .pending, stationEssentials: .pending, stationMap: .pending)
        }
    }
}

enum CityDataCapabilityStatus: String, Codable {
    case available
    case partial
    case pending

    var isAvailable: Bool {
        self == .available || self == .partial
    }

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

    var colorName: String {
        switch self {
        case .available:
            return "green"
        case .partial:
            return "orange"
        case .pending:
            return "gray"
        }
    }
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
