import Foundation

final class RoutePlanningService {
    private let aMapService: AMapService

    init(aMapService: AMapService) {
        self.aMapService = aMapService
    }

    func planRoute(
        from originName: String,
        to destinationName: String,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none
    ) async throws -> [Route] {
        async let originPlaces = aMapService.searchPlaces(keyword: originName, city: city, limit: 8)
        async let destinationPlaces = aMapService.searchPlaces(keyword: destinationName, city: city, limit: 8)

        let originPlace = try await originPlaces.first
        let destinationPlace = try await destinationPlaces.first

        guard let origin = originPlace,
              let destination = destinationPlace else {
            throw RoutePlanningError.stationNotFound
        }

        return try await aMapService.planTransitRoute(
            from: origin,
            to: destination,
            city: city,
            accessibilityFilter: accessibilityFilter
        )
    }

    func planRoute(
        from origin: TransitPlace,
        to destination: TransitPlace,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none
    ) async throws -> [Route] {
        try await aMapService.planTransitRoute(
            from: origin,
            to: destination,
            city: city,
            accessibilityFilter: accessibilityFilter
        )
    }

    private func accessibilityScore(for route: Route, preferences: AccessibilityPreference) -> Double {
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
                for note in segment.accessibilityNotes where note.localizedCaseInsensitiveContains("stairs") || note.contains("楼梯") || note.contains("階梯") {
                    score -= 0.2
                }
            }
        }

        for warning in route.warnings {
            switch warning.type {
            case .stairsDetected:
                score -= preferences.avoidStairs ? 0.3 : 0.1
            case .stepFreeAccessUnconfirmed:
                score -= preferences.requiresWheelchairAccess ? 0.3 : 0.15
            case .longWalk:
                score -= 0.1
            default:
                break
            }
        }

        return max(0, min(1, score))
    }

    func sortRoutes(_ routes: [Route], by strategy: RouteSortStrategy, preferences: AccessibilityPreference) -> [Route] {
        switch strategy {
        case .metroFirst:
            return routes.sorted {
                if $0.strategy != $1.strategy {
                    return $0.strategy == .metroFirst
                }
                return $0.totalDuration < $1.totalDuration
            }
        case .fastest:
            return routes.sorted {
                if $0.strategy != $1.strategy {
                    return $0.strategy == .fastest
                }
                return $0.totalDuration < $1.totalDuration
            }
        case .leastWalking:
            return routes.sorted {
                if $0.strategy != $1.strategy {
                    return $0.strategy == .leastWalking
                }
                return $0.walkingDistance < $1.walkingDistance
            }
        case .mostAccessible:
            return routes.sorted { accessibilityScore(for: $0, preferences: preferences) > accessibilityScore(for: $1, preferences: preferences) }
        }
    }
}

enum RoutePlanningError: Error {
    case stationNotFound
    case noRouteFound
    case networkError
    case realTimeDataUnavailable
    case trainScheduleUnavailable
    case amapScheduleLookupNotEnabled
    case amapServiceDiagnostic(AMapResponseDiagnostic)
    case amapNoScheduleForLine(AMapResponseDiagnostic)
    case amapAPIKeyMissing
}

extension RoutePlanningError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .stationNotFound:
            return AppLocalization.localized("Station not found. Try another station name.")
        case .noRouteFound:
            return AppLocalization.localized("No route found between these stations.")
        case .networkError:
            return AppLocalization.localized("Network connection failed. Try again later.")
        case .realTimeDataUnavailable:
            return AppLocalization.localized("Live countdown unavailable")
        case .trainScheduleUnavailable:
            return AppLocalization.localized("Schedule unavailable")
        case .amapScheduleLookupNotEnabled:
            return AppLocalization.localized("AMap schedule lookup is not enabled")
        case .amapServiceDiagnostic(let diagnostic):
            return diagnostic.userMessage
        case .amapNoScheduleForLine(let diagnostic):
            return diagnostic.userMessage
        case .amapAPIKeyMissing:
            return AppLocalization.localized("Add an AMap Web API key to enable public transit routing and place search.")
        }
    }
}

enum RouteSortStrategy: CaseIterable, Identifiable {
    case metroFirst
    case fastest
    case leastWalking
    case mostAccessible

    var id: Self { self }

    var title: String {
        switch self {
        case .metroFirst:
            return "Metro First"
        case .fastest:
            return "Fastest"
        case .leastWalking:
            return "Least Walking"
        case .mostAccessible:
            return "Most Accessible"
        }
    }

    var icon: String {
        switch self {
        case .metroFirst:
            return "tram.fill"
        case .fastest:
            return "clock"
        case .leastWalking:
            return "figure.walk"
        case .mostAccessible:
            return "accessibility"
        }
    }

    init(routeStrategy: RouteStrategy) {
        switch routeStrategy {
        case .metroFirst:
            self = .metroFirst
        case .fastest:
            self = .fastest
        case .leastWalking:
            self = .leastWalking
        }
    }
}
