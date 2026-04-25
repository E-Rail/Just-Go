import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(DIContainer.self) private var container
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
                    Label("Map", systemImage: "map.fill")
                }
                .tag(Tab.map)

            RoutePlannerView()
                .tabItem {
                    Label("Route", systemImage: "arrow.triangle.branch")
                }
                .tag(Tab.route)

            StationSearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(Tab.search)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }
                .tag(Tab.profile)
        }
        .tint(.blue)
    }
}
