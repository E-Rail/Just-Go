import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @AppStorage("showAccessibilityBadges") private var showBadges = true
    @AppStorage(AppLocalization.preferenceKey) private var languagePreference = AppLanguagePreference.system.rawValue
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5
    @State private var showTour = false
    @State private var showQuickTags = false
    @State private var showClearCacheConfirmation = false
    @State private var didClearCache = false

    private let leadMinuteOptions = [5, 10, 15, 20, 30]

    var body: some View {
        NavigationStack {
            Form {
                themeSection
                languageSection
                notificationsSection
                tagsSection
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
            .sheet(isPresented: $showQuickTags) {
                QuickTagsView()
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
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        Section {
            ThemePickerRow()
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        } header: {
            Text(AppLocalization.text(english: "App Theme", simplified: "主题颜色", traditional: "主題顏色"))
        }
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
            if languagePreference != AppLocalization.launchPreference.rawValue {
                Text(AppLocalization.localized("Language changes take effect after restarting Just-Go."))
            }
        }
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
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        Section {
            Button {
                showQuickTags = true
            } label: {
                HStack {
                    Label(AppLocalization.localized("Quick Tags"), systemImage: "tag.fill")
                    Spacer()
                    Text("\(tripMemoryService.stationQuickTags.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text(AppLocalization.text(english: "Tags", simplified: "标签", traditional: "標籤"))
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            LabeledContent(
                AppLocalization.text(english: "Metro routing", simplified: "地铁规划", traditional: "地鐵規劃"),
                value: AppLocalization.text(english: "Included with the app", simplified: "随应用内置", traditional: "隨應用內建")
            )
            LabeledContent(
                AppLocalization.text(english: "Places and walking", simplified: "地点与步行", traditional: "地點與步行"),
                value: AppLocalization.localized("Apple Maps")
            )
            LabeledContent(AppLocalization.localized("Official Station Details"), value: AppLocalization.localized("City Packs"))
            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                Label(clearCacheTitle, systemImage: "trash")
            }
            .alert(clearCacheTitle, isPresented: $showClearCacheConfirmation) {
                Button(clearCacheTitle, role: .destructive) {
                    Task {
                        await container.clearAllCaches()
                        didClearCache = true
                    }
                }
                Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            } message: {
                Text(AppLocalization.text(
                    english: "Saved official station information and temporary web data will be deleted, and fetched again when needed. Your tags, trips, records and settings are not affected.",
                    simplified: "已保存的官方车站信息和临时网页数据将被删除，需要时会重新获取。您的标签、行程、记录和设置不受影响。",
                    traditional: "已儲存的官方車站資訊和暫存網頁資料將被刪除，需要時會重新取得。您的標籤、行程、記錄和設定不受影響。"
                ))
            }
        } header: {
            Text(AppLocalization.localized("Transit Data"))
        } footer: {
            if didClearCache {
                Text(AppLocalization.text(
                    english: "Cache cleared.",
                    simplified: "缓存已清除。",
                    traditional: "快取已清除。"
                ))
            }
        }
    }

    private var clearCacheTitle: String {
        AppLocalization.text(english: "Clear Cache", simplified: "清除缓存", traditional: "清除快取")
    }

    // MARK: - Accessibility

    private var accessibilitySection: some View {
        Section {
            Toggle(AppLocalization.localized("Show Accessibility Badges"), isOn: $showBadges)
        } header: {
            Text(AppLocalization.localized("Accessibility"))
        }
    }

}
