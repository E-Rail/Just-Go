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

struct SavedTripAccessibilityFilter: Codable, Equatable {
    var requiresWheelchairAccess: Bool
    var requiresElevator: Bool
    var avoidStairs: Bool

    init(filter: AccessibilityFilter) {
        requiresWheelchairAccess = filter.requiresWheelchairAccess
        requiresElevator = filter.requiresElevator
        avoidStairs = filter.avoidStairs
    }
}

struct TripRecord: Identifiable, Codable, Equatable {
    let id: String
    let savedTripID: String?
    let originName: String
    let destinationName: String
    let cityID: String
    let routeSummary: String
    let plannedDuration: TimeInterval
    let walkingDistance: Double
    let transferCount: Int
    let strategy: RouteStrategy
    let accessibilityFilter: SavedTripAccessibilityFilter
    let warningMessages: [String]
    let createdAt: Date
    var completedAt: Date?
    var note: String?

    var isCompleted: Bool {
        completedAt != nil
    }
}
