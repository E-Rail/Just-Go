import Foundation
import CoreLocation

/// Main-actor isolated, as `CLLocationManager` delivers its callbacks on main. A continuation
/// stored off the main actor can lose a race with the delegate's `removeAll()` and never resume,
/// leaving "locating…" forever.
///
/// `@preconcurrency` on the delegate conformance because `CLLocationManagerDelegate` is a plain
/// ObjC protocol with no isolation of its own.
@MainActor
@Observable
final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pendingLocationContinuations: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var locationRequestGeneration = UUID()
    /// Screens that need a continuous stream (live navigation) hold a session here; a
    /// one-shot request resolving must not stop the hardware while a session is active.
    private var continuousSessionCount = 0

    /// The fix as Core Location reported it: right for "which city is this" and for measuring the
    /// correction below, wrong for everything else. See `mapSpaceLocation`.
    var currentLocation: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var locationErrorMessage: String?

    /// How far Core Location's frame sits from the map's, measured rather than assumed.
    ///
    /// Everything this app stores, draws and measures is GCJ-02 (every bundled network declares it,
    /// and so does Apple's basemap in Greater China). A `CLLocation` is the one input nothing
    /// converts, and on a device reporting WGS-84 it is ~540 m off in Beijing.
    ///
    /// Not a datum transform: whether a given iPhone reports WGS-84 or already-shifted GCJ-02
    /// cannot be known here, and converting a converted coordinate doubles the error. The offset is
    /// observed as MapKit's position minus Core Location's at the same instant; a phone that needs
    /// none measures ~0.
    private(set) var mapSpaceCorrection: (latitude: CLLocationDegrees, longitude: CLLocationDegrees)?

    /// Where the correction was measured, stored with it. Persisted because it can only be measured
    /// once MapKit reports the user dot, which the first trip of a session is often planned before.
    /// Kept with its location because the GCJ-02 offset varies across the country: a Beijing
    /// correction must not be applied in Shanghai.
    private(set) var correctionMeasuredAt: CLLocationCoordinate2D?
    private static let correctionDefaultsKey = "locationMapSpaceCorrection"
    /// How far a stored correction still applies. The offset drifts smoothly across a metro area,
    /// so within this it is accurate to a fraction of the error it removes.
    private static let correctionReuseRadius: CLLocationDistance = 50_000

    /// A MapKit report that arrived before Core Location delivered anything to pair it with (on a
    /// cold start MapKit can be first). Held briefly and paired with the next fix.
    private var unpairedMapSpaceSample: (coordinate: CLLocationCoordinate2D, at: Date)?

    /// The fix in the map's frame. Identical to `currentLocation` until a correction is known;
    /// unknown is left uncorrected, not guessed.
    var mapSpaceLocation: CLLocation? {
        guard let currentLocation else { return nil }
        return mapSpaceLocation(from: currentLocation)
    }

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        restoreCorrection()
    }

    func requestCurrentLocation() async throws -> CLLocation {
        locationErrorMessage = nil

        // The cache fast path returns before the cancellation handler below is armed, so an
        // already-cancelled caller would otherwise still get a fix.
        try Task.checkCancellation()

        if let currentLocation,
           isAuthorized,
           currentLocation.horizontalAccuracy >= 0,
           currentLocation.horizontalAccuracy <= 100,
           abs(currentLocation.timestamp.timeIntervalSinceNow) <= 30 {
            return currentLocation
        }

        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldScheduleTimeout = pendingLocationContinuations.isEmpty
                pendingLocationContinuations[requestID] = continuation
                if shouldScheduleTimeout {
                    scheduleLocationRequestTimeout()
                }

                if Task.isCancelled {
                    cancelPendingLocationRequest(requestID)
                    return
                }

                switch authorizationStatus {
                case .notDetermined:
                    manager.requestWhenInUseAuthorization()
                case .authorizedAlways, .authorizedWhenInUse:
                    // Acquire through the continuous stream, which is more forgiving than a single
                    // shot, and stop it once a fix passes the gate. See
                    // `finishPendingLocationRequests`.
                    startUpdatingLocation()
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
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingLocationRequest(requestID)
            }
        }
    }

    /// Called by the map whenever MapKit reports the rider's position. Paired with Core Location's
    /// fix for the same moment, the difference is the correction.
    func observeMapSpaceUserLocation(_ coordinate: CLLocationCoordinate2D) {
        // Only a fix from the same moment. Core Location stops after a one-shot request while
        // MapKit keeps reporting the dot as the rider walks, and pairing with a stale fix would
        // record the walk as the frame offset.
        guard let fix = currentLocation, abs(fix.timestamp.timeIntervalSinceNow) <= 5 else {
            // Held rather than dropped. See `unpairedMapSpaceSample`.
            unpairedMapSpaceSample = (coordinate, Date())
            return
        }
        pairMapSpaceSample(mapSpace: coordinate, raw: fix.coordinate)
    }

    /// The measurement itself: MapKit's frame minus Core Location's, for the same instant.
    private func pairMapSpaceSample(mapSpace coordinate: CLLocationCoordinate2D, raw: CLLocationCoordinate2D) {
        // Two readings seconds apart can differ because the rider moved. Anything past a plausible
        // datum shift (GCJ-02 peaks around 800 m) is movement or a bad fix; a wrong correction is
        // worse than none.
        guard coordinate.distance(to: raw) <= 900 else { return }
        mapSpaceCorrection = (coordinate.latitude - raw.latitude, coordinate.longitude - raw.longitude)
        correctionMeasuredAt = raw
        persistCorrection()
    }

    private func persistCorrection() {
        guard let mapSpaceCorrection, let correctionMeasuredAt else { return }
        UserDefaults.standard.set(
            [
                mapSpaceCorrection.latitude, mapSpaceCorrection.longitude,
                correctionMeasuredAt.latitude, correctionMeasuredAt.longitude
            ],
            forKey: Self.correctionDefaultsKey
        )
    }

    private func restoreCorrection() {
        guard let stored = UserDefaults.standard.array(forKey: Self.correctionDefaultsKey) as? [CLLocationDegrees],
              stored.count == 4 else { return }
        mapSpaceCorrection = (stored[0], stored[1])
        correctionMeasuredAt = CLLocationCoordinate2D(latitude: stored[2], longitude: stored[3])
    }

    /// The correction, but only where it is known to hold. Nil far from where it was measured, so a
    /// correction taken in one city is never silently applied in another.
    private func correction(
        near coordinate: CLLocationCoordinate2D
    ) -> (latitude: CLLocationDegrees, longitude: CLLocationDegrees)? {
        guard let mapSpaceCorrection else { return nil }
        // Measured this session, before anything was stored: no origin recorded, so trust it.
        guard let correctionMeasuredAt else { return mapSpaceCorrection }
        guard coordinate.distance(to: correctionMeasuredAt) <= Self.correctionReuseRadius else { return nil }
        return mapSpaceCorrection
    }

    /// Applies the measured correction to an arbitrary fix. Same instance back when nothing has
    /// been measured yet, so callers never have to branch on it.
    func mapSpaceLocation(from location: CLLocation) -> CLLocation {
        guard let mapSpaceCorrection = correction(near: location.coordinate) else { return location }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: location.coordinate.latitude + mapSpaceCorrection.latitude,
                longitude: location.coordinate.longitude + mapSpaceCorrection.longitude
            ),
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            timestamp: location.timestamp
        )
    }

    func mapSpaceCoordinate(from coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard let mapSpaceCorrection = correction(near: coordinate) else { return coordinate }
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + mapSpaceCorrection.latitude,
            longitude: coordinate.longitude + mapSpaceCorrection.longitude
        )
    }

    func startUpdatingLocation() {
        guard isAuthorized else { return }

        locationErrorMessage = nil
        manager.startUpdatingLocation()
    }

    /// Keep the location stream running until the matching `endContinuousUpdates()`.
    /// Balanced calls, e.g. from a live-navigation screen's appear/disappear.
    func beginContinuousUpdates() {
        continuousSessionCount += 1
        startUpdatingLocation()
    }

    func endContinuousUpdates() {
        continuousSessionCount = max(0, continuousSessionCount - 1)
        if continuousSessionCount == 0, pendingLocationContinuations.isEmpty {
            manager.stopUpdatingLocation()
        }
    }

    /// Warms the location cache with a single fix: `requestLocation()` delivers one update and
    /// stops. No-op, with no permission prompt, when access has not been granted.
    func prewarmLocation() {
        guard isAuthorized else { return }

        locationErrorMessage = nil
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.max(by: { $0.timestamp < $1.timestamp }) else { return }
        currentLocation = location
        locationErrorMessage = nil
        // A MapKit report that had nothing to pair with when it arrived. Only while it is fresh:
        // pairing an old map sample with a new fix measures how far the rider walked, not how far
        // the two frames sit apart.
        if let pending = unpairedMapSpaceSample {
            unpairedMapSpaceSample = nil
            if abs(pending.at.timeIntervalSinceNow) <= 5 {
                pairMapSpaceSample(mapSpace: pending.coordinate, raw: location.coordinate)
            }
        }
        if location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= 100,
           abs(location.timestamp.timeIntervalSinceNow) <= 30 {
            finishPendingLocationRequests(with: .success(location))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            // Start acquiring only when a request is waiting or a navigation session is active:
            // granting permission alone must not leave a stream running.
            if !pendingLocationContinuations.isEmpty || continuousSessionCount > 0 {
                startUpdatingLocation()
            }
        } else {
            manager.stopUpdatingLocation()
            currentLocation = nil
            if authorizationStatus == .denied || authorizationStatus == .restricted {
                let error = LocationServiceError.permissionDenied
                locationErrorMessage = error.localizedDescription
                finishPendingLocationRequests(with: .failure(error))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `kCLErrorLocationUnknown` is transient: Core Location keeps trying and delivers a fix or
        // a real error shortly, so a cold start indoors keeps waiting. The 15 s request timeout is
        // the backstop.
        if (error as? CLError)?.code == .locationUnknown { return }
        locationErrorMessage = error.localizedDescription
        finishPendingLocationRequests(with: .failure(error))

        if (error as? CLError)?.code == .denied {
            authorizationStatus = manager.authorizationStatus
            manager.stopUpdatingLocation()
            currentLocation = nil
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    private func finishPendingLocationRequests(with result: Result<CLLocation, Error>) {
        // Stop the stream once the requests it was acquiring for resolve, however they resolved,
        // unless a navigation session holds it.
        if continuousSessionCount == 0 {
            manager.stopUpdatingLocation()
        }

        let continuations = Array(pendingLocationContinuations.values)
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

    private func cancelPendingLocationRequest(_ requestID: UUID) {
        guard let continuation = pendingLocationContinuations.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: CancellationError())
        if pendingLocationContinuations.isEmpty, continuousSessionCount == 0 {
            manager.stopUpdatingLocation()
        }
    }

    private func scheduleLocationRequestTimeout() {
        let generation = UUID()
        locationRequestGeneration = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
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
