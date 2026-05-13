import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .map

    enum Tab: String, CaseIterable {
        case map = "map"
        case route = "route"
        case search = "search"
        case profile = "profile"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            MapContainerView()
                .tabItem {
                    Label(AppLocalization.localized("Map"), systemImage: "map.fill")
                }
                .tag(Tab.map)

            RoutePlannerView()
                .tabItem {
                    Label(AppLocalization.localized("Route"), systemImage: "arrow.triangle.branch")
                }
                .tag(Tab.route)

            StationSearchView()
                .tabItem {
                    Label(AppLocalization.localized("Search"), systemImage: "magnifyingglass")
                }
                .tag(Tab.search)

            ProfileView()
                .tabItem {
                    Label(AppLocalization.localized("Profile"), systemImage: "person.fill")
                }
                .tag(Tab.profile)
        }
        .tint(.blue)
    }
}
