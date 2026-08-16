import SwiftUI
import UIKit

/// Puts the keyboard away when the rider taps anywhere outside the field they were typing in.
///
/// One recogniser on the window rather than a modifier repeated on every screen with a text
/// field — the planner's From/To, the map and station search bars, the city picker and the
/// save-trip sheet all inherit it, and a screen added later cannot forget it.
///
/// **The recogniser is disabled unless a keyboard is actually on screen.** The first version of
/// this was always live, and Profile → Settings stopped opening: a tap on that row no longer
/// reached the button. `cancelsTouchesInView = false` and simultaneous recognition are supposed to
/// make a window recogniser harmless, and mostly they do — but "mostly" is not a property you want
/// on the one object that sees every touch in the app. Keying it to the keyboard's own
/// notifications means that on a screen with no text field it is not in the touch pipeline at all,
/// so it cannot compete for a tap it would have nothing to do with anyway. It is live only in the
/// window between the keyboard appearing and it going away, which is exactly its whole job.
///
/// `shouldReceive` is the second guard, for screens that *do* have a keyboard up: a tap that lands
/// on a control is that control's, and this gesture declines it rather than racing for it.
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

    /// Decline any touch that landed on a control. The keyboard still goes away — the control's
    /// own action runs, and moving focus or leaving the field dismisses it — but this gesture
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
    // Same key the old one-shot welcome card used, so existing users never see the tour
    // uninvited; it stays replayable from Settings → App Tour.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showTour = false

    var body: some View {
        @Bindable var appState = appState
        // Two tabs, because the map is the app. Planning a trip and searching for a place are
        // things you do *to* somewhere on the map, not separate destinations to walk to — a rider
        // looking at a place had to leave it, switch tabs, and type its name back in. Both now
        // live on the map's own navigation stack (see `MapRoute`).
        TabView(selection: $appState.selectedTab) {
            Tab(AppLocalization.localized("Map"), systemImage: "map.fill", value: AppState.Tab.map) {
                MapContainerView()
            }
            Tab(AppLocalization.localized("Profile"), systemImage: "person.fill", value: AppState.Tab.profile) {
                ProfileView()
            }
        }
        // On a phone this is the tab bar it has always been. On an iPad it becomes a sidebar, which
        // is the one line that stops the app rendering as a phone screen stretched to 1024 points.
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
