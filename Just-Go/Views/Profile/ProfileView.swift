import SwiftUI

enum AppWebLinks {
    static let privacyPolicy = URL(string: "https://e-rail.github.io/just-go/docs/privacy/")!
    static let termsOfService = URL(string: "https://e-rail.github.io/just-go/docs/terms/")!
}

/// The five screens Profile can open. One `sheet(item:)` rather than five `sheet(isPresented:)`
/// on the same node: stacked presentation modifiers are a documented failure class in this app
/// already: `RouteDetailView` carries the same note about `navigationDestination(item:)`. Where
/// one registration shadows another and the shadowed row simply stops opening. Settings was the
/// fourth of the five, and the fourth is exactly the one riders reported as dead.
private enum ProfileDestination: String, Identifiable {
    case accessibility
    case transitData
    case tripMemory
    case settings
    case quickTags

    var id: String { rawValue }
}

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var destination: ProfileDestination?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                stackLayout
            }
        }
        #if DEBUG
        // The sibling of the map's seeds. Profile's screens are all behind a tap, and there is no
        // tap injection here, so without this the split layout could only be reasoned about.
        .task {
            if let seed = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_PROFILE"] {
                appState.selectedTab = .profile
                destination = ProfileDestination(rawValue: seed)
            }
        }
        #endif
        // Quick Tags → a station → "Route here" switches to the Map tab and pushes the entry page
        // *underneath* this still-open sheet, so the rider's tap appeared to do nothing. Whoever
        // records a pending route is leaving Profile; close what is covering the map.
        .onChange(of: appState.pendingRouteInput) { _, pending in
            if pending != nil { destination = nil }
        }
    }

    /// The phone shape, unchanged. Five rows that each raise a sheet.
    private var stackLayout: some View {
        NavigationStack {
            profileList
                .sheet(item: $destination) { destinationView(for: $0) }
        }
    }

    /// The tablet shape: the same five rows as a permanent sidebar, and whatever is selected
    /// filling the rest of the window.
    ///
    /// Five modals on a screen this size was the wrong answer twice over. It buried every one of
    /// these screens under a card, and it made Quick Tags open a sheet on a sheet on a sheet to
    /// reach one station. The rows stay the same rows; only where their contents land changes.
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
            accessibilitySection
            riderTrustSection
            transitDataSection
            settingsSection
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
        case .tripMemory: TripMemoryView(showsDoneButton: showsDoneButton)
        case .settings: SettingsView(showsDoneButton: showsDoneButton)
        case .quickTags: QuickTagsView(showsDoneButton: showsDoneButton)
        }
    }

    private var accessibilitySection: some View {
        Section {
            Button(action: { destination = .accessibility }) {
                HStack {
                    Image(systemName: "accessibility")
                        .foregroundStyle(Color.accentColor)
                    Text(AppLocalization.localized("Accessibility Settings"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text(AppLocalization.localized("Accessibility"))
        }
    }

    private var transitDataSection: some View {
        Section {
            Button(action: { destination = .transitData }) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    Text(AppLocalization.localized("Transit Data"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text(AppLocalization.localized("Data Source"))
        }
    }

    private var riderTrustSection: some View {
        Section {
            Button(action: { destination = .quickTags }) {
                HStack {
                    Image(systemName: "tag.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(AppLocalization.localized("Quick Tags"))
                    Spacer()
                    Text("\(tripMemoryService.stationQuickTags.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { destination = .tripMemory }) {
                HStack {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(AppLocalization.localized("My Trips"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        } header: {
            Text(AppLocalization.localized("My Activity"))
        }
    }

    private var settingsSection: some View {
        Section {
            Button(action: { destination = .settings }) {
                HStack {
                    Image(systemName: "gear")
                        .foregroundStyle(.gray)
                    Text(AppLocalization.localized("Settings"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text(AppLocalization.localized("Version"))
                Spacer()
                // From the bundle, not a literal. This read "1.0.0" while the plist and
                // MARKETING_VERSION both said 1.0, and would have gone on saying it through every
                // release. The validator cannot see it: its literal check requires a letter.
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
            }

            Link(destination: AppWebLinks.privacyPolicy) {
                HStack {
                    Text(AppLocalization.localized("Privacy Policy"))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }

            Link(destination: AppWebLinks.termsOfService) {
                HStack {
                    Text(AppLocalization.localized("Terms of Service"))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text(AppLocalization.localized("About"))
        }
    }
}
