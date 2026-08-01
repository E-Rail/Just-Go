import SwiftUI
import UIKit

/// Puts the keyboard away when the rider taps anywhere outside the field they were typing in.
///
/// One recogniser on the window rather than a modifier repeated on every screen with a text
/// field — the planner's From/To, the map and station search bars, the city picker and the
/// save-trip sheet all inherit it, and a screen added later cannot forget it.
///
/// `cancelsTouchesInView = false` is the part that matters. Without it the window swallows the
/// dismissing tap and every control under it stops responding — the fix would read as the app
/// freezing. The delegate returning true for simultaneous recognition is the same guarantee from
/// the other side: this gesture observes, it never wins a conflict against a button, a map pan or
/// a scroll.
@MainActor
final class KeyboardDismissGesture: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissGesture()
    private var installedWindows = Set<ObjectIdentifier>()

    func install() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where installedWindows.insert(ObjectIdentifier(window)).inserted {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
        }
    }

    @objc private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

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
            KeyboardDismissGesture.shared.install()
        }
        .fullScreenCover(isPresented: $showTour) {
            OnboardingTourView {
                hasSeenWelcome = true
                showTour = false
            }
        }
    }
}
