import SwiftUI

enum AppWebLinks {
    static let privacyPolicy = URL(string: "https://e-rail.github.io/justgo/docs/privacy/")!
    static let termsOfService = URL(string: "https://e-rail.github.io/justgo/docs/terms/")!
}

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var showAccessibilitySettings = false
    @State private var showTransitData = false
    @State private var showTripMemory = false
    @State private var showSettings = false
    @State private var showQuickTags = false

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
            .sheet(isPresented: $showAccessibilitySettings) {
                AccessibilitySettingsView()
            }
            .sheet(isPresented: $showTransitData) {
                TransitDataView()
            }
            .sheet(isPresented: $showTripMemory) {
                TripMemoryView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showQuickTags) {
                QuickTagsView()
            }
        }
    }

    private var accessibilitySection: some View {
        Section {
            Button(action: { showAccessibilitySettings = true }) {
                HStack {
                    Image(systemName: "accessibility")
                        .foregroundStyle(Color.accentColor)
                    Text(AppLocalization.localized("Accessibility Settings"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
            Button(action: { showTransitData = true }) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    Text(AppLocalization.localized("Transit Data"))
                    Spacer()
                    Text(AppLocalization.localized("Apple Maps + official packs"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(AppLocalization.localized("Data Source"))
        }
    }

    private var riderTrustSection: some View {
        Section {
            Button(action: { showQuickTags = true }) {
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
            }

            Button(action: { showTripMemory = true }) {
                HStack {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(AppLocalization.localized("My Trips"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        } header: {
            Text(AppLocalization.localized("My Activity"))
        }
    }

    private var settingsSection: some View {
        Section {
            Button(action: { showSettings = true }) {
                HStack {
                    Image(systemName: "gear")
                        .foregroundStyle(.gray)
                    Text(AppLocalization.localized("Settings"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            }

            Link(destination: AppWebLinks.termsOfService) {
                HStack {
                    Text(AppLocalization.localized("Terms of Service"))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(AppLocalization.localized("About"))
        }
    }
}
