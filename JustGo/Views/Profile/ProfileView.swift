import SwiftUI

struct ProfileView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var showAccessibilitySettings = false
    @State private var showOfflineData = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                accessibilitySection
                offlineDataSection
                settingsSection
                aboutSection
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showAccessibilitySettings) {
                AccessibilitySettingsView()
            }
            .sheet(isPresented: $showOfflineData) {
                OfflineDataView()
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
                    Text("Accessibility Settings")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Current Profile")
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
            Text("Accessibility")
        }
    }

    private var offlineDataSection: some View {
        Section {
            Button(action: { showOfflineData = true }) {
                HStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.green)
                    Text("Offline Data")
                    Spacer()
                    Text("\(container.offlineDataManager.installedPacks.count) cities")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Offline Mode")
        } footer: {
            Text("Download city data to use the app without internet")
        }
    }

    private var settingsSection: some View {
        Section {
            Button(action: { showSettings = true }) {
                HStack {
                    Image(systemName: "gear")
                        .foregroundStyle(.gray)
                    Text("Settings")
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
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://justgo.app/privacy")!) {
                HStack {
                    Text("Privacy Policy")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Link(destination: URL(string: "https://justgo.app/terms")!) {
                HStack {
                    Text("Terms of Service")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("About")
        }
    }
}
