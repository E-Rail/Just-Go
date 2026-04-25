import SwiftUI
import CoreLocation

@Observable
final class AppState {
    var selectedCity: City?
    var isOnboardingComplete: Bool = false
    var accessibilityPreference: AccessibilityPreference = .default
    var locationManager: LocationService?
    var isLocationAuthorized: Bool = false

    func initialize(container: DIContainer) async {
        locationManager = container.locationService
        await locationManager?.requestPermission()
        isLocationAuthorized = locationManager?.authorizationStatus == .authorizedWhenInUse || locationManager?.authorizationStatus == .authorizedAlways

        if let location = locationManager?.currentLocation {
            selectedCity = await container.cityService.findNearestCity(to: location)
        }
    }
}
