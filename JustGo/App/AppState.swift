import SwiftUI

@Observable
final class AppState {
    var selectedCity: City?
    var accessibilityPreference: AccessibilityPreference = .default

    func initialize(container: DIContainer) async {
        await container.cityService.refreshCities()

        if let location = container.locationService.currentLocation {
            selectedCity = await container.cityService.findNearestCity(to: location)
        }

        selectedCity = selectedCity ?? container.cityService.getCity(byID: "1100")
    }
}
