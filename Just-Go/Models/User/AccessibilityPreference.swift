import Foundation

/// `Equatable` so a view can key work on "the rider changed a preference". `MapContainerView`
/// re-seeds the planner from this, which is the only path by which these settings reach a plan.
struct AccessibilityPreference: Codable, Equatable {
    // Mobility
    var requiresWheelchairAccess: Bool
    var prefersElevator: Bool
    var maxWalkingDistance: Double
    var avoidStairs: Bool

    // Vision. VoiceOver / high contrast / large text are SYSTEM features an app can't
    // toggle: the settings sheet points to the right iOS Settings paths instead of
    // carrying dead switches for them.
    var audioNavigation: Bool

    // Hearing. LED flash-for-alerts is likewise system-level (covers our trip-reminder
    // notifications); only the in-app behaviors keep preference fields.
    var visualAnnouncements: Bool
    var vibrationAlerts: Bool

    // Cognitive
    var stepByStepGuidance: Bool

    static var `default`: AccessibilityPreference {
        AccessibilityPreference(
            requiresWheelchairAccess: false,
            prefersElevator: false,
            maxWalkingDistance: 500,
            avoidStairs: false,
            audioNavigation: false,
            visualAnnouncements: false,
            vibrationAlerts: false,
            stepByStepGuidance: false
        )
    }

}

struct RouteAffectingAccessibilitySignature: Equatable {
    let requiresWheelchairAccess: Bool
    let prefersElevator: Bool
    let avoidStairs: Bool
    let maxWalkingDistance: Double

    /// The mobility trio only: a maxWalkingDistance change alone must not reseed the
    /// planner's per-trip chips.
    func mobilityMatches(_ other: RouteAffectingAccessibilitySignature) -> Bool {
        requiresWheelchairAccess == other.requiresWheelchairAccess &&
            prefersElevator == other.prefersElevator &&
            avoidStairs == other.avoidStairs
    }
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

    var requiresStepFreeEntrance: Bool {
        requiresWheelchairAccess || prefersElevator || avoidStairs
    }
}
