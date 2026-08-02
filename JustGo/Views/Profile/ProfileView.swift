import SwiftUI

enum AppWebLinks {
    static let privacyPolicy = URL(string: "https://e-rail.github.io/justgo/docs/privacy/")!
    static let termsOfService = URL(string: "https://e-rail.github.io/justgo/docs/terms/")!
}

/// The five screens Profile can open. One `sheet(item:)` rather than five `sheet(isPresented:)`
/// on the same node: stacked presentation modifiers are a documented failure class in this app
/// already — `RouteDetailView` carries the same note about `navigationDestination(item:)` — where
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

    var body: some View {
        NavigationStack {
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
            .sheet(item: $destination) { destination in
                switch destination {
                case .accessibility: AccessibilitySettingsView()
                case .transitData: TransitDataView()
                case .tripMemory: TripMemoryView()
                case .settings: SettingsView()
                case .quickTags: QuickTagsView()
                }
            }
        }
        // Quick Tags → a station → "Route here" switches to the Map tab and pushes the entry page
        // *underneath* this still-open sheet, so the rider's tap appeared to do nothing. Whoever
        // records a pending route is leaving Profile; close what is covering the map.
        .onChange(of: appState.pendingRouteInput) { _, pending in
            if pending != nil { destination = nil }
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

            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Current Profile"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: appState.accessibilityPreference.primaryCategory.icon)
                        .foregroundStyle(Color.accentColor)
                    Text(appState.accessibilityPreference.primaryCategory.displayName)
                        .font(.subheadline)
                }
            }
        } header: {
            Text(AppLocalization.localized("Trip Preferences"))
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
                Text("1.0.0")
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
