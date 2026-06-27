import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @AppStorage("showAccessibilityBadges") private var showBadges = true
    @AppStorage(AppLocalization.preferenceKey) private var languagePreference = AppLanguagePreference.system.rawValue
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue

    @State private var quickPlaces: [QuickPlace] = []

    private let leadMinuteOptions = [5, 10, 15, 20, 30]
    private let quickPlacesKey = "quickPlaces"

    var body: some View {
        NavigationStack {
            Form {
                themeSection
                languageSection
                notificationsSection
                quickPlacesSection
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
            .onAppear { loadQuickPlaces() }
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

    // MARK: - Quick Places

    private var quickPlacesSection: some View {
        Section {
            ForEach(QuickPlaceKind.allCases) { kind in
                quickPlaceRow(for: kind)
            }

            if !quickPlaces.isEmpty {
                Button(role: .destructive) {
                    resetAllQuickPlaces()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text(AppLocalization.text(english: "Reset All Quick Places", simplified: "重置所有快捷地点", traditional: "重置所有快捷地點"))
                    }
                }
            }
        } header: {
            Text(AppLocalization.text(english: "Quick Places", simplified: "快捷地点", traditional: "快捷地點"))
        } footer: {
            Text(AppLocalization.text(english: "Quick places let you route to Home, Company, or School with one tap.", simplified: "快捷地点让您一键导航至家、公司或学校。", traditional: "快捷地點讓您一鍵導航至家、公司或學校。"))
        }
    }

    @ViewBuilder
    private func quickPlaceRow(for kind: QuickPlaceKind) -> some View {
        let saved = quickPlaces.first { $0.kind == kind }
        HStack {
            Image(systemName: kind.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.subheadline)
                if let saved {
                    Text(saved.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(AppLocalization.text(english: "Not set", simplified: "未设置", traditional: "未設置"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(saved == nil
                   ? AppLocalization.text(english: "Set", simplified: "设置", traditional: "設置")
                   : AppLocalization.text(english: "Change", simplified: "更改", traditional: "更改")) {
                startQuickPlaceSetup(kind)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            if saved != nil {
                Button {
                    removeQuickPlace(kind)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(.systemGray3))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func startQuickPlaceSetup(_ kind: QuickPlaceKind) {
        appState.pendingQuickPlaceSetup = kind
        appState.selectedTab = 1 // Route planner tab
        dismiss()
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

    // MARK: - Quick Place Helpers

    private func loadQuickPlaces() {
        quickPlaces = UserDefaults.standard.codableValue(forKey: quickPlacesKey, as: [QuickPlace].self, default: [])
    }

    private func removeQuickPlace(_ kind: QuickPlaceKind) {
        quickPlaces.removeAll { $0.kind == kind }
        UserDefaults.standard.setCodable(quickPlaces, forKey: quickPlacesKey)
        NotificationCenter.default.post(name: .quickPlacesDidReset, object: kind)
    }

    private func resetAllQuickPlaces() {
        quickPlaces = []
        UserDefaults.standard.setCodable(quickPlaces, forKey: quickPlacesKey)
        NotificationCenter.default.post(name: .quickPlacesDidReset, object: nil)
    }
}
