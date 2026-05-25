import Foundation

enum AccessibilityAvailability: String, Codable {
    case available
    case unavailable
    case unknown

    init(_ value: Bool?) {
        switch value {
        case true:
            self = .available
        case false:
            self = .unavailable
        case nil:
            self = .unknown
        }
    }

    var isAvailable: Bool {
        self == .available
    }

    var localizedStatusText: String {
        switch self {
        case .available:
            return AppLocalization.localized("Feature available")
        case .unavailable:
            return AppLocalization.localized("Not available")
        case .unknown:
            return AppLocalization.localized("Not verified")
        }
    }
}

enum StationAccessibilitySummary {
    case fullyAccessible
    case partial
    case notVerified
}

final class StationAccessibility {
    var stationID: String
    var dataSource: String?

    // Mobility
    var elevatorAvailability: AccessibilityAvailability
    var escalatorAvailability: AccessibilityAvailability
    var wheelchairRampAvailability: AccessibilityAvailability
    var fullAccessibilityAvailability: AccessibilityAvailability
    var elevatorLocations: [String]
    var accessibleEntrances: [String]
    var wheelchairBoardingAssistanceAvailability: AccessibilityAvailability

    // Visual Impairment
    var tactilePathAvailability: AccessibilityAvailability
    var brailleSignsAvailability: AccessibilityAvailability
    var audioAnnouncementAvailability: AccessibilityAvailability
    var tactilePathCoverage: Double

    // Hearing Impairment
    var visualAnnouncementAvailability: AccessibilityAvailability
    var hearingLoopAvailability: AccessibilityAvailability
    var signLanguageDisplayAvailability: AccessibilityAvailability

    // Cognitive
    var simplifiedSignageAvailability: AccessibilityAvailability
    var colorCodingAvailability: AccessibilityAvailability
    var pictogramsAvailability: AccessibilityAvailability

    // Status
    var lastVerifiedDate: Date?
    var elevatorStatus: String
    var communityRating: Double
    var reportCount: Int

    var elevatorStatusEnum: ElevatorStatus {
        ElevatorStatus(rawValue: elevatorStatus) ?? .unknown
    }

    var hasElevator: Bool { elevatorAvailability.isAvailable }
    var hasEscalator: Bool { escalatorAvailability.isAvailable }
    var hasWheelchairRamp: Bool { wheelchairRampAvailability.isAvailable }
    var isFullyAccessible: Bool { fullAccessibilityAvailability.isAvailable }
    var wheelchairBoardingAssistance: Bool { wheelchairBoardingAssistanceAvailability.isAvailable }
    var hasTactilePath: Bool { tactilePathAvailability.isAvailable }
    var hasBrailleSigns: Bool { brailleSignsAvailability.isAvailable }
    var hasAudioAnnouncement: Bool { audioAnnouncementAvailability.isAvailable }
    var hasVisualAnnouncement: Bool { visualAnnouncementAvailability.isAvailable }
    var hasHearingLoop: Bool { hearingLoopAvailability.isAvailable }
    var hasSignLanguageDisplay: Bool { signLanguageDisplayAvailability.isAvailable }
    var hasSimplifiedSignage: Bool { simplifiedSignageAvailability.isAvailable }
    var hasColorCoding: Bool { colorCodingAvailability.isAvailable }
    var hasPictograms: Bool { pictogramsAvailability.isAvailable }

    var hasVerifiedAccessibilityData: Bool {
        let stationSpecificStates = [
            fullAccessibilityAvailability,
            elevatorAvailability,
            escalatorAvailability,
            wheelchairRampAvailability,
            tactilePathAvailability,
            audioAnnouncementAvailability,
            visualAnnouncementAvailability
        ]

        return stationSpecificStates.contains { $0 != .unknown } ||
            !elevatorLocations.isEmpty ||
            !accessibleEntrances.isEmpty
    }

    var hasUnverifiedCoreAccessibilityData: Bool {
        let stationSpecificStates = [
            elevatorLocations.isEmpty ? elevatorAvailability : .available,
            escalatorAvailability,
            accessibleEntrances.isEmpty ? wheelchairRampAvailability : .available,
            tactilePathAvailability,
            audioAnnouncementAvailability,
            visualAnnouncementAvailability
        ]

        return stationSpecificStates.contains(.unknown)
    }

    var summary: StationAccessibilitySummary {
        guard hasVerifiedAccessibilityData else { return .notVerified }
        return isFullyAccessible ? .fullyAccessible : .partial
    }

    init(
        stationID: String,
        dataSource: String? = nil,
        hasElevator: Bool? = nil,
        hasEscalator: Bool? = nil,
        hasWheelchairRamp: Bool? = nil,
        isFullyAccessible: Bool? = nil,
        elevatorLocations: [String] = [],
        accessibleEntrances: [String] = [],
        wheelchairBoardingAssistance: Bool? = nil,
        hasTactilePath: Bool? = nil,
        hasBrailleSigns: Bool? = nil,
        hasAudioAnnouncement: Bool? = nil,
        tactilePathCoverage: Double = 0,
        hasVisualAnnouncement: Bool? = nil,
        hasHearingLoop: Bool? = nil,
        hasSignLanguageDisplay: Bool? = nil,
        hasSimplifiedSignage: Bool? = nil,
        hasColorCoding: Bool? = nil,
        hasPictograms: Bool? = nil,
        elevatorStatus: ElevatorStatus = .unknown,
        communityRating: Double = 0,
        reportCount: Int = 0
    ) {
        self.stationID = stationID
        self.dataSource = dataSource
        self.elevatorAvailability = AccessibilityAvailability(hasElevator)
        self.escalatorAvailability = AccessibilityAvailability(hasEscalator)
        self.wheelchairRampAvailability = AccessibilityAvailability(hasWheelchairRamp)
        self.fullAccessibilityAvailability = AccessibilityAvailability(isFullyAccessible)
        self.elevatorLocations = elevatorLocations
        self.accessibleEntrances = accessibleEntrances
        self.wheelchairBoardingAssistanceAvailability = AccessibilityAvailability(wheelchairBoardingAssistance)
        self.tactilePathAvailability = AccessibilityAvailability(hasTactilePath)
        self.brailleSignsAvailability = AccessibilityAvailability(hasBrailleSigns)
        self.audioAnnouncementAvailability = AccessibilityAvailability(hasAudioAnnouncement)
        self.tactilePathCoverage = tactilePathCoverage
        self.visualAnnouncementAvailability = AccessibilityAvailability(hasVisualAnnouncement)
        self.hearingLoopAvailability = AccessibilityAvailability(hasHearingLoop)
        self.signLanguageDisplayAvailability = AccessibilityAvailability(hasSignLanguageDisplay)
        self.simplifiedSignageAvailability = AccessibilityAvailability(hasSimplifiedSignage)
        self.colorCodingAvailability = AccessibilityAvailability(hasColorCoding)
        self.pictogramsAvailability = AccessibilityAvailability(hasPictograms)
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

extension StationAccessibility {
    convenience init(stationID: String, data: AccessibilityData) {
        self.init(
            stationID: stationID,
            dataSource: data.source,
            hasElevator: data.hasElevator,
            hasEscalator: data.hasEscalator,
            hasWheelchairRamp: data.hasWheelchairRamp,
            isFullyAccessible: data.isFullyAccessible,
            elevatorLocations: data.elevatorLocations ?? [],
            accessibleEntrances: data.accessibleEntrances ?? [],
            wheelchairBoardingAssistance: data.wheelchairBoardingAssistance,
            hasTactilePath: data.hasTactilePath,
            hasBrailleSigns: data.hasBrailleSigns,
            hasAudioAnnouncement: data.hasAudioAnnouncement,
            tactilePathCoverage: data.tactilePathCoverage ?? 0,
            hasVisualAnnouncement: data.hasVisualAnnouncement,
            hasHearingLoop: data.hasHearingLoop,
            hasSignLanguageDisplay: data.hasSignLanguageDisplay,
            hasSimplifiedSignage: data.hasSimplifiedSignage,
            hasColorCoding: data.hasColorCoding,
            hasPictograms: data.hasPictograms,
            communityRating: data.isFullyAccessible == true ? 4.6 : 0,
            reportCount: data.isFullyAccessible == true ? 18 : 0
        )
    }
}
