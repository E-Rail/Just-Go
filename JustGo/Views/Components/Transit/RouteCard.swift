import SwiftUI

struct RouteCard: View {
    let route: Route
    let confidence: RouteConfidence
    var comfort: RouteComfortForecast?
    var departurePlan: DeparturePlan?
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
                        Text(route.dataCoverage.scheduleConfidence == .official
                            ? DataConfidence.official.label
                            : DataConfidence.mapKit.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        confidenceBadge
                    }
                }

                routeLinePills

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

                ServiceStatusBanner(status: route.serviceStatus, compact: true)

                if let comfort, comfort.hasSignal {
                    Label(comfort.summaryTitle, systemImage: comfort.level.iconName)
                        .font(.caption)
                        .foregroundStyle(comfort.level.uiColor)
                }

                if let departurePlan {
                    Label(departurePlan.leaveByHeadline, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private var routeLinePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(route.segments.enumerated()), id: \.element.id) { idx, segment in
                    pillItem(for: segment, at: idx)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func pillItem(for segment: RouteSegment, at idx: Int) -> some View {
        let prev: RouteSegment? = idx > 0 ? route.segments[idx - 1] : nil
        switch segment.type {
        case .transfer:
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                Text(AppLocalization.localized("Transfer"))
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12), in: Capsule())

        case .walking:
            HStack(spacing: 4) {
                if let prev, prev.type != .transfer {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "figure.walk")
                        .font(.caption2)
                    Text(AppLocalization.distance(segment.distance))
                        .font(.caption2)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(.systemGray5), in: Capsule())
                .foregroundStyle(.secondary)
            }

        case .subway, .transit:
            HStack(spacing: 4) {
                if let prev, prev.type == .walking {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                let color = Color(hex: segment.lineColorHex ?? "#007AFF")
                HStack(spacing: 5) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(segment.lineName ?? AppLocalization.localized("Transit"))
                        .font(.caption)
                        .fontWeight(.semibold)
                    if segment.stops > 0 {
                        Text(AppLocalization.stops(segment.stops))
                            .font(.caption2)
                            .foregroundStyle(color.opacity(0.7))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.14), in: Capsule())
                .foregroundStyle(color)
            }
        }
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
