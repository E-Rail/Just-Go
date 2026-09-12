import Foundation
import CoreLocation

/// Main-actor isolated, and it has to be.
///
/// `requestCurrentLocation()` is `async`, so before this annotation it ran on the cooperative
/// pool (SE-0338) and inserted into `pendingLocationContinuations` from there, while
/// `CLLocationManager` — built on the main thread by `DIContainer.configure()` — delivered
/// `didUpdateLocations` on main and called `removeAll()` on the same dictionary. An insert lost
/// against that wipe leaves a `CheckedContinuation` that is never resumed: the caller suspends
/// forever and "locating…" never clears. `MapViewModel` carries the same note for the same fix.
///
/// `@preconcurrency` on the delegate conformance because `CLLocationManagerDelegate` is a plain
/// ObjC protocol with no isolation of its own; the callbacks genuinely do arrive on main.
@MainActor
@Observable
final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pendingLocationContinuations: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var locationRequestGeneration = UUID()
    /// Screens that need a continuous stream (live navigation) hold a session here; a
    /// one-shot request resolving must not stop the hardware while a session is active.
    private var continuousSessionCount = 0

    /// The fix exactly as Core Location reported it. Correct for asking "which city is this" and
    /// for measuring the correction below, and wrong for everything else. See `mapSpaceLocation`.
    var currentLocation: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var locationErrorMessage: String?

    /// How far Core Location's frame sits from the map's, measured rather than assumed.
    ///
    /// Every coordinate this app stores, draws and measures against is GCJ-02, each bundled
    /// network declares `"coordinateSystem": "gcj02"`, and Apple's basemap uses it across Greater
    /// China. A `CLLocation` is the sole input nothing converts, so on a device that reports
    /// WGS-84 the rider's own position is the one coordinate in the whole app in a different
    /// frame. In Beijing that is ~540 m: half the distance between two stops.
    ///
    /// Deliberately not a datum transform. Whether a given iPhone reports WGS-84 or already-shifted
    /// GCJ-02 is not something this code can know, and converting a coordinate that was already
    /// converted would double the error rather than remove it, so the offset is *observed*. The
    /// difference between what MapKit says (always the map's frame) and what Core Location said at
    /// the same instant. A phone that needs no correction measures ~0 and nothing moves.
    private(set) var mapSpaceCorrection: (latitude: CLLocationDegrees, longitude: CLLocationDegrees)?

    /// Where the correction above was measured, and the key it is stored under.
    ///
    /// The correction is *persisted* because it was otherwise unarmed at the moment it matters
    /// most. It can only be measured once MapKit has reported the user dot, and the first trip of a
    /// session is routinely planned before that has happened — so `mapSpaceCoordinate` was the
    /// identity function and the route began at the raw fix, ~540 m from the rider. The rider's own
    /// dot was drawn in the right place the whole time, which is what made it look like a routing
    /// bug rather than a coordinate one.
    ///
    /// Stored with the coordinate it was measured at because the GCJ-02 offset varies across the
    /// country: a correction measured in Beijing must not be applied in Shanghai. Near where it was
    /// taken it is far better than nothing; far away it is discarded and the app waits to measure a
    /// new one, exactly as before.
    private(set) var correctionMeasuredAt: CLLocationCoordinate2D?
    private static let correctionDefaultsKey = "locationMapSpaceCorrection"
    /// How far a stored correction still applies. The obfuscation drifts smoothly over tens of
    /// metres across a metro area, so this is generous on purpose: within it the correction is
    /// right to within a fraction of the error it removes.
    private static let correctionReuseRadius: CLLocationDistance = 50_000

    /// A MapKit report that arrived before Core Location had delivered anything to pair it with.
    ///
    /// On a cold start MapKit's first user-location callback can beat `didUpdateLocations`, and
    /// `observeMapSpaceUserLocation` simply dropped that sample — so the correction stayed unarmed
    /// until the rider moved enough to produce another one. Held briefly instead, and paired with
    /// the next fix.
    private var unpairedMapSpaceSample: (coordinate: CLLocationCoordinate2D, at: Date)?

    /// The fix in the frame the rest of the app lives in. Identical to `currentLocation` until the
    /// map has reported a user location. Unknown is left uncorrected rather than guessed at.
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

        // The cache fast path returns before the cancellation handler below is armed.
        // Without this check an already-cancelled caller (e.g. locate-me superseded by a
        // city switch) would still receive a fix and act on it.
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
                    // Acquire via the continuous stream (more forgiving than a single shot) and
                    // stop it the moment a fix passes the gate. See finishPendingLocationRequests.
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

    /// Called by the map every time MapKit reports the rider's position. Paired against the fix
    /// Core Location delivered for the same moment, the difference *is* the correction.
    func observeMapSpaceUserLocation(_ coordinate: CLLocationCoordinate2D) {
        guard let raw = currentLocation?.coordinate else {
            // Held rather than dropped. See `unpairedMapSpaceSample`.
            unpairedMapSpaceSample = (coordinate, Date())
            return
        }
        pairMapSpaceSample(mapSpace: coordinate, raw: raw)
    }

    /// The measurement itself: MapKit's frame minus Core Location's, for the same instant.
    private func pairMapSpaceSample(mapSpace coordinate: CLLocationCoordinate2D, raw: CLLocationCoordinate2D) {
        // A fix that arrived seconds ago and a MapKit update from now can differ because the rider
        // moved, which is not a frame difference. Anything past a plausible datum shift (the GCJ-02
        // obfuscation peaks around 800 m) is movement or a bad fix, so ignore it. A wrong
        // correction is worse than none.
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

    /// Warm the location cache with a single fix without leaving continuous updates running.
    /// `requestLocation()` delivers one update (via `didUpdateLocations`) then auto-stops, so
    /// opening a screen that pre-warms doesn't drain the battery. No-op (and no permission
    /// prompt) when location access hasn't been granted yet.
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
            // Only start acquiring when a request is actually waiting (or a navigation
            // session is active): granting permission alone shouldn't leave a continuous
            // stream running for the app's lifetime.
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
        // kCLErrorLocationUnknown is transient. Core Location keeps trying and will deliver
        // a fix (or a real error) shortly. Failing every pending request here made a cold GPS
        // start (indoors, first fix after launch) error out instantly; keep waiting instead.
        // The 15s request timeout remains the backstop and stops the stream on expiry.
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
        // Tear down the continuous stream once the request(s) it was acquiring for resolve.
        // Success, failure, or timeout, so GPS doesn't keep running for the app's lifetime.
        // Unless a live-navigation session holds it open.
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
