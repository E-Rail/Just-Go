import Foundation

enum AccessibilityAvailability: String, Codable {
    case available
    case unavailable
    case unknown

    init(_ value: Bool?) {
        switch value {
        case true?:
            self = .available
        case false?:
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
    var accessibleRestroomAvailability: AccessibilityAvailability
    var fullAccessibilityAvailability: AccessibilityAvailability
    var elevatorLocations: [String]
    var accessibleEntrances: [String]
    var facilityNotes: [String]

    // Visual Impairment
    var tactilePathAvailability: AccessibilityAvailability
    var audioAnnouncementAvailability: AccessibilityAvailability
    var tactilePathCoverage: Double

    // Hearing Impairment
    var visualAnnouncementAvailability: AccessibilityAvailability

    var hasElevator: Bool { elevatorAvailability.isAvailable }
    var hasWheelchairRamp: Bool { wheelchairRampAvailability.isAvailable }
    var isFullyAccessible: Bool { fullAccessibilityAvailability.isAvailable }
    var hasTactilePath: Bool { tactilePathAvailability.isAvailable }

    var hasVerifiedAccessibilityData: Bool {
        let stationSpecificStates = [
            fullAccessibilityAvailability,
            elevatorAvailability,
            escalatorAvailability,
            wheelchairRampAvailability,
            tactilePathAvailability,
            audioAnnouncementAvailability,
            visualAnnouncementAvailability,
            accessibleRestroomAvailability
        ]

        // `accessibleEntrances` is deliberately *not* here. For 484 of the 582 bundled records it
        // holds an OpenStreetMap entrance letter and nothing else — hasElevator null,
        // hasWheelchairRamp null — and counting it made `summary` report "Partial Accessibility —
        // Some accessibility features are verified" on the strength of a door existing. A mapped
        // door is not a verified step-free route, and this is the one section where saying so
        // wrongly has a physical cost. `elevatorLocations` stays: a named lift is a lift.
        return stationSpecificStates.contains { $0 != .unknown } || !elevatorLocations.isEmpty
    }

    /// Whether anything a rider would look for here is still unrecorded.
    ///
    /// The three fields no source populates — escalator (null in all 582 records) and the audio and
    /// visual announcement states, which have no backing field on `OfficialAccessibility` at all —
    /// used to be in this list, so it was true for *every* station that carried any accessibility
    /// data, Hong Kong's fully surveyed ones included. A caveat that is always on carries no
    /// information and teaches riders to ignore the one time it matters.
    var hasUnverifiedCoreAccessibilityData: Bool {
        let stationSpecificStates = [
            elevatorLocations.isEmpty ? elevatorAvailability : .available,
            wheelchairRampAvailability,
            accessibleRestroomAvailability,
            tactilePathAvailability
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
        hasAccessibleRestroom: Bool? = nil,
        isFullyAccessible: Bool? = nil,
        elevatorLocations: [String] = [],
        accessibleEntrances: [String] = [],
        facilityNotes: [String] = [],
        hasTactilePath: Bool? = nil,
        hasAudioAnnouncement: Bool? = nil,
        tactilePathCoverage: Double = 0,
        hasVisualAnnouncement: Bool? = nil
    ) {
        self.stationID = stationID
        self.dataSource = dataSource
        self.elevatorAvailability = AccessibilityAvailability(hasElevator)
        self.escalatorAvailability = AccessibilityAvailability(hasEscalator)
        self.wheelchairRampAvailability = AccessibilityAvailability(hasWheelchairRamp)
        self.accessibleRestroomAvailability = AccessibilityAvailability(hasAccessibleRestroom)
        self.fullAccessibilityAvailability = AccessibilityAvailability(isFullyAccessible)
        self.elevatorLocations = elevatorLocations
        self.accessibleEntrances = accessibleEntrances
        self.facilityNotes = facilityNotes
        self.tactilePathAvailability = AccessibilityAvailability(hasTactilePath)
        self.audioAnnouncementAvailability = AccessibilityAvailability(hasAudioAnnouncement)
        self.tactilePathCoverage = tactilePathCoverage
        self.visualAnnouncementAvailability = AccessibilityAvailability(hasVisualAnnouncement)
    }
}

extension StationAccessibility {
    convenience init(stationID: String, data: AccessibilityData) {
        self.init(
            stationID: stationID,
            dataSource: data.source,
            hasElevator: data.hasElevator,
            hasEscalator: data.hasEscalator,
            hasWheelchairRamp: data.hasWheelchairRamp,
            hasAccessibleRestroom: data.hasAccessibleRestroom,
            isFullyAccessible: data.isFullyAccessible,
            elevatorLocations: data.elevatorLocations ?? [],
            accessibleEntrances: data.accessibleEntrances ?? [],
            facilityNotes: data.facilityNotes ?? [],
            hasTactilePath: data.hasTactilePath,
            hasAudioAnnouncement: data.hasAudioAnnouncement,
            tactilePathCoverage: data.tactilePathCoverage ?? 0,
            hasVisualAnnouncement: data.hasVisualAnnouncement
        )
    }
}
