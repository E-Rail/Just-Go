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

    var currentAccessGuide: RouteAccessGuide? {
        guard let segment = currentSegment, segment.type == .walking else { return nil }
        if currentSegmentIndex < (route.segments.firstIndex { $0.type == .subway } ?? route.segments.count) {
            return route.originAccessGuide
        }
        if currentSegmentIndex > (route.segments.lastIndex { $0.type == .subway } ?? -1) {
            return route.destinationAccessGuide
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            TransitMapView(
                visibleRegion: .constant(route.previewRegion),
                stations: [],
                subwayLines: [],
                route: route,
                showsUserLocation: true,
                onStationSelected: { _ in }
            )
            .frame(height: 300)

            VStack(spacing: 16) {
                if let segment = currentSegment {
                    currentStepCard(segment)
                }

                VStack(spacing: 8) {
                    ProgressView(value: Double(currentSegmentIndex), total: Double(route.segments.count))
                        .tint(.blue)

                    Text(AppLocalization.text(
                        english: "Step \(currentSegmentIndex + 1) of \(route.segments.count)",
                        chinese: "第 \(currentSegmentIndex + 1) 步，共 \(route.segments.count) 步"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

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

                if let segment = currentSegment {
                    accessibilityAnnouncementBar(segment)
                }
            }
            .padding()

            Spacer()
        }
        .navigationTitle(AppLocalization.localized("Navigation"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalization.localized("End")) {
                    dismiss()
                }
            }
        }
    }

    private func currentStepCard(_ segment: RouteSegment) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    segmentIcon(segment)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentAccessGuide?.primaryInstruction ?? segment.navigationLabel)
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

                if let firstStep = segment.walkingDirections?.first, segment.type == .walking {
                    Label(firstStep.instruction, systemImage: walkingStepIcon(firstStep))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let guide = currentAccessGuide, !guide.accessibilityNotes.isEmpty {
                    ForEach(guide.accessibilityNotes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    private func walkingStepIcon(_ step: WalkingStep) -> String {
        if step.hasElevator { return "arrow.up.arrow.down.square" }
        if step.hasRamp { return "figure.roll" }
        if step.hasEscalator { return "arrow.up.right.square" }
        if step.hasStairs { return "stairs" }
        return "figure.walk"
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

    private func accessibilityAnnouncementBar(_ segment: RouteSegment) -> some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.blue)
            Text(AppLocalization.localized("Voice guidance active"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(AppLocalization.localized("Announce")) {
                accessibilityService.announce(
                    segment.navigationLabel,
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
                accessibilityService.announce(segment.navigationLabel, priority: .high)
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
