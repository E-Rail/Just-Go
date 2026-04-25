import Foundation
import CoreLocation

final class RoutePlanningService {
    private let aMapService: AMapServiceProtocol
    private let offlineEngine: OfflineRouteEngine
    private let offlineDataManager: OfflineDataManager

    init(
        aMapService: AMapServiceProtocol,
        offlineEngine: OfflineRouteEngine,
        offlineDataManager: OfflineDataManager
    ) {
        self.aMapService = aMapService
        self.offlineEngine = offlineEngine
        self.offlineDataManager = offlineDataManager
    }

    func planRoute(
        from origin: Station,
        to destination: Station,
        accessibilityFilter: AccessibilityFilter = .none
    ) async throws -> [Route] {
        let cityID = origin.cityID

        // Use offline engine if pack is downloaded
        if offlineDataManager.isAvailable(cityID: cityID) {
            let offlineRoutes = offlineEngine.findRoute(
                from: origin,
                to: destination,
                filter: accessibilityFilter
            )
            if !offlineRoutes.isEmpty {
                return offlineRoutes
            }
        }

        // Fall back to online
        return try await aMapService.planTransitRoute(
            from: origin.coordinate,
            to: destination.coordinate,
            city: cityID,
            accessibilityFilter: accessibilityFilter
        )
    }

    func planRoute(
        from originName: String,
        to destinationName: String,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none
    ) async throws -> [Route] {
        let origins = try await aMapService.searchStations(keyword: originName, city: city)
        let destinations = try await aMapService.searchStations(keyword: destinationName, city: city)

        guard let origin = origins.first, let destination = destinations.first else {
            throw RoutePlanningError.stationNotFound
        }

        return try await planRoute(from: origin, to: destination, accessibilityFilter: accessibilityFilter)
    }

    func getAccessibilityScore(for route: Route, preferences: AccessibilityPreference) -> Double {
        var score: Double = 1.0

        if preferences.requiresWheelchairAccess {
            if !route.isFullyAccessible {
                score -= 0.5
            }
            for warning in route.warnings where warning.type == .elevatorOutage {
                score -= 0.3
            }
        }

        if preferences.avoidStairs {
            for segment in route.segments {
                for note in segment.accessibilityNotes where note.contains("stairs") {
                    score -= 0.2
                }
            }
        }

        return max(0, min(1, score))
    }

    func sortRoutes(_ routes: [Route], by strategy: RouteSortStrategy, preferences: AccessibilityPreference) -> [Route] {
        switch strategy {
        case .fastest:
            return routes.sorted { $0.totalDuration < $1.totalDuration }
        case .fewestTransfers:
            return routes.sorted { $0.transferCount < $1.transferCount }
        case .mostAccessible:
            return routes.sorted { getAccessibilityScore(for: $0, preferences: preferences) > getAccessibilityScore(for: $1, preferences: preferences) }
        case .fewestStops:
            return routes.sorted { $0.totalStops < $1.totalStops }
        }
    }
}

enum RoutePlanningError: Error {
    case stationNotFound
    case noRouteFound
    case networkError
    case offlineDataNotAvailable
}

extension RoutePlanningError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .stationNotFound:
            return "Station not found. Try another station name."
        case .noRouteFound:
            return "No route found between these stations."
        case .networkError:
            return "Network connection failed. Try again later."
        case .offlineDataNotAvailable:
            return "Offline data is not available for this city."
        }
    }
}

enum RouteSortStrategy {
    case fastest
    case fewestTransfers
    case mostAccessible
    case fewestStops
}
