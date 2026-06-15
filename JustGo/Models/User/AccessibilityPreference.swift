import Foundation

struct AccessibilityPreference: Codable {
    var primaryCategory: DisabilityCategory

    // Mobility
    var requiresWheelchairAccess: Bool
    var prefersElevator: Bool
    var maxWalkingDistance: Double
    var avoidStairs: Bool

    // Vision
    var voiceOverEnabled: Bool
    var highContrastMode: Bool
    var largeText: Bool
    var audioNavigation: Bool

    // Hearing
    var visualAnnouncements: Bool
    var vibrationAlerts: Bool
    var flashAlerts: Bool

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
            voiceOverEnabled: false,
            highContrastMode: false,
            largeText: false,
            audioNavigation: false,
            visualAnnouncements: false,
            vibrationAlerts: false,
            flashAlerts: false,
            simplifiedUI: false,
            stepByStepGuidance: false
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
