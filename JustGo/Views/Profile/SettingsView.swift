import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
        Section {
            LabeledContent("App Language", value: systemLanguageName)
        } header: {
            Text("Language")
        } footer: {
            Text("JustGo follows the system language configured in iOS Settings.")
        }
    }

    private var systemLanguageName: String {
        Locale.autoupdatingCurrent.localizedString(forIdentifier: Locale.autoupdatingCurrent.identifier)
            ?? Locale.autoupdatingCurrent.identifier
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
