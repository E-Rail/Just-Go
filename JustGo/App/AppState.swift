import SwiftUI

@MainActor
@Observable
final class AppState {
    private let userDefaults: UserDefaults
    private let accessibilityPreferenceKey = "accessibilityPreference"

    var selectedCity: City?
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
