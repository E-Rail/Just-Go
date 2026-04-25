import SwiftUI

enum AppRoute: Hashable {
    case map
    case route
    case search
    case profile
    case station(id: String)
    case routeDetail(id: UUID)
    case routeNavigation(id: UUID)
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
