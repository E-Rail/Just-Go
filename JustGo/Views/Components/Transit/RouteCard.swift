import SwiftUI

struct RouteCard: View {
    let route: Route
    let confidence: RouteConfidence
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.formattedDuration)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("\(route.strategy.localizedName) • \(route.formattedWalkingDistance)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(DataConfidence.mapKit.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    confidenceBadge
                }

                // Route segments preview
                HStack(spacing: 2) {
                    ForEach(route.segments) { segment in
                        segmentBar(segment)
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())

                RouteStationTimeline(stops: route.stationTimelineStops)

                if let originGuide = route.originAccessGuide,
                   let destinationGuide = route.destinationAccessGuide {
                    VStack(alignment: .leading, spacing: 6) {
                        accessPreviewRow(guide: originGuide, icon: "arrow.down.forward.circle")
                        accessPreviewRow(guide: destinationGuide, icon: "arrow.up.forward.circle")
                    }
                }

                Text(confidence.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let warning = confidence.warnings.first {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(confidence.level.color)
                        .lineLimit(2)
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .overlay(alignment: .leading) {
                routeColorAccent
                    .frame(width: 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var routeColorAccent: some View {
        VStack(spacing: 0) {
            let subwaySegments = route.segments.filter { $0.type.isTransit }
            ForEach(subwaySegments) { segment in
                Color(hex: segment.lineColorHex ?? "#007AFF")
            }
            if subwaySegments.isEmpty {
                Color.gray
            }
        }
    }

    private func segmentBar(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Color.gray
            case .subway, .transit:
                Color(hex: segment.lineColorHex ?? "#000000")
            case .transfer:
                Color.orange
            }
        }
        .frame(minWidth: segment.type == .walking ? 20 : 40)
    }

    private func accessPreviewRow(guide: RouteAccessGuide, icon: String) -> some View {
        Label {
            Text(guide.primaryInstruction)
                .font(.caption)
                .lineLimit(2)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(.secondary)
    }

    private var confidenceBadge: some View {
        VStack(spacing: 2) {
            Image(systemName: confidence.level.iconName)
            Text("\(confidence.score)")
                .fontWeight(.semibold)
            Text(confidence.level.title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption)
        .frame(minWidth: 74)
        .padding(.vertical, 6)
        .foregroundStyle(confidence.level.color)
        .accessibilityLabel("\(confidence.level.title), \(confidence.score) \(AppLocalization.localized("out of 100"))")
    }
}

extension RouteConfidenceLevel {
    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    var iconName: String {
        switch self {
        case .high: return "checkmark.seal.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "xmark.octagon.fill"
        }
    }
}
