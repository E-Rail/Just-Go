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
            .navigationTitle("Accessibility")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var primaryCategorySection: some View {
        Section {
            Picker("Primary Category", selection: $appState.accessibilityPreference.primaryCategory) {
                ForEach(DisabilityCategory.allCases, id: \.self) { category in
                    Label(category.displayName, systemImage: category.icon)
                        .tag(category)
                }
            }
        } header: {
            Text("Primary Disability Category")
        } footer: {
            Text("This helps us customize the app experience for you")
        }
    }

    private var mobilitySection: some View {
        Section("Mobility") {
            Toggle("Requires Wheelchair Access", isOn: $appState.accessibilityPreference.requiresWheelchairAccess)
            Toggle("Prefer Elevator", isOn: $appState.accessibilityPreference.prefersElevator)
            Toggle("Avoid Stairs", isOn: $appState.accessibilityPreference.avoidStairs)

            VStack(alignment: .leading, spacing: 8) {
                Text("Max Walking Distance")
                Slider(
                    value: $appState.accessibilityPreference.maxWalkingDistance,
                    in: 100...1000,
                    step: 50
                ) {
                    Text("Distance")
                } minimumValueLabel: {
                    Text("100m")
                        .font(.caption)
                } maximumValueLabel: {
                    Text("1km")
                        .font(.caption)
                }
                Text("\(Int(appState.accessibilityPreference.maxWalkingDistance))m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var visionSection: some View {
        Section("Vision") {
            Toggle("VoiceOver Support", isOn: $appState.accessibilityPreference.voiceOverEnabled)
            Toggle("High Contrast Mode", isOn: $appState.accessibilityPreference.highContrastMode)
            Toggle("Large Text", isOn: $appState.accessibilityPreference.largeText)
            Toggle("Audio Navigation", isOn: $appState.accessibilityPreference.audioNavigation)
        }
    }

    private var hearingSection: some View {
        Section("Hearing") {
            Toggle("Visual Announcements", isOn: $appState.accessibilityPreference.visualAnnouncements)
            Toggle("Vibration Alerts", isOn: $appState.accessibilityPreference.vibrationAlerts)
            Toggle("Flash Alerts", isOn: $appState.accessibilityPreference.flashAlerts)
        }
    }

    private var cognitiveSection: some View {
        Section("Cognitive") {
            Toggle("Simplified UI", isOn: $appState.accessibilityPreference.simplifiedUI)
            Toggle("Step-by-Step Guidance", isOn: $appState.accessibilityPreference.stepByStepGuidance)
        }
    }
}
