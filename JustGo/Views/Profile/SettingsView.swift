import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAccessibilityBadges") private var showBadges = true
    @AppStorage(AppLocalization.preferenceKey) private var languagePreference = AppLanguagePreference.system.rawValue
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5

    private let leadMinuteOptions = [5, 10, 15, 20, 30]

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                notificationsSection
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

    private var notificationsSection: some View {
        Section {
            Picker(AppLocalization.text(english: "Reminder lead time", simplified: "提前提醒时间", traditional: "提前提醒時間"), selection: $reminderLeadMinutes) {
                ForEach(leadMinuteOptions, id: \.self) { minutes in
                    Text(AppLocalization.text(
                        english: "\(minutes) min before departure",
                        simplified: "出发前\(minutes)分钟",
                        traditional: "出發前\(minutes)分鐘"
                    )).tag(minutes)
                }
            }
        } header: {
            Text(AppLocalization.localized("Notifications"))
        } footer: {
            Text(AppLocalization.text(
                english: "When you set a departure reminder, you'll be notified this many minutes before you need to leave.",
                simplified: "设置出发提醒后，将在出发前提前此时间通知您。",
                traditional: "設定出發提醒後，將在出發前提前此時間通知您。"
            ))
        }
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
            Text(AppLocalization.text(
                english: "Shows elevator, ramp, and wheelchair icons on station pins in the map and on station rows in search results.",
                simplified: "在地图站点标注和搜索结果中显示电梯、坡道和轮椅图标。",
                traditional: "在地圖站點標註和搜尋結果中顯示電梯、坡道和輪椅圖示。"
            ))
        }
    }
}
