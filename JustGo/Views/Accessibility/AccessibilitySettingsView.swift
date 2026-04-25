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
            Picker("Primary Category", selection: preferenceBinding(\.primaryCategory)) {
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
            Toggle("Requires Wheelchair Access", isOn: preferenceBinding(\.requiresWheelchairAccess))
            Toggle("Prefer Elevator", isOn: preferenceBinding(\.prefersElevator))
            Toggle("Avoid Stairs", isOn: preferenceBinding(\.avoidStairs))

            VStack(alignment: .leading, spacing: 8) {
                Text("Max Walking Distance")
                Slider(
                    value: preferenceBinding(\.maxWalkingDistance),
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
            Toggle("VoiceOver Support", isOn: preferenceBinding(\.voiceOverEnabled))
            Toggle("High Contrast Mode", isOn: preferenceBinding(\.highContrastMode))
            Toggle("Large Text", isOn: preferenceBinding(\.largeText))
            Toggle("Audio Navigation", isOn: preferenceBinding(\.audioNavigation))
        }
    }

    private var hearingSection: some View {
        Section("Hearing") {
            Toggle("Visual Announcements", isOn: preferenceBinding(\.visualAnnouncements))
            Toggle("Vibration Alerts", isOn: preferenceBinding(\.vibrationAlerts))
            Toggle("Flash Alerts", isOn: preferenceBinding(\.flashAlerts))
        }
    }

    private var cognitiveSection: some View {
        Section("Cognitive") {
            Toggle("Simplified UI", isOn: preferenceBinding(\.simplifiedUI))
            Toggle("Step-by-Step Guidance", isOn: preferenceBinding(\.stepByStepGuidance))
        }
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<AccessibilityPreference, Value>) -> Binding<Value> {
        Binding(
            get: { appState.accessibilityPreference[keyPath: keyPath] },
            set: { appState.accessibilityPreference[keyPath: keyPath] = $0 }
        )
    }
}
