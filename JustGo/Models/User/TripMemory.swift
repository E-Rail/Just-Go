import Foundation
import CoreLocation

struct TransitPlaceSnapshot: Codable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    let uid: String?
    let cityCode: String?
    let adCode: String?
    let address: String?

    init(
        name: String,
        latitude: Double,
        longitude: Double,
        uid: String? = nil,
        cityCode: String? = nil,
        adCode: String? = nil,
        address: String? = nil
    ) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.uid = uid
        self.cityCode = cityCode
        self.adCode = adCode
        self.address = address
    }

    init(place: TransitPlace) {
        name = place.name
        latitude = place.coordinate.latitude
        longitude = place.coordinate.longitude
        uid = place.uid
        cityCode = place.cityCode
        adCode = place.adCode
        address = place.address
    }

    init(name: String) {
        self.name = name
        latitude = 0
        longitude = 0
        uid = nil
        cityCode = nil
        adCode = nil
        address = nil
    }
}

extension TransitPlaceSnapshot {
    var transitPlace: TransitPlace {
        TransitPlace(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            uid: uid,
            address: address,
            cityCode: cityCode,
            adCode: adCode,
            source: .quickPlace
        )
    }

    var hasUsableRouteCoordinate: Bool {
        uid != nil || abs(latitude) > 0.000001 || abs(longitude) > 0.000001
    }
}

struct SavedTrip: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var origin: TransitPlaceSnapshot
    var destination: TransitPlaceSnapshot
    var cityID: String
    var cityName: String
    var preferredStrategy: RouteStrategy?
    var preferredRoutePreference: RoutePreference?
    var accessibilityFilter: SavedTripAccessibilityFilter
    var createdAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var notes: String?

    var routeTitle: String {
        "\(origin.name) -> \(destination.name)"
    }

    var hasAccessibilityOverrides: Bool {
        accessibilityFilter.requiresWheelchairAccess ||
            accessibilityFilter.requiresElevator ||
            accessibilityFilter.avoidStairs
    }
}

struct SavedTripAccessibilityFilter: Codable, Equatable {
    var requiresWheelchairAccess: Bool
    var requiresElevator: Bool
    var avoidStairs: Bool

    static var none: SavedTripAccessibilityFilter {
        SavedTripAccessibilityFilter(
            requiresWheelchairAccess: false,
            requiresElevator: false,
            avoidStairs: false
        )
    }

    init(filter: AccessibilityFilter) {
        requiresWheelchairAccess = filter.requiresWheelchairAccess
        requiresElevator = filter.requiresElevator
        avoidStairs = filter.avoidStairs
    }

    init(
        requiresWheelchairAccess: Bool,
        requiresElevator: Bool,
        avoidStairs: Bool
    ) {
        self.requiresWheelchairAccess = requiresWheelchairAccess
        self.requiresElevator = requiresElevator
        self.avoidStairs = avoidStairs
    }

    var routeFilter: AccessibilityFilter {
        AccessibilityFilter(
            requiresWheelchairAccess: requiresWheelchairAccess,
            requiresElevator: requiresElevator,
            avoidStairs: avoidStairs
        )
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
