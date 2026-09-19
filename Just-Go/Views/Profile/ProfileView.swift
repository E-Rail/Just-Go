import SwiftUI

enum AppWebLinks {
    static let privacyPolicy = URL(string: "https://e-rail.github.io/just-go/docs/privacy/")!
    static let termsOfService = URL(string: "https://e-rail.github.io/just-go/docs/terms/")!
}

/// The screens Profile can open, through one `sheet(item:)` rather than a `sheet(isPresented:)`
/// each: stacked presentation modifiers shadow one another, and the shadowed row stops opening.
private enum ProfileDestination: String, Identifiable {
    case accessibility
    case transitData
    case settings

    var id: String { rawValue }
}

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var destination: ProfileDestination?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                stackLayout
            }
        }
        #if DEBUG
        // The sibling of the map's seeds: every screen here is behind a tap, and there is no tap
        // injection.
        .task {
            if let seed = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_PROFILE"] {
                appState.selectedTab = .profile
                destination = ProfileDestination(rawValue: seed)
            }
        }
        #endif
        // Close whatever covers the map when this tab stops being the one on screen: Quick Tags → a
        // station → "Route here" switches to the map, and a sheet left open would sit over the
        // results. Keyed on the tab rather than `pendingRouteInput`, a one-shot channel the map
        // reads and clears in the same update.
        .onChange(of: appState.selectedTab) { _, tab in
            if tab != .profile { destination = nil }
        }
    }

    /// The phone shape: rows that raise a sheet.
    private var stackLayout: some View {
        NavigationStack {
            profileList
                .sheet(item: $destination) { destinationView(for: $0) }
        }
    }

    /// The tablet shape: the same rows as a permanent sidebar, with the selection filling the
    /// window, rather than modals stacked on a large screen.
    private var splitLayout: some View {
        NavigationSplitView {
            profileList
        } detail: {
            if let destination {
                destinationView(for: destination, showsDoneButton: false)
            } else {
                ContentUnavailableView {
                    Label(AppLocalization.localized("Profile"), systemImage: "person.crop.circle")
                } description: {
                    Text(AppLocalization.text(
                        english: "Choose something on the left.",
                        simplified: "请从左侧选择。",
                        traditional: "請從左側選擇。"
                    ))
                }
                .background(Color.appBackground)
            }
        }
    }

    private var profileList: some View {
        List {
            appSection
            aboutSection
        }
        .navigationTitle(AppLocalization.localized("Profile"))
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func destinationView(
        for destination: ProfileDestination,
        showsDoneButton: Bool = true
    ) -> some View {
        switch destination {
        case .accessibility: AccessibilitySettingsView(showsDoneButton: showsDoneButton)
        case .transitData: TransitDataView(showsDoneButton: showsDoneButton)
        case .settings: SettingsView(showsDoneButton: showsDoneButton)
        }
    }

    /// How the app behaves, as one group of rows; any header would restate one of the rows.
    private var appSection: some View {
        Section {
            row(AppLocalization.localized("Settings"), icon: "gearshape.fill") {
                destination = .settings
            }
            row(AppLocalization.localized("Accessibility"), icon: "accessibility") {
                destination = .accessibility
            }
            row(
                AppLocalization.localized("Transit Data"),
                icon: "antenna.radiowaves.left.and.right"
            ) { destination = .transitData }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text(AppLocalization.localized("Version"))
                Spacer()
                // From the bundle, not a literal, so it follows MARKETING_VERSION. The localization
                // validator cannot see this: its literal check requires a letter.
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
            linkRow(AppLocalization.localized("Privacy Policy"), url: AppWebLinks.privacyPolicy)
            linkRow(AppLocalization.localized("Terms of Service"), url: AppWebLinks.termsOfService)
        } header: {
            Text(AppLocalization.localized("About"))
        }
    }

    /// One row shape for every door out of this screen, so the rows cannot drift apart.
    private func row(
        _ title: String,
        icon: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    // Tinted by hand: `.buttonStyle(.plain)` removes the accent from the icon along
                    // with the label.
                    Image(systemName: icon)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A row that leaves the app: a plain-styled `Button`, not a `Link`, which tints its whole
    /// label with the accent and ignores `.foregroundStyle(.primary)`.
    private func linkRow(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
