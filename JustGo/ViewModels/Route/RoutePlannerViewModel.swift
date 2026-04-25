import Foundation
import CoreLocation

@Observable
final class RoutePlannerViewModel {
    var originName: String = ""
    var destinationName: String = ""
    var selectedCity: City?
    var routes: [Route] = []
    var isLoading = false
    var errorMessage: String?
    var sortStrategy: RouteSortStrategy = .fastest
    var showAccessibilityFilters = false

    // Accessibility filters
    var requiresWheelchairAccess = false
    var requiresElevator = false
    var avoidStairs = false

    private let routePlanningService: RoutePlanningService
    private let stationSearchService: StationSearchService
    private let cityService: CityService

    init(
        routePlanningService: RoutePlanningService,
        stationSearchService: StationSearchService,
        cityService: CityService
    ) {
        self.routePlanningService = routePlanningService
        self.stationSearchService = stationSearchService
        self.cityService = cityService
    }

    var accessibilityFilter: AccessibilityFilter {
        AccessibilityFilter(
            requiresWheelchairAccess: requiresWheelchairAccess,
            requiresElevator: requiresElevator,
            avoidStairs: avoidStairs,
            minAccessibilityScore: 0
        )
    }

    var canSearch: Bool {
        !originName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !destinationName.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedCity != nil
    }

    func searchRoutes() async {
        guard let city = selectedCity else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            routes = try await routePlanningService.planRoute(
                from: originName,
                to: destinationName,
                city: city.name,
                accessibilityFilter: accessibilityFilter
            )
            sortRoutes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sortRoutes() {
        // This would use the user's accessibility preferences in production
        routes = routePlanningService.sortRoutes(
            routes,
            by: sortStrategy,
            preferences: .default
        )
    }

    func swapOriginDestination() {
        let temp = originName
        originName = destinationName
        destinationName = temp
    }

    func clearRoutes() {
        routes = []
        errorMessage = nil
    }

    func getAccessibilityScore(for route: Route) -> Double {
        routePlanningService.getAccessibilityScore(for: route, preferences: .default)
    }
}
