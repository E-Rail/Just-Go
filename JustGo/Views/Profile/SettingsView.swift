import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAccessibilityBadges") private var showBadges = true
    @AppStorage(AppLocalization.preferenceKey) private var languagePreference = AppLanguagePreference.system.rawValue

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
            Picker(AppLocalization.localized("App Language"), selection: $languagePreference) {
                ForEach(AppLanguagePreference.allCases) { preference in
                    Text(preference.localizedName).tag(preference.rawValue)
                }
            }
        } header: {
            Text(AppLocalization.localized("Language"))
        } footer: {
            Text(languageFooter)
        }
    }

    private var languageFooter: String {
        if languagePreference != AppLocalization.launchPreference.rawValue {
            return AppLocalization.localized("Language changes take effect after restarting JustGo.")
        }
        if languagePreference == AppLanguagePreference.system.rawValue {
            return AppLocalization.localized("System Default follows the language configured in iOS Settings.")
        }
        return AppLocalization.localized("JustGo uses the selected language instead of the system language.")
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
