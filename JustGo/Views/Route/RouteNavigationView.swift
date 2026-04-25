import SwiftUI

struct RouteNavigationView: View {
    let route: Route
    @Environment(AccessibilityService.self) private var accessibilityService
    @State private var currentSegmentIndex = 0
    @State private var isNavigating = false
    @Environment(\.dismiss) private var dismiss

    var currentSegment: RouteSegment? {
        guard currentSegmentIndex < route.segments.count else { return nil }
        return route.segments[currentSegmentIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Map placeholder
            Rectangle()
                .fill(Color(.systemGroupedBackground))
                .frame(height: 300)
                .overlay {
                    VStack {
                        Image(systemName: "map.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Navigation Map")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

            // Navigation info
            VStack(spacing: 16) {
                if let segment = currentSegment {
                    currentStepCard(segment)
                }

                // Progress
                VStack(spacing: 8) {
                    ProgressView(value: Double(currentSegmentIndex), total: Double(route.segments.count))
                        .tint(.blue)

                    Text("Step \(currentSegmentIndex + 1) of \(route.segments.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // Controls
                HStack(spacing: 20) {
                    Button(action: previousStep) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                            .padding()
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(currentSegmentIndex == 0)

                    Button(action: { isNavigating.toggle() }) {
                        Image(systemName: isNavigating ? "pause.fill" : "play.fill")
                            .font(.title)
                            .padding(20)
                            .background(Color.blue, in: Circle())
                            .foregroundStyle(.white)
                    }

                    Button(action: nextStep) {
                        Image(systemName: "chevron.right")
                            .font(.title2)
                            .padding()
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(currentSegmentIndex >= route.segments.count - 1)
                }

                // Accessibility announcements
                if let segment = currentSegment {
                    accessibilityAnnouncementBar(segment)
                }
            }
            .padding()

            Spacer()
        }
        .navigationTitle("Navigation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("End") {
                    dismiss()
                }
            }
        }
    }

    private func currentStepCard(_ segment: RouteSegment) -> some View {
        GlassCard {
            HStack {
                segmentIcon(segment)

                VStack(alignment: .leading, spacing: 4) {
                    Text(segmentLabel(segment))
                        .font(.headline)

                    if let from = segment.fromStationName, let to = segment.toStationName {
                        Text("\(from) → \(to)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(segment.formattedDuration)
                    .font(.title3)
                    .fontWeight(.bold)
            }
        }
    }

    private func segmentIcon(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Image(systemName: "figure.walk")
            case .subway:
                Image(systemName: "tram.fill")
            case .transfer:
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .font(.title2)
        .foregroundStyle(Color(hex: segment.lineColorHex ?? "#000000"))
    }

    private func segmentLabel(_ segment: RouteSegment) -> String {
        switch segment.type {
        case .walking:
            return "Walk to \(segment.toStationName ?? "station")"
        case .subway:
            return "\(segment.lineName ?? "Subway") toward \(segment.toStationName ?? "")"
        case .transfer:
            return "Transfer to \(segment.lineName ?? "next line")"
        }
    }

    private func accessibilityAnnouncementBar(_ segment: RouteSegment) -> some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.blue)
            Text("Voice guidance active")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Announce") {
                accessibilityService.announce(
                    segmentLabel(segment),
                    priority: .high
                )
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func nextStep() {
        if currentSegmentIndex < route.segments.count - 1 {
            currentSegmentIndex += 1
            accessibilityService.playHaptic(.navigation)
            if let segment = currentSegment {
                accessibilityService.announce(segmentLabel(segment), priority: .high)
            }
        }
    }

    private func previousStep() {
        if currentSegmentIndex > 0 {
            currentSegmentIndex -= 1
            accessibilityService.playHaptic(.navigation)
        }
    }
}
