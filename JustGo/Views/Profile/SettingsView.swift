import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAccessibilityBadges") private var showBadges = true
    @AppStorage(AppLocalization.preferenceKey) private var languagePreference = AppLanguagePreference.system.rawValue
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue
    @State private var showTour = false

    private let leadMinuteOptions = [5, 10, 15, 20, 30]

    var body: some View {
        NavigationStack {
            Form {
                themeSection
                languageSection
                notificationsSection
                dataSection
                accessibilitySection
                helpSection
            }
            .navigationTitle(AppLocalization.localized("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showTour) {
                OnboardingTourView { showTour = false }
            }
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            Button {
                showTour = true
            } label: {
                Label(
                    AppLocalization.text(english: "App Tour", simplified: "界面导览", traditional: "介面導覽"),
                    systemImage: "sparkles.tv"
                )
            }
        } header: {
            Text(AppLocalization.text(english: "Help", simplified: "帮助", traditional: "幫助"))
        } footer: {
            Text(AppLocalization.text(
                english: "Replay the walkthrough shown on first launch.",
                simplified: "重看首次启动时的功能导览。",
                traditional: "重看首次啟動時的功能導覽。"
            ))
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(AppTheme.allCases) { theme in
                        themeCircle(for: theme)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        } header: {
            Text(AppLocalization.text(english: "App Theme", simplified: "主题颜色", traditional: "主題顏色"))
        } footer: {
            Text(AppLocalization.text(english: "Theme color applies to buttons, icons, and highlights throughout the app.", simplified: "主题颜色将应用于整个应用的按钮、图标和高亮元素。", traditional: "主題顏色將應用於整個應用程式的按鈕、圖示和高亮元素。"))
        }
    }

    @ViewBuilder
    private func themeCircle(for theme: AppTheme) -> some View {
        let isSelected = selectedThemeHex == theme.rawValue
        Button {
            selectedThemeHex = theme.rawValue
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 44, height: 44)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(
                    Circle()
                        .stroke(isSelected ? theme.accent : Color.clear, lineWidth: 2.5)
                        .padding(-3)
                )
                Text(theme.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Language

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

    // MARK: - Notifications

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

    // MARK: - Data

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

    // MARK: - Accessibility

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
