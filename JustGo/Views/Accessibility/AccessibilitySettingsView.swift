import SwiftUI

struct AccessibilitySettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

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
        } footer: {
            Text(AppLocalization.localized("This helps us customize the app experience for you"))
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

    private var visionSection: some View {
        Section(AppLocalization.localized("Vision")) {
            Toggle(AppLocalization.localized("VoiceOver Support"), isOn: preferenceBinding(\.voiceOverEnabled))
            Toggle(AppLocalization.localized("High Contrast Mode"), isOn: preferenceBinding(\.highContrastMode))
            Toggle(AppLocalization.localized("Large Text"), isOn: preferenceBinding(\.largeText))
            Toggle(AppLocalization.localized("Audio Navigation"), isOn: preferenceBinding(\.audioNavigation))
        }
    }

    private var hearingSection: some View {
        Section(AppLocalization.localized("Hearing")) {
            Toggle(AppLocalization.localized("Visual Announcements"), isOn: preferenceBinding(\.visualAnnouncements))
            Toggle(AppLocalization.localized("Vibration Alerts"), isOn: preferenceBinding(\.vibrationAlerts))
            Toggle(AppLocalization.localized("Flash Alerts"), isOn: preferenceBinding(\.flashAlerts))
        }
    }

    private var cognitiveSection: some View {
        Section(AppLocalization.localized("Cognitive")) {
            Toggle(AppLocalization.localized("Simplified UI"), isOn: preferenceBinding(\.simplifiedUI))
            Toggle(AppLocalization.localized("Step-by-Step Guidance"), isOn: preferenceBinding(\.stepByStepGuidance))
        }
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<AccessibilityPreference, Value>) -> Binding<Value> {
        Binding(
            get: { appState.accessibilityPreference[keyPath: keyPath] },
            set: { appState.accessibilityPreference[keyPath: keyPath] = $0 }
        )
    }
}
