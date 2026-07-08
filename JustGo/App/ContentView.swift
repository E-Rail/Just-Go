import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue
    // Same key the old one-shot welcome card used, so existing users never see the tour
    // uninvited; it stays replayable from Settings → App Tour.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showTour = false

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.selectedTab) {
            MapContainerView()
                .tabItem {
                    Label(AppLocalization.localized("Map"), systemImage: "map.fill")
                }
                .tag(0)

            RoutePlannerView()
                .tabItem {
                    Label(AppLocalization.localized("Route"), systemImage: "arrow.triangle.branch")
                }
                .tag(1)

            StationSearchView()
                .tabItem {
                    Label(AppLocalization.localized("Search"), systemImage: "magnifyingglass")
                }
                .tag(2)

            ProfileView()
                .tabItem {
                    Label(AppLocalization.localized("Profile"), systemImage: "person.fill")
                }
                .tag(3)
        }
        .tint(Color.adaptive(hex: selectedThemeHex))
        .onAppear {
            if !hasSeenWelcome { showTour = true }
        }
        .fullScreenCover(isPresented: $showTour) {
            OnboardingTourView {
                hasSeenWelcome = true
                showTour = false
            }
        }
    }
}
