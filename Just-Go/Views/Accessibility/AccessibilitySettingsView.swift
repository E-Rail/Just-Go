import SwiftUI
import UIKit

struct AccessibilitySettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var voiceOverOn = UIAccessibility.isVoiceOverRunning

    var body: some View {
        NavigationStack {
            Form {
                primaryCategorySection
                mobilitySection
                visionSection
                hearingSection
                cognitiveSection
            }
            .navigationTitle(AppLocalization.localized("Accessibility"))
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
                voiceOverOn = UIAccessibility.isVoiceOverRunning
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
    }

    private var primaryCategorySection: some View {
        Section {
            Picker(AppLocalization.localized("Primary Category"), selection: preferenceBinding(\.primaryCategory)) {
                ForEach(DisabilityCategory.allCases, id: \.self) { category in
                    Label(category.displayName, systemImage: category.icon)
                        .tag(category)
                }
            }
        } header: {
            Text(AppLocalization.localized("Primary Disability Category"))
        }
    }

    private var mobilitySection: some View {
        Section(AppLocalization.localized("Mobility")) {
            Toggle(AppLocalization.localized("Requires Wheelchair Access"), isOn: preferenceBinding(\.requiresWheelchairAccess))
            Toggle(AppLocalization.localized("Prefer Elevator"), isOn: preferenceBinding(\.prefersElevator))
            Toggle(AppLocalization.localized("Avoid Stairs"), isOn: preferenceBinding(\.avoidStairs))

            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Max Walking Distance"))
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
                Text(AppLocalization.distance(appState.accessibilityPreference.maxWalkingDistance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // VoiceOver / high contrast / large text / LED flash are SYSTEM features: an app
    // cannot toggle them (and there is no public deep-link to Settings > Accessibility),
    // so these rows show the real state where readable and the exact Settings path —
    // honest guidance instead of switches that silently do nothing.
    private var visionSection: some View {
        Section {
            systemFeatureRow(
                title: AppLocalization.localized("VoiceOver Support"),
                status: voiceOverOn
                    ? AppLocalization.text(english: "On", simplified: "已开启", traditional: "已開啟")
                    : AppLocalization.text(english: "Off", simplified: "未开启", traditional: "未開啟"),
                path: AppLocalization.text(
                    english: "Turn on in Settings > Accessibility > VoiceOver. You can also ask Siri, or triple-click the side button.",
                    simplified: "请在 设置 > 辅助功能 > 旁白 中开启，也可通过 Siri 或连按三下侧边按钮。",
                    traditional: "請在 設定 > 輔助使用 > 旁白 中開啟，也可透過 Siri 或連按三下側邊按鈕。"
                )
            )
            systemFeatureRow(
                title: AppLocalization.localized("High Contrast Mode"),
                status: nil,
                path: AppLocalization.text(
                    english: "Turn on in Settings > Accessibility > Display & Text Size > Increase Contrast.",
                    simplified: "请在 设置 > 辅助功能 > 显示与文字大小 > 增强对比度 中开启。",
                    traditional: "請在 設定 > 輔助使用 > 螢幕顯示與文字大小 > 增加對比 中開啟。"
                )
            )
            systemFeatureRow(
                title: AppLocalization.localized("Large Text"),
                status: nil,
                path: AppLocalization.text(
                    english: "The app follows your system text size. Change it in Settings > Display & Brightness > Text Size; for even larger sizes use Settings > Accessibility > Display & Text Size > Larger Text.",
                    simplified: "本应用跟随系统字体大小。请在 设置 > 显示与亮度 > 文字大小 中调整；更大字号请在 设置 > 辅助功能 > 显示与文字大小 > 更大字体 中开启。",
                    traditional: "本 App 跟隨系統文字大小。請在 設定 > 螢幕顯示與亮度 > 文字大小 中調整；更大字級請在 設定 > 輔助使用 > 螢幕顯示與文字大小 > 放大文字 中開啟。"
                )
            )
            Toggle(AppLocalization.localized("Audio Navigation"), isOn: preferenceBinding(\.audioNavigation))
        } header: {
            Text(AppLocalization.localized("Vision"))
        } footer: {
            Text(AppLocalization.text(
                english: "Audio Navigation speaks each step aloud during step-by-step trips.",
                simplified: "语音导航会在分步出行时朗读每个步骤。",
                traditional: "語音導航會在分步出行時朗讀每個步驟。"
            ))
        }
    }

    private var hearingSection: some View {
        Section {
            Toggle(AppLocalization.localized("Visual Announcements"), isOn: preferenceBinding(\.visualAnnouncements))
            Toggle(AppLocalization.localized("Vibration Alerts"), isOn: preferenceBinding(\.vibrationAlerts))
            systemFeatureRow(
                title: AppLocalization.localized("Flash Alerts"),
                status: nil,
                path: AppLocalization.text(
                    english: "iPhone can flash the LED for notifications (including this app's trip reminders): Settings > Accessibility > Audio & Visual > LED Flash for Alerts.",
                    simplified: "iPhone 可在收到通知（含本应用的出发提醒）时闪烁 LED：设置 > 辅助功能 > 音频/视觉 > LED 闪烁以示提醒。",
                    traditional: "iPhone 可在收到通知（含本 App 的出發提醒）時閃爍 LED：設定 > 輔助使用 > 音訊/視覺 > LED 閃爍提示。"
                )
            )
        } header: {
            Text(AppLocalization.localized("Hearing"))
        } footer: {
            Text(AppLocalization.text(
                english: "During step-by-step trips, Visual Announcements shows a banner and Vibration Alerts plays a haptic at every step change.",
                simplified: "分步出行时，视觉播报会在每次步骤变化时显示横幅，振动提醒会同时触发振动。",
                traditional: "分步出行時，視覺播報會在每次步驟變化時顯示橫幅，震動提醒會同時觸發震動。"
            ))
        }
    }

    private var cognitiveSection: some View {
        Section {
            // "Simplified UI" used to sit here. Nothing in the app ever read `simplifiedUI` — no
            // view hid anything — so a rider with a cognitive-accessibility need flipped a switch
            // that did nothing, on the one screen that exists to serve them. A control that lies
            // is worse than a control that is absent.
            Toggle(AppLocalization.localized("Step-by-Step Guidance"), isOn: preferenceBinding(\.stepByStepGuidance))
        } header: {
            Text(AppLocalization.localized("Cognitive"))
        } footer: {
            Text(AppLocalization.text(
                english: "Step-by-Step Guidance opens the guided navigator directly when you view a route.",
                simplified: "分步指引会在查看路线时直接进入分步导航。",
                traditional: "分步指引會在查看路線時直接進入分步導航。"
            ))
        }
    }

    private func systemFeatureRow(title: String, status: String?, path: String) -> some View {
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

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<AccessibilityPreference, Value>) -> Binding<Value> {
        Binding(
            get: { appState.accessibilityPreference[keyPath: keyPath] },
            set: { appState.accessibilityPreference[keyPath: keyPath] = $0 }
        )
    }
}
