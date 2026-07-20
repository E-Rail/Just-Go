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

protocol TransitRouteProviding {
    func routes(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter
    ) async throws -> [Route]
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
