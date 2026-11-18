import SwiftUI
import UIKit

/// How every route is planned: what the rider needs from a station, and how far they will go on
/// foot or by bike to reach one. One section, shown in Settings and from a plan's Options, so the
/// screen where a route is read and the place its rules are changed cannot drift apart.
struct RoutePreferencesSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AccessBicycle.storageKey) private var usesElectricBike = false

    var body: some View {
        Section {
            Toggle(AppLocalization.localized("Requires Wheelchair Access"), isOn: preferenceBinding(\.requiresWheelchairAccess))
            Toggle(
                AppLocalization.text(english: "Requires Elevator", simplified: "需要电梯", traditional: "需要電梯"),
                isOn: preferenceBinding(\.prefersElevator)
            )
            Toggle(AppLocalization.localized("Avoid Stairs"), isOn: preferenceBinding(\.avoidStairs))

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(AppLocalization.localized("Max Walking Distance")) {
                    Text(AppLocalization.distance(appState.accessibilityPreference.maxWalkingDistance))
                }
                Slider(
                    value: preferenceBinding(\.maxWalkingDistance),
                    in: 100...1000,
                    step: 50
                ) {
                    Text(AppLocalization.localized("Distance"))
                } minimumValueLabel: {
                    Text(AppLocalization.distance(100))
                        .font(.caption)
                } maximumValueLabel: {
                    Text(AppLocalization.distance(1000))
                        .font(.caption)
                }
            }

            // Beside the walking distance, which answers the same question: how the rider covers
            // a first or last mile too long to walk. Which kind of bike changes both the route
            // drawn and the time quoted.
            Toggle(
                AppLocalization.text(
                    english: "I ride an electric bike",
                    simplified: "我骑电动车",
                    traditional: "我騎電動車"
                ),
                isOn: $usesElectricBike
            )
        } header: {
            Text(AppLocalization.text(english: "Routes", simplified: "路线", traditional: "路線"))
        } footer: {
            Text(AppLocalization.text(
                english: "Every route you plan follows these. Walking distance and bike type apply to getting to and from the station.",
                simplified: "规划的每条路线都会遵循这些设置。步行距离和车辆类型用于往返车站的接驳路段。",
                traditional: "規劃的每條路線都會遵循這些設定。步行距離和車輛類型用於往返車站的接駁路段。"
            ))
        }
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<AccessibilityPreference, Value>) -> Binding<Value> {
        Binding(
            get: { appState.accessibilityPreference[keyPath: keyPath] },
            set: { appState.accessibilityPreference[keyPath: keyPath] = $0 }
        )
    }
}

/// Route preferences opened from a plan, where their effect is on screen. The plan follows a
/// change as soon as it is made; Done only closes the sheet.
struct RouteOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                RoutePreferencesSection()
            }
            .navigationTitle(AppLocalization.text(english: "Route Options", simplified: "路线选项", traditional: "路線選項"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// What a trip under way does for the rider beyond showing the next step: the two reminders, and
/// how each step change is announced.
struct TripGuidanceSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5
    @AppStorage("arrivalAlertLeadMinutes") private var arrivalAlertLeadMinutes = 2

    private let leadMinuteOptions = [5, 10, 15, 20, 30]
    private let arrivalLeadMinuteOptions = [1, 2, 3, 5]

    var body: some View {
        Section {
            Picker(
                AppLocalization.text(english: "Before you leave", simplified: "出发前提醒", traditional: "出發前提醒"),
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
                AppLocalization.text(english: "Before your stop", simplified: "下车提醒", traditional: "下車提醒"),
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
            Toggle(AppLocalization.localized("Audio Navigation"), isOn: preferenceBinding(\.audioNavigation))
            Toggle(AppLocalization.localized("Visual Announcements"), isOn: preferenceBinding(\.visualAnnouncements))
            Toggle(AppLocalization.localized("Vibration Alerts"), isOn: preferenceBinding(\.vibrationAlerts))
            Toggle(AppLocalization.localized("Step-by-Step Guidance"), isOn: preferenceBinding(\.stepByStepGuidance))
        } header: {
            Text(AppLocalization.text(english: "During a Trip", simplified: "出行途中", traditional: "出行途中"))
        } footer: {
            // The rows name themselves; the footer says what each switch does at a step, and the
            // one thing none of them can: iOS will ask permission.
            Text(AppLocalization.text(
                english: "At each step change: Audio Navigation reads the step aloud, Visual Announcements show a banner, Vibration Alerts buzz. Step-by-Step Guidance opens the navigator as soon as you choose a route. iOS asks for notification permission the first time you use a reminder.",
                simplified: "每次步骤变化时：语音导航朗读该步骤，视觉提示显示横幅，振动提醒会振动。分步指引会在选定路线后直接打开分步导航。首次使用提醒时，系统会询问通知权限。",
                traditional: "每次步驟變化時：語音導航朗讀該步驟，視覺提示顯示橫幅，震動提醒會震動。分步指引會在選定路線後直接打開分步導航。首次使用提醒時，系統會詢問通知權限。"
            ))
        }
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<AccessibilityPreference, Value>) -> Binding<Value> {
        Binding(
            get: { appState.accessibilityPreference[keyPath: keyPath] },
            set: { appState.accessibilityPreference[keyPath: keyPath] = $0 }
        )
    }
}

/// VoiceOver, contrast, text size and LED flash are system features an app cannot switch (and
/// there is no public deep link to Settings > Accessibility), so this page shows the real state
/// where it is readable and the exact Settings path for each.
struct SystemAccessibilityFeaturesView: View {
    @State private var voiceOverOn = UIAccessibility.isVoiceOverRunning

    var body: some View {
        Form {
            Section {
                featureRow(
                    title: AppLocalization.localized("VoiceOver Support"),
                    status: voiceOverOn
                        ? AppLocalization.text(english: "On", simplified: "已开启", traditional: "已開啟")
                        : AppLocalization.text(english: "Off", simplified: "未开启", traditional: "未開啟"),
                    path: AppLocalization.text(
                        english: "Settings > Accessibility > VoiceOver. Or ask Siri, or triple-click the side button.",
                        simplified: "设置 > 辅助功能 > 旁白。或使用 Siri，或连按三下侧边按钮。",
                        traditional: "設定 > 輔助使用 > 旁白。或使用 Siri，或連按三下側邊按鈕。"
                    )
                )
                featureRow(
                    title: AppLocalization.localized("High Contrast Mode"),
                    status: nil,
                    path: AppLocalization.text(
                        english: "Settings > Accessibility > Display & Text Size > Increase Contrast.",
                        simplified: "设置 > 辅助功能 > 显示与文字大小 > 增强对比度。",
                        traditional: "設定 > 輔助使用 > 螢幕顯示與文字大小 > 增加對比。"
                    )
                )
                featureRow(
                    title: AppLocalization.localized("Large Text"),
                    status: nil,
                    path: AppLocalization.text(
                        english: "Settings > Display & Brightness > Text Size. Larger still: Settings > Accessibility > Display & Text Size > Larger Text.",
                        simplified: "设置 > 显示与亮度 > 文字大小。更大字号：设置 > 辅助功能 > 显示与文字大小 > 更大字体。",
                        traditional: "設定 > 螢幕顯示與亮度 > 文字大小。更大字級：設定 > 輔助使用 > 螢幕顯示與文字大小 > 放大文字。"
                    )
                )
                featureRow(
                    title: AppLocalization.localized("Flash Alerts"),
                    status: nil,
                    path: AppLocalization.text(
                        english: "Settings > Accessibility > Audio & Visual > LED Flash for Alerts. Covers trip reminders too.",
                        simplified: "设置 > 辅助功能 > 音频/视觉 > LED 闪烁以示提醒。出发提醒同样适用。",
                        traditional: "設定 > 輔助使用 > 音訊/視覺 > LED 閃爍提示。出發提醒同樣適用。"
                    )
                )
            } footer: {
                Text(AppLocalization.text(
                    english: "These are iOS settings. Just-Go follows them everywhere.",
                    simplified: "这些是 iOS 设置，Just-Go 会全程遵循。",
                    traditional: "這些是 iOS 設定，Just-Go 會全程遵循。"
                ))
            }
        }
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            voiceOverOn = UIAccessibility.isVoiceOverRunning
        }
    }

    static var title: String {
        AppLocalization.text(english: "iOS Accessibility Features", simplified: "iOS 辅助功能", traditional: "iOS 輔助使用功能")
    }

    private func featureRow(title: String, status: String?, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
