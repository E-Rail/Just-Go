import SwiftUI

struct RouteDetailView: View {
    let route: Route
    @State private var showNavigation = false
    @Environment(AccessibilityService.self) private var accessibilityService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                routeSummaryCard
                routeMapPreview
                accessGuidanceCard
                accessibilityInfoCard
                segmentsTimeline
                startNavigationButton
            }
            .padding()
        }
        .navigationTitle(AppLocalization.localized("Route Details"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showNavigation) {
            RouteNavigationView(route: route)
        }
    }

    private var routeMapPreview: some View {
        TransitMapView(
            visibleRegion: .constant(route.previewRegion),
            stations: [],
            subwayLines: [],
            route: route,
            showsUserLocation: false,
            onStationSelected: { _ in }
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var routeSummaryCard: some View {
        GlassCard {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.origin)
                            .font(.headline)
                        Text(AppLocalization.localized("Origin"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(route.destination)
                            .font(.headline)
                        Text(AppLocalization.localized("Destination"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 20) {
                    StatItem(title: "Duration", value: route.formattedDuration, icon: "clock")
                    StatItem(title: "Stops", value: "\(route.totalStops)", icon: "tram")
                    StatItem(title: "Transfers", value: "\(route.transferCount)", icon: "arrow.triangle.2.circlepath")
                }

                if route.isFullyAccessible {
                    HStack {
                        Image(systemName: "figure.roll")
                            .foregroundStyle(.green)
                        Text(AppLocalization.localized("Fully Accessible Route"))
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1), in: Capsule())
                }
            }
        }
    }

    private var accessibilityInfoCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Accessibility Info"))
                    .font(.headline)

                if route.isFullyAccessible {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(AppLocalization.localized("All stations on this route have elevator access"))
                            .font(.subheadline)
                    }
                }

                if !route.warnings.isEmpty {
                    ForEach(route.warnings) { warning in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning.message)
                                .font(.subheadline)
                        }
                    }
                }

                let accessibleStops = route.segments.filter { $0.type == .subway }.count
                Text(AppLocalization.text(
                    english: "\(accessibleStops) accessible stations on this route",
                    chinese: "此路线有\(accessibleStops)座无障碍车站"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var accessGuidanceCard: some View {
        if !route.accessGuidance.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(AppLocalization.localized("Access Guidance"))
                        .font(.headline)

                    ForEach(route.accessGuidance) { guide in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: guide.kind == .origin ? "arrow.down.forward.circle.fill" : "arrow.up.forward.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                    .frame(width: 26)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(guide.title)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text(guide.primaryInstruction)
                                        .font(.subheadline)
                                    Text(guide.formattedWalk)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            ForEach(guide.accessibilityNotes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }

                            if let firstStep = guide.walkingSteps.first {
                                Text(firstStep.instruction)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 36)
                            }
                        }

                        if guide.id != route.accessGuidance.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var segmentsTimeline: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppLocalization.localized("Route Steps"))
                    .font(.headline)

                ForEach(route.segments) { segment in
                    segmentTimelineRow(segment)
                }
            }
        }
    }

    private func segmentTimelineRow(_ segment: RouteSegment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack {
                segmentIcon(segment)
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 2, height: 20)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(segment.summaryLabel)
                    .font(.body)
                    .fontWeight(.medium)

                if let from = segment.fromStationName, let to = segment.toStationName {
                    Text("\(from) → \(to)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(segment.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let firstDirection = segment.walkingDirections?.first?.instruction,
                   segment.type == .walking {
                    Text(firstDirection)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(segment.accessibilityNotes, id: \.self) { note in
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text(note)
                            .font(.caption)
                    }
                    .foregroundStyle(.blue)
                }
            }

            Spacer()
        }
    }

    private func segmentIcon(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Image(systemName: "figure.walk")
                    .padding(6)
                    .background(Color.gray.opacity(0.2), in: Circle())
            case .subway:
                Image(systemName: "tram.fill")
                    .padding(6)
                    .background(Color(hex: segment.lineColorHex ?? "#000000").opacity(0.2), in: Circle())
            case .transfer:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .padding(6)
                    .background(Color.orange.opacity(0.2), in: Circle())
            }
        }
    }

    private var startNavigationButton: some View {
        Button(action: { showNavigation = true }) {
            HStack {
                Image(systemName: "location.fill")
                Text(AppLocalization.localized("Start Navigation"))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
            Text(AppLocalization.localized(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
