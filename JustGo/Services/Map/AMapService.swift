import Foundation
import CoreLocation

protocol AMapServiceProtocol {
    func searchStations(keyword: String, city: String) async throws -> [Station]
    func searchStations(near location: CLLocationCoordinate2D, radius: Double) async throws -> [Station]
    func planTransitRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        city: String,
        accessibilityFilter: AccessibilityFilter?
    ) async throws -> [Route]
    func getRealTimeArrivals(lineID: String, stationID: String) async throws -> [RealTimeArrival]
}

struct AccessibilityFilter {
    var requiresWheelchairAccess: Bool
    var requiresElevator: Bool
    var avoidStairs: Bool
    var minAccessibilityScore: Double

    static var none: AccessibilityFilter {
        AccessibilityFilter(
            requiresWheelchairAccess: false,
            requiresElevator: false,
            avoidStairs: false,
            minAccessibilityScore: 0
        )
    }
}

final class AMapService: AMapServiceProtocol {
    // This will be replaced with actual AMap SDK calls when integrated
    // For now, we provide a mock implementation for development

    func searchStations(keyword: String, city: String) async throws -> [Station] {
        // Simulated response
        try await Task.sleep(for: .milliseconds(300))
        return []
    }

    func searchStations(near location: CLLocationCoordinate2D, radius: Double) async throws -> [Station] {
        try await Task.sleep(for: .milliseconds(300))
        return []
    }

    func planTransitRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        city: String,
        accessibilityFilter: AccessibilityFilter?
    ) async throws -> [Route] {
        try await Task.sleep(for: .milliseconds(500))
        return []
    }

    func getRealTimeArrivals(lineID: String, stationID: String) async throws -> [RealTimeArrival] {
        try await Task.sleep(for: .milliseconds(200))
        return []
    }
}

// MARK: - AMap Response Models (for when SDK is integrated)

struct AMapTransitRouteResponse {
    let transits: [AMapTransit]?
    let count: Int
}

struct AMapTransit {
    let duration: TimeInterval
    let segments: [AMapTransitSegment]
    let walkingDistance: Double
}

struct AMapTransitSegment {
    let walking: AMapWalking?
    let bus: AMapBus?
}

struct AMapWalking {
    let distance: Double
    let duration: TimeInterval
    let steps: [AMapWalkingStep]
}

struct AMapWalkingStep {
    let instruction: String
    let road: String
    let distance: Double
    let duration: TimeInterval
}

struct AMapBus {
    let name: String
    let type: String
    let buslines: [AMapBusLine]
}

struct AMapBusLine {
    let name: String
    let departureStop: AMapBusStop
    let arrivalStop: AMapBusStop
    let viaNum: Int
    let duration: TimeInterval
}

struct AMapBusStop {
    let name: String
    let id: String
}
