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
                HStack(alignment: .top) {
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

                routeSegmentRows

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
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Segment Rows

    private var routeSegmentRows: some View {
        VStack(spacing: 6) {
            ForEach(route.segments) { segment in
                if segment.type != .transfer {
                    segmentRow(segment)
                }
            }
        }
    }

    private func segmentRow(_ segment: RouteSegment) -> some View {
        HStack(spacing: 12) {
            badgeCircle(for: segment)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.summaryLabel)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(segmentDetail(segment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.appSurfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func badgeCircle(for segment: RouteSegment) -> some View {
        switch segment.type {
        case .walking:
            ZStack {
                Circle().fill(Color(.systemGray3))
                Image(systemName: "figure.walk")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        case .subway, .transit:
            let color = Color(hex: segment.lineColorHex ?? "#007AFF")
            ZStack {
                Circle().fill(color)
                Text(lineShortCode(from: segment.lineName))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        case .transfer:
            ZStack {
                Circle().fill(Color.orange)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func lineShortCode(from name: String?) -> String {
        guard let name else { return "?" }
        let nums = name.filter(\.isNumber)
        if !nums.isEmpty { return String(nums.prefix(2)) }
        let letters = name.filter { $0.isLetter && $0.isASCII }
        let code = String(letters.prefix(2)).uppercased()
        return code.isEmpty ? "?" : code
    }

    private func segmentDetail(_ segment: RouteSegment) -> String {
        switch segment.type {
        case .walking:
            return "\(segment.formattedDuration) • \(AppLocalization.distance(segment.distance))"
        case .subway, .transit:
            return segment.formattedDuration
        case .transfer:
            return ""
        }
    }

    // MARK: - Other views

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
