import Foundation
import CoreLocation

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pendingLocationContinuations: [CheckedContinuation<CLLocation, Error>] = []
    private var locationRequestGeneration = UUID()

    var currentLocation: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var locationErrorMessage: String?
    var isUpdatingLocation = false

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }

    func requestPermission() async {
        locationErrorMessage = nil

        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdatingLocation()
        case .denied, .restricted:
            isUpdatingLocation = false
            break
        @unknown default:
            isUpdatingLocation = false
            break
        }
    }

    func requestCurrentLocation() async throws -> CLLocation {
        locationErrorMessage = nil

        if let currentLocation,
           isAuthorized,
           currentLocation.horizontalAccuracy >= 0,
           currentLocation.horizontalAccuracy <= 100,
           abs(currentLocation.timestamp.timeIntervalSinceNow) <= 30 {
            return currentLocation
        }

        return try await withCheckedThrowingContinuation { continuation in
            let shouldScheduleTimeout = pendingLocationContinuations.isEmpty
            pendingLocationContinuations.append(continuation)
            if shouldScheduleTimeout {
                scheduleLocationRequestTimeout()
            }

            switch authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                startUpdatingLocation()
                manager.requestLocation()
            case .denied, .restricted:
                let error = LocationServiceError.permissionDenied
                locationErrorMessage = error.localizedDescription
                finishPendingLocationRequests(with: .failure(error))
            @unknown default:
                let error = LocationServiceError.unavailable
                locationErrorMessage = error.localizedDescription
                finishPendingLocationRequests(with: .failure(error))
            }
        }
    }

    func startUpdatingLocation() {
        guard isAuthorized else {
            isUpdatingLocation = false
            return
        }

        locationErrorMessage = nil
        isUpdatingLocation = true
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.max(by: { $0.timestamp < $1.timestamp }) else { return }
        currentLocation = location
        locationErrorMessage = nil
        if location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= 100,
           abs(location.timestamp.timeIntervalSinceNow) <= 30 {
            finishPendingLocationRequests(with: .success(location))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            startUpdatingLocation()
            if !pendingLocationContinuations.isEmpty {
                manager.requestLocation()
            }
        } else {
            isUpdatingLocation = false
            manager.stopUpdatingLocation()
            if authorizationStatus == .denied || authorizationStatus == .restricted {
                let error = LocationServiceError.permissionDenied
                locationErrorMessage = error.localizedDescription
                finishPendingLocationRequests(with: .failure(error))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationErrorMessage = error.localizedDescription
        isUpdatingLocation = false
        finishPendingLocationRequests(with: .failure(error))

        if (error as? CLError)?.code == .denied {
            authorizationStatus = manager.authorizationStatus
            manager.stopUpdatingLocation()
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    private func finishPendingLocationRequests(with result: Result<CLLocation, Error>) {
        let continuations = pendingLocationContinuations
        pendingLocationContinuations.removeAll()

        for continuation in continuations {
            switch result {
            case let .success(location):
                continuation.resume(returning: location)
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func scheduleLocationRequestTimeout() {
        let generation = UUID()
        locationRequestGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self,
                  self.locationRequestGeneration == generation,
                  !self.pendingLocationContinuations.isEmpty else {
                return
            }
            let error = LocationServiceError.unavailable
            self.locationErrorMessage = error.localizedDescription
            self.finishPendingLocationRequests(with: .failure(error))
        }
    }
}

enum LocationServiceError: LocalizedError {
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return AppLocalization.localized("Location permission denied")
        case .unavailable:
            return AppLocalization.localized("Current location unavailable")
        }
    }
}
