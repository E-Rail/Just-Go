import SwiftUI

enum AppRoute: Hashable {
    case map
    case route
    case search
    case profile
    case station(Station)
    case routeDetail(Route)
    case routeNavigation(Route)
    case accessibilitySettings
    case offlineData
    case settings
}

@Observable
final class AppRouter {
    var path = NavigationPath()

    func navigate(to route: AppRoute) {
        path.append(route)
    }

    func goBack() {
        if !path.isEmpty {
            path.removeLast()
        }
    }

    func goToRoot() {
        path = NavigationPath()
    }
}
