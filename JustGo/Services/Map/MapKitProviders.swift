import CoreLocation
import MapKit

struct MapKitTimeoutError: Error {}

/// Races `operation` against a deadline so a stalled MapKit call (MKLocalSearch, MKDirections)
/// can't hang a user-facing spinner indefinitely. MapKit calls are known elsewhere in this
/// codebase to ignore Swift task cancellation, so the abandoned call may keep running in the
/// background after this throws — but the caller (and its loading UI) is unblocked either way.
func withMapKitTimeout<T: Sendable>(
    seconds: TimeInterval = 12,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MapKitTimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw MapKitTimeoutError()
        }
        return result
    }
}

protocol PlaceSearchProviding {
    func searchPlaces(keyword: String, region: MKCoordinateRegion?, limit: Int) async throws -> [TransitPlace]
    func reverseGeocode(location: CLLocationCoordinate2D, name: String?) async throws -> TransitPlace
}

/// "Where I am", as somewhere a trip can start from.
///
/// The ladder below has four ways to go wrong — a cached fix that is fresh enough, a live request,
/// a coarser last-known fallback, and a reverse-geocode that may fail on its own — and it used to
/// live inside `RoutePlannerViewModel.useCurrentLocation` because the deleted route-entry page was
/// the only thing that ever asked. Two screens ask now, and a second copy of a four-branch fallback
/// is exactly the drift `CLAUDE.md` warns about.
struct CurrentPlaceResolver {
    let locationService: LocationService
    let placeSearchProvider: PlaceSearchProviding

    /// A fix good enough to route from, already in the map's coordinate frame. Throws rather than
    /// returning nil: "you have not allowed this" and "it never arrived" need different words on
    /// screen, and only the error carries which one happened.
    func coordinate() async throws -> CLLocationCoordinate2D {
        if let recent = locationService.currentLocation,
           recent.horizontalAccuracy >= 0,
           recent.horizontalAccuracy <= 100,
           abs(recent.timestamp.timeIntervalSinceNow) <= 120 {
            // A recent, sufficiently accurate fix (e.g. from pre-warming) is good enough for a
            // route origin — use it instead of waiting on a fresh one that can stall indoors, on
            // weak GPS, or in the simulator. The ≤120 s window is looser than
            // requestCurrentLocation's 30 s so a just-prewarmed fix answers instantly; the
            // accuracy gate is what keeps it safe.
            return locationService.mapSpaceCoordinate(from: recent.coordinate)
        }

        do {
            let fix = try await locationService.requestCurrentLocation()
            return locationService.mapSpaceCoordinate(from: fix.coordinate)
        } catch {
            if let locationError = error as? LocationServiceError, locationError == .permissionDenied {
                throw error
            }
            // Last resort: a last-known fix so the field still fills, but reject an obviously
            // coarse one (accuracy relaxed only to a city-level bound) rather than seed routing
            // with a km-off origin.
            guard let lastKnown = locationService.currentLocation,
                  lastKnown.horizontalAccuracy >= 0,
                  lastKnown.horizontalAccuracy <= 1000 else {
                throw error
            }
            return locationService.mapSpaceCoordinate(from: lastKnown.coordinate)
        }
    }

    /// Names the coordinate. A failed reverse-geocode is not a failed locate — the rider still
    /// gets a start they can route from, just labelled generically.
    func place(at coordinate: CLLocationCoordinate2D) async -> TransitPlace {
        do {
            return try await placeSearchProvider.reverseGeocode(
                location: coordinate,
                name: AppLocalization.localized("Current Location")
            ).withSource(.currentLocation)
        } catch {
            return TransitPlace(
                name: AppLocalization.localized("Current Location"),
                coordinate: coordinate,
                source: .currentLocation
            )
        }
    }

    func place() async throws -> TransitPlace {
        await place(at: try await coordinate())
    }
}

protocol TransitRouteProviding {
    func routes(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter
    ) async throws -> [Route]
}

/// Builds one walking leg. Extracted from `BundledMetroRouteProvider` because enrichment needs it
/// too: the graph walks the rider to the station, then `RoutePlanningService` picks which door they
/// should actually use, and the leg has to be recomputed against that door. Two callers, one
/// implementation — a second copy would drift on exactly the numbers riders read.
protocol WalkingRouteProviding {
    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment?
}

final class MapKitWalkingRouteProvider: WalkingRouteProviding {
    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        let directDistance = from.distance(to: to)
        guard directDistance >= 10 else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .walking
        let mapRoute: MKRoute?
        do {
            mapRoute = try await withMapKitTimeout {
                try await MKDirections(request: request).calculate().routes.first
            }
        } catch {
            AppLog.routing.info("Walking directions unavailable, using straight-line estimate: \(error)")
            mapRoute = nil
        }
        let distance = mapRoute?.distance ?? directDistance
        let duration = mapRoute?.expectedTravelTime ?? distance / 1.25
        let steps = mapRoute?.steps.filter { $0.distance >= 10 || !$0.instructions.isEmpty }.map {
            WalkingStep(
                instruction: AppLocalization.isChinese ? "" : $0.instructions,
                distance: $0.distance,
                duration: max(1, duration * ($0.distance / max(distance, 1))),
                isAccessible: !$0.instructions.localizedCaseInsensitiveContains("stairs"),
                road: nil,
                action: nil,
                assistantAction: nil,
                walkType: nil
            )
        } ?? [WalkingStep(
            instruction: AppLocalization.text(
                english: "Walk from \(fromName) to \(toName)",
                simplified: "从\(fromName)步行至\(toName)",
                traditional: "從\(fromName)步行至\(toName)"
            ),
            distance: distance,
            duration: duration,
            isAccessible: true,
            road: nil,
            action: nil,
            assistantAction: nil,
            walkType: nil
        )]
        return RouteSegment(
            id: UUID(),
            type: .walking,
            lineName: nil,
            lineColorHex: nil,
            fromStationName: fromName,
            toStationName: toName,
            fromStationID: nil,
            toStationID: nil,
            duration: duration,
            distance: distance,
            stops: 0,
            stationStops: [],
            polylineCoordinates: mapRoute?.polyline.routeCoordinates.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) } ?? [],
            walkingDirections: steps,
            accessibilityNotes: mapRoute == nil ? [AppLocalization.localized("Walking distance is estimated")] : []
        )
    }
}

@MainActor
final class MapKitPlaceSearchProvider: PlaceSearchProviding {
    func searchPlaces(keyword: String, region: MKCoordinateRegion?, limit: Int) async throws -> [TransitPlace] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let region {
            request.region = region
        }

        do {
            let response = try await withMapKitTimeout {
                try await MKLocalSearch(request: request).start()
            }
            return response.mapItems.prefix(limit).map {
                TransitPlace(mapItem: $0, source: .mapKit)
            }
        } catch {
            throw RoutePlanningError.placeSearchUnavailable
        }
    }

    func reverseGeocode(location: CLLocationCoordinate2D, name: String?) async throws -> TransitPlace {
        // A fresh CLGeocoder per call: CLGeocoder allows only one in-flight request per
        // instance and cancels a prior request when a new one starts, so a shared instance
        // would make overlapping reverse-geocodes (e.g. quick Current-Location taps across
        // fields) cancel each other. Reverse-geocode is one-shot, not a hot path.
        let placemarks = try await withMapKitTimeout {
            try await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: location.latitude, longitude: location.longitude)
            )
        }
        let placemark = placemarks.first
        return TransitPlace(
            name: name ?? placemark?.name ?? AppLocalization.localized("Current Location"),
            coordinate: location,
            address: [placemark?.locality, placemark?.subLocality, placemark?.thoroughfare]
                .compactMap { $0 }
                .joined(separator: " "),
            source: .currentLocation
        )
    }
}

struct TransitPlace: Identifiable, Equatable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let type: String?
    let address: String?
    let entranceCoordinate: CLLocationCoordinate2D?
    let source: TransitPlaceSource

    init(
        name: String,
        coordinate: CLLocationCoordinate2D,
        type: String? = nil,
        address: String? = nil,
        entranceCoordinate: CLLocationCoordinate2D? = nil,
        source: TransitPlaceSource = .mapKit
    ) {
        self.name = name
        self.coordinate = coordinate
        self.type = type
        self.address = address
        self.entranceCoordinate = entranceCoordinate
        self.source = source
    }

    init(mapItem: MKMapItem, source: TransitPlaceSource = .mapKit) {
        self.init(
            name: mapItem.name ?? AppLocalization.localized("Unknown place"),
            coordinate: mapItem.placemark.coordinate,
            address: mapItem.placemark.title,
            source: source
        )
    }

    var id: String {
        "\(name)-\(String(format: "%.6f", coordinate.latitude))-\(String(format: "%.6f", coordinate.longitude))"
    }

    var routeCoordinate: CLLocationCoordinate2D { entranceCoordinate ?? coordinate }

    func withSource(_ source: TransitPlaceSource) -> TransitPlace {
        TransitPlace(
            name: name,
            coordinate: coordinate,
            type: type,
            address: address,
            entranceCoordinate: entranceCoordinate,
            source: source
        )
    }

    var detailText: String? {
        [type, address]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
    }

    static func == (lhs: TransitPlace, rhs: TransitPlace) -> Bool { lhs.id == rhs.id }
}
