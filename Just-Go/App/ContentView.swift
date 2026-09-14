import SwiftUI
import UIKit

/// Puts the keyboard away when the rider taps outside the field they were typing in. One recogniser
/// on the window, so every screen with a text field inherits it.
///
/// **Enabled only while a keyboard is on screen.** An always-live window recogniser competes for
/// every touch in the app and can swallow a tap on a list row. `shouldReceive` is the second guard:
/// a tap on a control belongs to that control.
@MainActor
final class KeyboardDismissGesture: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissGesture()
    private var recognizers: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    private var observers: [NSObjectProtocol] = []

    func install() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where recognizers[ObjectIdentifier(window)] == nil {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            recognizer.isEnabled = false
            window.addGestureRecognizer(recognizer)
            recognizers[ObjectIdentifier(window)] = recognizer
        }
        observeKeyboardIfNeeded()
    }

    private func observeKeyboardIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // willShow rather than didShow so the recogniser is live for the first tap after the
        // keyboard starts animating in; willHide symmetrically retires it before it is gone.
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { _ in MainActor.assumeIsolated { KeyboardDismissGesture.shared.setEnabled(true) } })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { _ in MainActor.assumeIsolated { KeyboardDismissGesture.shared.setEnabled(false) } })
    }

    private func setEnabled(_ enabled: Bool) {
        for recognizer in recognizers.values {
            recognizer.isEnabled = enabled
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

    /// Decline any touch that landed on a control. The keyboard still goes away. The control's
    /// own action runs, and moving focus or leaving the field dismisses it, but this gesture
    /// never becomes a second claimant on a tap that already has an owner.
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // UIKit calls delegate callbacks on the main thread; the protocol simply predates the
        // annotation that would say so.
        MainActor.assumeIsolated {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue
    // The key the tour has always been gated on; it stays replayable from Settings → App Tour.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showTour = false

    var body: some View {
        @Bindable var appState = appState
        // The map is the app: planning and searching happen on the map's own navigation stack (see
        // `MapRoute`), so a rider looking at a place never has to switch tabs to route to it. Trips
        // is its own tab because it is what the rider owns, not a setting.
        TabView(selection: $appState.selectedTab) {
            Tab(AppLocalization.localized("Map"), systemImage: "map.fill", value: AppState.Tab.map) {
                MapContainerView()
            }
            Tab(
                AppLocalization.text(english: "Trips", simplified: "行程", traditional: "行程"),
                systemImage: "bookmark.fill",
                value: AppState.Tab.trips
            ) {
                TripsView()
            }
            Tab(AppLocalization.localized("Profile"), systemImage: "person.fill", value: AppState.Tab.profile) {
                ProfileView()
            }
        }
        // A tab bar on a phone, a sidebar on an iPad.
        .tabViewStyle(.sidebarAdaptable)
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
