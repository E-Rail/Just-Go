import Foundation
import CoreLocation

struct TransitPlaceSnapshot: Codable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    let address: String?

    init(place: TransitPlace) {
        name = place.name
        latitude = place.coordinate.latitude
        longitude = place.coordinate.longitude
        address = place.address
    }

    init(name: String) {
        self.name = name
        latitude = 0
        longitude = 0
        address = nil
    }
}

extension TransitPlaceSnapshot {
    var transitPlace: TransitPlace {
        TransitPlace(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            address: address,
            source: .quickPlace
        )
    }
}

struct TripRecord: Identifiable, Codable, Equatable {
    let id: String
    let originName: String
    let destinationName: String
    let cityID: String
    let routeSummary: String
    let plannedDuration: TimeInterval
    let walkingDistance: Double
    let transferCount: Int
    let strategy: RouteStrategy
    // No `accessibilityFilter` and no `savedTripID`. Both were written on every trip and read
    // nowhere in the app. `savedTripID` was passed nil at both call sites, and the filter meant
    // every record persisted the rider's wheelchair, elevator and stairs settings into
    // UserDefaults — a copy of health-adjacent information, kept indefinitely, that bought nothing.
    // Old records decode without them.
    let warningMessages: [String]
    let createdAt: Date
    var completedAt: Date?
    var note: String?
    /// The two ends, as station IDs rather than the names above, because a name cannot be planned
    /// from: two cities share plenty of them and a rider's own history should not be re-matched by
    /// string. Optional because rows saved before this field existed have neither, and those rows
    /// simply do not offer to replan — the same shape `RecentRoute.cityID` already uses.
    var originStationID: String?
    var destinationStationID: String?

    var canReplan: Bool { originStationID != nil && destinationStationID != nil }

    var isCompleted: Bool {
        completedAt != nil
    }
}
