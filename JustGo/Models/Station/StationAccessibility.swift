import SwiftData

@Model
final class StationAccessibility {
    var stationID: String

    // Mobility
    var hasElevator: Bool
    var hasEscalator: Bool
    var hasWheelchairRamp: Bool
    var isFullyAccessible: Bool
    var elevatorLocations: [String]
    var accessibleEntrances: [String]
    var wheelchairBoardingAssistance: Bool

    // Visual Impairment
    var hasTactilePath: Bool
    var hasBrailleSigns: Bool
    var hasAudioAnnouncement: Bool
    var tactilePathCoverage: Double

    // Hearing Impairment
    var hasVisualAnnouncement: Bool
    var hasHearingLoop: Bool
    var hasSignLanguageDisplay: Bool

    // Cognitive
    var hasSimplifiedSignage: Bool
    var hasColorCoding: Bool
    var hasPictograms: Bool

    // Status
    var lastVerifiedDate: Date?
    var elevatorStatus: String
    var communityRating: Double
    var reportCount: Int

    @Relationship(inverse: \Station.accessibility)
    var station: Station?

    var elevatorStatusEnum: ElevatorStatus {
        ElevatorStatus(rawValue: elevatorStatus) ?? .unknown
    }

    init(
        stationID: String,
        hasElevator: Bool = false,
        hasEscalator: Bool = false,
        hasWheelchairRamp: Bool = false,
        isFullyAccessible: Bool = false,
        elevatorLocations: [String] = [],
        accessibleEntrances: [String] = [],
        wheelchairBoardingAssistance: Bool = false,
        hasTactilePath: Bool = false,
        hasBrailleSigns: Bool = false,
        hasAudioAnnouncement: Bool = false,
        tactilePathCoverage: Double = 0,
        hasVisualAnnouncement: Bool = false,
        hasHearingLoop: Bool = false,
        hasSignLanguageDisplay: Bool = false,
        hasSimplifiedSignage: Bool = false,
        hasColorCoding: Bool = false,
        hasPictograms: Bool = false,
        elevatorStatus: ElevatorStatus = .unknown,
        communityRating: Double = 0,
        reportCount: Int = 0
    ) {
        self.stationID = stationID
        self.hasElevator = hasElevator
        self.hasEscalator = hasEscalator
        self.hasWheelchairRamp = hasWheelchairRamp
        self.isFullyAccessible = isFullyAccessible
        self.elevatorLocations = elevatorLocations
        self.accessibleEntrances = accessibleEntrances
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
        self.elevatorStatus = elevatorStatus.rawValue
        self.communityRating = communityRating
        self.reportCount = reportCount
    }
}

enum ElevatorStatus: String, Codable {
    case operational = "operational"
    case outOfService = "out_of_service"
    case unknown = "unknown"
}
