import SwiftUI
import UIKit

/// The policy pages on the app's own website. Plain http: over HTTPS the site's host presents its
/// own certificate, not one for just-go.com.cn, so an https link opens on a certificate warning.
/// Safari loads these, not the app, so App Transport Security does not apply. Move them to https
/// once a certificate covers the domain.
enum AppWebLinks {
    static let privacyPolicy = URL(string: "http://just-go.com.cn/privacy/")!
    static let termsOfService = URL(string: "http://just-go.com.cn/terms/")!
}

/// The pages Settings pushes. A value per page, so a DEBUG launch can open one.
enum SettingsDestination: String, Hashable {
    case transitData
    case systemAccessibility
    case faq
}

/// The Settings tab: everything about how the app behaves, on one page, grouped by when it matters.
/// How routes are planned, what a trip does while it runs, how the app looks, the data it runs
/// on, then help and about. Pages are pushed, never presented: a tab is already a place.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(DIContainer.self) private var container
    @Environment(\.openURL) private var openURL
    @AppStorage(AppLocalization.preferenceKey) private var languagePreference = AppLanguagePreference.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage("showAccessibilityBadges") private var showBadges = true
    @State private var path: [SettingsDestination] = []
    @State private var showTour = false

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                RoutePreferencesSection()
                TripGuidanceSection()
                displaySection
                dataSection
                helpSection
                aboutSection
            }
            .navigationTitle(AppLocalization.localized("Settings"))
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .transitData: TransitDataView()
                case .systemAccessibility: SystemAccessibilityFeaturesView()
                case .faq: HelpFAQView()
                }
            }
            .fullScreenCover(isPresented: $showTour) {
                OnboardingTourView { showTour = false }
            }
        }
        #if DEBUG
        // Every page here is behind a tap, and there is no tap injection.
        .task {
            if let seed = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SETTINGS"],
               let destination = SettingsDestination(rawValue: seed),
               path.isEmpty {
                appState.selectedTab = .settings
                path = [destination]
            }
        }
        #endif
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            ThemePickerRow()
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            // Applies immediately: `preferredColorScheme` at the window root re-renders the live
            // view tree, unlike the language row, which needs a relaunch.
            Picker(
                AppLocalization.text(english: "Light & Dark", simplified: "浅色与深色", traditional: "淺色與深色"),
                selection: $appearance
            ) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.name).tag(option.rawValue)
                }
            }
            Picker(AppLocalization.localized("App Language"), selection: $languagePreference) {
                ForEach(AppLanguagePreference.allCases) { preference in
                    Text(preference.localizedName).tag(preference.rawValue)
                }
            }
            .onChange(of: languagePreference) { _, newValue in
                AppLocalization.applyToSystem(AppLanguagePreference(rawValue: newValue) ?? .system)
            }
            Toggle(AppLocalization.localized("Show Accessibility Badges"), isOn: $showBadges)
            NavigationLink(value: SettingsDestination.systemAccessibility) {
                Text(SystemAccessibilityFeaturesView.title)
            }
        } header: {
            Text(AppLocalization.text(english: "Display", simplified: "显示", traditional: "顯示"))
        } footer: {
            if languagePreference != AppLocalization.launchPreference.rawValue {
                Text(AppLocalization.localized("Takes effect after you quit and reopen the app."))
            } else {
                Text(AppLocalization.text(
                    english: "Accessibility badges mark a station when elevator, ramp or tactile-path data exists.",
                    simplified: "无障碍标记会在车站有电梯、坡道或盲道数据时显示。",
                    traditional: "無障礙標記會在車站有電梯、坡道或導盲磚資料時顯示。"
                ))
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            NavigationLink(value: SettingsDestination.transitData) {
                LabeledContent {
                    Text(transitDataStatus)
                } label: {
                    Label {
                        Text(AppLocalization.localized("Transit Data"))
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        } header: {
            Text(AppLocalization.text(english: "Data", simplified: "数据", traditional: "資料"))
        } footer: {
            Text(AppLocalization.text(
                english: "Updates, the cities covered, sources and attribution.",
                simplified: "更新、覆盖的城市、数据来源与署名。",
                traditional: "更新、涵蓋的城市、資料來源與署名。"
            ))
        }
    }

    /// The row's answer to "is my data current", in a word or two.
    private var transitDataStatus: String {
        guard let updater = container.cityDataUpdater else { return "" }
        if updater.activity == .checking {
            return AppLocalization.text(english: "Checking…", simplified: "正在检查…", traditional: "正在檢查…")
        }
        switch updater.lastOutcome?.status {
        case .upToDate?:
            return AppLocalization.text(english: "Up to date", simplified: "已是最新", traditional: "已是最新")
        case .checked?:
            return updater.lastOutcome?.updates.isEmpty == false
                ? AppLocalization.text(english: "Updated", simplified: "已更新", traditional: "已更新")
                : AppLocalization.text(english: "Incomplete", simplified: "未完成", traditional: "未完成")
        case .unreachable?:
            return AppLocalization.text(english: "Offline", simplified: "无法连接", traditional: "無法連線")
        case .notConfigured?, nil:
            return ""
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            // A plain-styled button with the icon tinted by hand, so this row looks like the
            // `NavigationLink` below it rather than a different kind of control.
            Button {
                showTour = true
            } label: {
                HStack {
                    Label {
                        Text(AppLocalization.text(english: "App Tour", simplified: "界面导览", traditional: "介面導覽"))
                    } icon: {
                        Image(systemName: "sparkles.tv")
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    // The `NavigationLink` below draws a chevron for free; this row needs one to
                    // look like it leads somewhere too.
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink(value: SettingsDestination.faq) {
                Label {
                    Text(AppLocalization.text(english: "FAQ & Support", simplified: "常见问题与支持", traditional: "常見問題與支援"))
                } icon: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        } header: {
            Text(AppLocalization.text(english: "Help", simplified: "帮助", traditional: "幫助"))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent(AppLocalization.localized("Version")) {
                // From the bundle, not a literal, so it follows MARKETING_VERSION. The localization
                // validator cannot see this: its literal check requires a letter.
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            linkRow(AppLocalization.localized("Privacy Policy"), url: AppWebLinks.privacyPolicy)
            linkRow(AppLocalization.localized("Terms of Service"), url: AppWebLinks.termsOfService)
        } header: {
            Text(AppLocalization.localized("About"))
        }
    }

    /// A row that leaves the app: a plain-styled `Button`, not a `Link`, which tints its whole
    /// label with the accent and ignores `.foregroundStyle(.primary)`.
    private func linkRow(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        english: "Copied. Search for it in QQ.",
                        simplified: "已复制。请在 QQ 中搜索加入。",
                        traditional: "已複製。請在 QQ 中搜尋加入。"
                    ))
                } else {
                    Text(AppLocalization.text(
                        english: "Tap to copy the number, then search for it in QQ.",
                        simplified: "点击复制群号，然后在 QQ 中搜索加入。",
                        traditional: "點擊複製群號，然後在 QQ 中搜尋加入。"
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
                        english: "Settings → Routes, or Options on any plan. Every route follows them.",
                        simplified: "设置 → 路线，或在任一规划中点“选项”。每条路线都会遵循。",
                        traditional: "設定 → 路線，或在任一規劃中點「選項」。每條路線都會遵循。"
                    )
                )
                faqRow(
                    question: AppLocalization.text(
                        english: "Why didn't the language change?",
                        simplified: "为什么语言没有立刻变？",
                        traditional: "為什麼語言沒有立刻變？"
                    ),
                    answer: AppLocalization.text(
                        english: "Quit the app from the app switcher, then open it again.",
                        simplified: "从后台完全退出，再重新打开。",
                        traditional: "從背景完全退出，再重新打開。"
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
        .navigationTitle(AppLocalization.text(english: "FAQ & Support", simplified: "常见问题与支持", traditional: "常見問題與支援"))
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
