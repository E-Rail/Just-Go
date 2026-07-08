import SwiftUI

@MainActor
@Observable
final class AppState {
    private let userDefaults: UserDefaults
    private let accessibilityPreferenceKey = "accessibilityPreference"

    var selectedCity: City?
    var selectedTab: Int = 1

    struct PendingRouteInput: Equatable {
        let place: TransitPlace
        let role: RouteInputField
        /// The place's home city when the sender knows it (station-originated inputs);
        /// nil for map POIs, which carry no city. The planner switches to this city on
        /// apply so a cross-city favorite doesn't plan against the wrong network.
        let cityID: String?
    }
    var pendingRouteInput: PendingRouteInput?

    var accessibilityPreference: AccessibilityPreference {
        didSet {
            userDefaults.setCodable(accessibilityPreference, forKey: accessibilityPreferenceKey)
        }
    }
    private(set) var hasInitialized = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.accessibilityPreference = userDefaults.codableValue(
            forKey: accessibilityPreferenceKey,
            as: AccessibilityPreference.self,
            default: .default
        )
    }

    func initialize(container: DIContainer) {
        guard !hasInitialized else { return }

        defer {
            hasInitialized = true
        }

        let nearestCity: City?
        if let location = container.locationService.currentLocation {
            nearestCity = container.cityService.findNearestCity(to: location)
        } else {
            nearestCity = nil
        }

        selectedCity = nearestCity
            ?? container.cityService.getCity(byID: "1100")
            ?? container.cityService.getAllCities().first
    }
}
