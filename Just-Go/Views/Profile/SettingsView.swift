import SwiftUI
import UIKit

struct SettingsView: View {
    /// False when this is a detail column rather than a sheet. `dismiss()` has nothing to dismiss
    /// in a column, so a Done button there is a control that looks live and does nothing.
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss
    @Environment(DIContainer.self) private var container
    @AppStorage(AppLocalization.preferenceKey) private var languagePreference = AppLanguagePreference.system.rawValue
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5
    @AppStorage("arrivalAlertLeadMinutes") private var arrivalAlertLeadMinutes = 2
    @AppStorage(AccessBicycle.storageKey) private var usesElectricBike = false
    @State private var showTour = false
    @State private var showClearCacheConfirmation = false
    @State private var didClearCache = false
    @State private var showForgetAnswersConfirmation = false
    @State private var didForgetAnswers = false

    private let leadMinuteOptions = [5, 10, 15, 20, 30]
    private let arrivalLeadMinuteOptions = [1, 2, 3, 5]

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                notificationsSection
                travelSection
                dataSection
                helpSection
            }
            .navigationTitle(AppLocalization.localized("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if showsDoneButton {
                        Button(AppLocalization.localized("Done")) { dismiss() }
                    }
                }
            }
            .fullScreenCover(isPresented: $showTour) {
                OnboardingTourView { showTour = false }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            ThemePickerRow()
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            Picker(AppLocalization.localized("App Language"), selection: $languagePreference) {
                ForEach(AppLanguagePreference.allCases) { preference in
                    Text(preference.localizedName).tag(preference.rawValue)
                }
            }
        } header: {
            Text(AppLocalization.text(english: "Appearance", simplified: "外观", traditional: "外觀"))
        } footer: {
            if languagePreference != AppLocalization.launchPreference.rawValue {
                Text(AppLocalization.localized("Language changes take effect after restarting Just-Go."))
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Picker(
                AppLocalization.text(english: "Leave reminder", simplified: "出发前提醒", traditional: "出發前提醒"),
                selection: $reminderLeadMinutes
            ) {
                ForEach(leadMinuteOptions, id: \.self) { minutes in
                    Text(AppLocalization.text(
                        english: "\(minutes) min before departure",
                        simplified: "出发前\(minutes)分钟",
                        traditional: "出發前\(minutes)分鐘"
                    )).tag(minutes)
                }
            }
            Picker(
                AppLocalization.text(english: "Get-off alert", simplified: "下车提醒", traditional: "下車提醒"),
                selection: $arrivalAlertLeadMinutes
            ) {
                ForEach(arrivalLeadMinuteOptions, id: \.self) { minutes in
                    Text(AppLocalization.text(
                        english: "\(minutes) min before the stop",
                        simplified: "到站前\(minutes)分钟",
                        traditional: "到站前\(minutes)分鐘"
                    )).tag(minutes)
                }
            }
        } header: {
            Text(AppLocalization.localized("Notifications"))
        } footer: {
            Text(AppLocalization.text(
                english: "Leave reminder is the alert on a planned route. Get-off alert is the one during Live Go. The system asks for notification permission the first time you use either.",
                simplified: "出发前提醒用于已规划的行程，下车提醒用于实时导航。首次使用时系统会询问通知权限。",
                traditional: "出發前提醒用於已規劃的行程，下車提醒用於即時導航。首次使用時系統會詢問通知權限。"
            ))
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            // `.buttonStyle(.plain)` with the icon tinted by hand, not a bare `Button`. A Button's
            // label inherits the accent colour, so this row read orange while the `NavigationLink`
            // directly below it read black — two rows that open a screen, styled as two different
            // kinds of control. The icon is tinted explicitly because plain takes that too.
            Button {
                showTour = true
            } label: {
                Label {
                    Text(AppLocalization.text(english: "App Tour", simplified: "界面导览", traditional: "介面導覽"))
                } icon: {
                    Image(systemName: "sparkles.tv")
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                HelpFAQView()
            } label: {
                Label(
                    AppLocalization.text(english: "FAQ", simplified: "常见问题", traditional: "常見問題"),
                    systemImage: "questionmark.circle"
                )
            }
        } header: {
            Text(AppLocalization.text(english: "Help", simplified: "帮助", traditional: "幫助"))
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
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
            // The one thing a rider gives this app that it keeps, and until now there was no way
            // to take it back. `forgetEverything()` has existed since transfer answers were added,
            // with a comment saying it was for "whatever delete-my-data control ships"; nothing
            // ever called it. Deliberately not folded into Clear Cache above, whose alert promises
            // that records are not affected — these are records, and deleting them belongs to its
            // own decision.
            Button(role: .destructive) {
                showForgetAnswersConfirmation = true
            } label: {
                Label(forgetAnswersTitle, systemImage: "person.crop.circle.badge.xmark")
            }
            .alert(forgetAnswersTitle, isPresented: $showForgetAnswersConfirmation) {
                Button(forgetAnswersTitle, role: .destructive) {
                    container.transferInsightService.forgetEverything()
                    didForgetAnswers = true
                }
                Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            } message: {
                Text(AppLocalization.text(
                    english: "How you rated transfers will be deleted from this device. It has never been sent anywhere else.",
                    simplified: "您对换乘的评价将从本机删除。这些内容从未发送到别处。",
                    traditional: "您對換乘的評價將從本機刪除。這些內容從未傳送到別處。"
                ))
            }
        } header: {
            Text(AppLocalization.text(english: "On this device", simplified: "本机数据", traditional: "本機資料"))
        } footer: {
            if didForgetAnswers {
                Text(AppLocalization.text(
                    english: "Your transfer answers were deleted.",
                    simplified: "您的换乘回答已删除。",
                    traditional: "您的換乘回答已刪除。"
                ))
            }
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

    private var forgetAnswersTitle: String {
        AppLocalization.text(
            english: "Delete My Transfer Answers",
            simplified: "删除我的换乘回答",
            traditional: "刪除我的換乘回答"
        )
    }

    /// How the rider covers a first or last mile too long to walk. The distance ladder that picks
    /// walking, cycling or driving is unchanged; this only says which kind of bike the cycling
    /// answer means, and it changes both the route drawn and the time quoted.
    private var travelSection: some View {
        Section {
            Toggle(
                AppLocalization.text(
                    english: "I ride an electric bike",
                    simplified: "我骑电动车",
                    traditional: "我騎電動車"
                ),
                isOn: $usesElectricBike
            )
        } header: {
            Text(AppLocalization.text(english: "Getting around", simplified: "出行方式", traditional: "出行方式"))
        } footer: {
            Text(AppLocalization.text(
                english: "Used for the ride to and from the station.",
                simplified: "用于往返车站的接驳路段。",
                traditional: "用於往返車站的接駁路段。"
            ))
        }
    }
}

struct HelpFAQView: View {
    @State private var didCopyQQ = false

    var body: some View {
        List {
            Section {
                Button {
                    UIPasteboard.general.string = "1062301115"
                    didCopyQQ = true
                } label: {
                    HStack {
                        Text(AppLocalization.text(
                            english: "QQ service group",
                            simplified: "QQ 服务群",
                            traditional: "QQ 服務群"
                        ))
                        Spacer()
                        Text(verbatim: "1062301115")
                            .foregroundStyle(.secondary)
                        // The row still has to look tappable once the label stops being tinted.
                        Image(systemName: didCopyQQ ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text(AppLocalization.text(english: "Support", simplified: "支持", traditional: "支援"))
            } footer: {
                if didCopyQQ {
                    Text(AppLocalization.text(
                        english: "Copied. Open QQ and join that group.",
                        simplified: "已复制。请打开 QQ 加入该群。",
                        traditional: "已複製。請打開 QQ 加入該群。"
                    ))
                } else {
                    Text(AppLocalization.text(
                        english: "The number is copied to the clipboard. Just-Go does not open QQ for you.",
                        simplified: "号码会复制到剪贴板。Just-Go 不会替您打开 QQ。",
                        traditional: "號碼會複製到剪貼簿。Just-Go 不會替您打開 QQ。"
                    ))
                }
            }

            Section {
                faqRow(
                    question: AppLocalization.text(
                        english: "Where do I set wheelchair or walking distance?",
                        simplified: "轮椅和无障碍、步行距离在哪里设置？",
                        traditional: "輪椅和無障礙、步行距離在哪裡設定？"
                    ),
                    answer: AppLocalization.text(
                        english: "Profile → Accessibility. Route search uses those settings.",
                        simplified: "个人 → 无障碍。路线搜索会按这些设置规划。",
                        traditional: "個人 → 無障礙。路線搜尋會按這些設定規劃。"
                    )
                )
                faqRow(
                    question: AppLocalization.text(
                        english: "Why didn't the language change?",
                        simplified: "为什么语言没有立刻变？",
                        traditional: "為什麼語言沒有立刻變？"
                    ),
                    answer: AppLocalization.text(
                        english: "Close Just-Go completely, then open it again.",
                        simplified: "请完全退出 Just-Go，再重新打开。",
                        traditional: "請完全退出 Just-Go，再重新打開。"
                    )
                )
                faqRow(
                    question: AppLocalization.text(
                        english: "Do routes work without signal?",
                        simplified: "没有信号也能规划路线吗？",
                        traditional: "沒有訊號也能規劃路線嗎？"
                    ),
                    answer: AppLocalization.text(
                        english: "Metro routing is on the phone. Place search, walking legs, and first/last trains need a network, in cities that publish them.",
                        simplified: "地铁规划在手机本地完成。地点搜索、步行路段，以及有公布数据的城市的首末班车，需要网络。",
                        traditional: "地鐵規劃在手機本機完成。地點搜尋、步行路段，以及有公布資料的城市的首末班車，需要網路。"
                    )
                )
            } header: {
                Text(AppLocalization.text(english: "FAQ", simplified: "常见问题", traditional: "常見問題"))
            }
        }
        .navigationTitle(AppLocalization.text(english: "FAQ", simplified: "常见问题", traditional: "常見問題"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func faqRow(question: String, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.body.weight(.medium))
            Text(answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
