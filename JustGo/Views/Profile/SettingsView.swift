import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAccessibilityBadges") private var showBadges = true

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                dataSection
                accessibilitySection
            }
            .navigationTitle(AppLocalization.localized("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
    }

    private var languageSection: some View {
        Section {
            LabeledContent(AppLocalization.localized("App Language"), value: systemLanguageName)
        } header: {
            Text(AppLocalization.localized("Language"))
        } footer: {
            Text(AppLocalization.localized("JustGo follows the system language configured in iOS Settings."))
        }
    }

    private var systemLanguageName: String {
        Locale.autoupdatingCurrent.localizedString(forIdentifier: Locale.autoupdatingCurrent.identifier)
            ?? Locale.autoupdatingCurrent.identifier
    }

    private var dataSection: some View {
        Section {
            LabeledContent(AppLocalization.localized("Transit Provider"), value: AppLocalization.localized("AMap"))
        } header: {
            Text(AppLocalization.localized("Transit Data"))
        } footer: {
            Text(AppLocalization.localized("Public transit plans, metro lines, and station search use AMap live data."))
        }
    }

    private var accessibilitySection: some View {
        Section {
            Toggle(AppLocalization.localized("Show Accessibility Badges"), isOn: $showBadges)
        } header: {
            Text(AppLocalization.localized("Accessibility"))
        } footer: {
            Text(AppLocalization.localized("Show accessibility indicators on station annotations and lists"))
        }
    }
}
