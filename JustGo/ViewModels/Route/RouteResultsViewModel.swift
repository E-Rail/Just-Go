import Foundation

@Observable
final class RouteResultsViewModel {
    var routes: [Route] = []
    var selectedRoute: Route?
    var sortStrategy: RouteSortStrategy = .fastest
    var isLoading = false

    func selectRoute(_ route: Route) {
        selectedRoute = route
    }

    func sortRoutes(by strategy: RouteSortStrategy) {
        sortStrategy = strategy
        switch strategy {
        case .fastest:
            routes.sort { $0.totalDuration < $1.totalDuration }
        case .fewestTransfers:
            routes.sort { $0.transferCount < $1.transferCount }
        case .mostAccessible:
            routes.sort { $0.accessibilityScore > $1.accessibilityScore }
        case .fewestStops:
            routes.sort { $0.totalStops < $1.totalStops }
        }
    }

    var sortedRoutes: [Route] {
        routes
    }
}
