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
        AppLocalization.isTraditionalChinese ? "繁體中文" : "简体中文"
    }

    private var dataSection: some View {
        Section {
            LabeledContent(AppLocalization.localized("Route and Search Provider"), value: AppLocalization.localized("Apple Maps"))
            LabeledContent(AppLocalization.localized("Official Station Details"), value: AppLocalization.localized("City Packs"))
        } header: {
            Text(AppLocalization.localized("Transit Data"))
        } footer: {
            Text(AppLocalization.localized("Route planning and place search use Apple Maps. Station facts use official city packs when available."))
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
