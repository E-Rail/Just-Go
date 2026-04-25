import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("preferredLanguage") private var language = "system"
    @AppStorage("autoDownloadOffline") private var autoDownload = false
    @AppStorage("showAccessibilityBadges") private var showBadges = true

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                offlineSection
                accessibilitySection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var languageSection: some View {
        Section("Language") {
            Picker("Preferred Language", selection: $language) {
                Text("System").tag("system")
                Text("中文").tag("zh")
                Text("English").tag("en")
                Text("中英双语").tag("both")
            }
        }
    }

    private var offlineSection: some View {
        Section {
            Toggle("Auto-download on visit", isOn: $autoDownload)
        } header: {
            Text("Offline Data")
        } footer: {
            Text("Automatically prompt to download city data when you visit a new city")
        }
    }

    private var accessibilitySection: some View {
        Section {
            Toggle("Show Accessibility Badges", isOn: $showBadges)
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Show accessibility indicators on station annotations and lists")
        }
    }
}
