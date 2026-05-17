import SwiftUI

@MainActor
@Observable
final class AppState {
    var selectedCity: City?
    var accessibilityPreference: AccessibilityPreference = .default
    private(set) var isInitializing = false
    private(set) var hasInitialized = false

    func initialize(container: DIContainer) async {
        guard !isInitializing, !hasInitialized else { return }

        isInitializing = true
        defer {
            isInitializing = false
            hasInitialized = true
        }

        await container.cityService.refreshCities()

        let nearestCity: City?
        if let location = container.locationService.currentLocation {
            nearestCity = await container.cityService.findNearestCity(to: location)
        } else {
            nearestCity = nil
        }

        selectedCity = nearestCity ?? container.cityService.getCity(byID: "1100") ?? container.cityService.getAllCities().first
    }
}
