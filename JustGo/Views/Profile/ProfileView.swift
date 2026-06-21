import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var showAccessibilitySettings = false
    @State private var showTransitData = false
    @State private var showTripMemory = false
    @State private var showReports = false
    @State private var showSettings = false
    @State private var showFavoriteStations = false

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
            .sheet(isPresented: $showAccessibilitySettings) {
                AccessibilitySettingsView()
            }
            .sheet(isPresented: $showTransitData) {
                TransitDataView()
            }
            .sheet(isPresented: $showTripMemory) {
                TripMemoryView()
            }
            .sheet(isPresented: $showReports) {
                AccessibilityReportsView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showFavoriteStations) {
                FavoriteStationsView()
            }
        }
    }

    private var accessibilitySection: some View {
        Section {
            Button(action: { showAccessibilitySettings = true }) {
                HStack {
                    Image(systemName: "accessibility")
                        .foregroundStyle(.blue)
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
                        .foregroundStyle(.blue)
                    Text(appState.accessibilityPreference.primaryCategory.displayName)
                        .font(.subheadline)
                }
            }
        } header: {
            Text(AppLocalization.localized("Universal Travel Support"))
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
        } footer: {
            Text(AppLocalization.localized("Routes use Apple Maps; station facts use downloadable official city packs where available."))
        }
    }

    private var riderTrustSection: some View {
        Section {
            Button(action: { showFavoriteStations = true }) {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(AppLocalization.localized("My Stations"))
                    Spacer()
                    if !tripMemoryService.favoriteStations.isEmpty {
                        Text("\(tripMemoryService.favoriteStations.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: { showTripMemory = true }) {
                HStack {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.blue)
                    Text(AppLocalization.localized("My Trips"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: { showReports = true }) {
                HStack {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text(AppLocalization.localized("My Reports"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(AppLocalization.localized("Rider Trust"))
        } footer: {
            Text(AppLocalization.localized("Saved trips, history, reports, and favorite stations stay on this device."))
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

            Link(destination: URL(string: "https://justgo.app/privacy")!) {
                HStack {
                    Text(AppLocalization.localized("Privacy Policy"))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Link(destination: URL(string: "https://justgo.app/terms")!) {
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
