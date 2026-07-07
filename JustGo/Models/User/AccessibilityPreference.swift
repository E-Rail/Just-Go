import Foundation

struct AccessibilityPreference: Codable {
    var primaryCategory: DisabilityCategory

    // Mobility
    var requiresWheelchairAccess: Bool
    var prefersElevator: Bool
    var maxWalkingDistance: Double
    var avoidStairs: Bool

    // Vision. VoiceOver / high contrast / large text are SYSTEM features an app can't
    // toggle — the settings sheet points to the right iOS Settings paths instead of
    // carrying dead switches for them.
    var audioNavigation: Bool

    // Hearing. LED flash-for-alerts is likewise system-level (covers our trip-reminder
    // notifications); only the in-app behaviors keep preference fields.
    var visualAnnouncements: Bool
    var vibrationAlerts: Bool

    // Cognitive
    var simplifiedUI: Bool
    var stepByStepGuidance: Bool

    static var `default`: AccessibilityPreference {
        AccessibilityPreference(
            primaryCategory: .none,
            requiresWheelchairAccess: false,
            prefersElevator: false,
            maxWalkingDistance: 500,
            avoidStairs: false,
            audioNavigation: false,
            visualAnnouncements: false,
            vibrationAlerts: false,
            simplifiedUI: false,
            stepByStepGuidance: false
        )
    }

}

struct RouteAffectingAccessibilitySignature: Equatable {
    let requiresWheelchairAccess: Bool
    let prefersElevator: Bool
    let avoidStairs: Bool
    let maxWalkingDistance: Double

    var mobilityDefaults: MobilityAccessibilityDefaults {
        MobilityAccessibilityDefaults(
            requiresWheelchairAccess: requiresWheelchairAccess,
            prefersElevator: prefersElevator,
            avoidStairs: avoidStairs
        )
    }
}

struct MobilityAccessibilityDefaults: Equatable {
    let requiresWheelchairAccess: Bool
    let prefersElevator: Bool
    let avoidStairs: Bool
}

extension AccessibilityPreference {
    var routeAffectingSignature: RouteAffectingAccessibilitySignature {
        RouteAffectingAccessibilitySignature(
            requiresWheelchairAccess: requiresWheelchairAccess,
            prefersElevator: prefersElevator,
            avoidStairs: avoidStairs,
            maxWalkingDistance: maxWalkingDistance
        )
    }
}

enum DisabilityCategory: String, Codable, CaseIterable {
    case mobility = "mobility"
    case visualImpairment = "visual_impairment"
    case hearingImpairment = "hearing_impairment"
    case cognitive = "cognitive"
    case multiple = "multiple"
    case none = "none"

    var displayName: String {
        switch self {
        case .mobility: return AppLocalization.localized("Mobility")
        case .visualImpairment: return AppLocalization.localized("Visual Impairment")
        case .hearingImpairment: return AppLocalization.localized("Hearing Impairment")
        case .cognitive: return AppLocalization.localized("Cognitive")
        case .multiple: return AppLocalization.localized("Multiple")
        case .none: return AppLocalization.localized("None")
        }
    }

    var icon: String {
        switch self {
        case .mobility: return "figure.roll"
        case .visualImpairment: return "eye.slash"
        case .hearingImpairment: return "ear.badge.waveform"
        case .cognitive: return "brain.head.profile"
        case .multiple: return "accessibility"
        case .none: return "person"
        }
    }
}
