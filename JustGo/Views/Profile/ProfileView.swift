import SwiftUI

struct ProfileView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var showAccessibilitySettings = false
    @State private var showTransitData = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                accessibilitySection
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
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
            Text(AppLocalization.localized("Accessibility"))
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
                    Text(AppLocalization.localized("AMap"))
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
            Text(AppLocalization.localized("Transit lines, stations, and routes are loaded from AMap when available."))
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
