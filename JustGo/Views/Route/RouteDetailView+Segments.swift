import SwiftUI

extension RouteDetailView {
    func routeFeasibilityCard(_ feasibility: RouteFeasibility) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(feasibility.title, systemImage: feasibility.level.iconName)
                        .font(.headline)
                        .foregroundStyle(feasibility.level.color)
                    Spacer()
                    if feasibility.estimatedExtraMinutes > 0 {
                        Text(AppLocalization.text(
                            english: "+\(feasibility.estimatedExtraMinutes) min possible",
                            chinese: "可能增加\(feasibility.estimatedExtraMinutes)分钟"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let bottleneck = feasibility.bottleneck {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppLocalization.localized("Bottleneck"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("\(bottleneck.segmentTitle): \(bottleneck.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(feasibility.allExplanations.prefix(4), id: \.self) { explanation in
                    Label(explanation, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if feasibility.allExplanations.isEmpty {
                    Text(AppLocalization.localized("No accessibility concerns found from available data."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    var tripEssentialsCard: some View {
        let boarding = route.boardingGuidance
        let arrival = route.arrivalGuidance
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.text(english: "Trip Essentials", simplified: "出行要点", traditional: "出行要點"))
                    .font(.headline)

                essentialRow(
                    icon: "arrow.down.forward.circle.fill",
                    title: AppLocalization.text(english: "Enter", simplified: "进站", traditional: "進站"),
                    detail: accessSummary(route.originAccessGuide),
                    confidence: boarding?.confidence
                )
                Divider()
                essentialRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: AppLocalization.text(english: "Transfer", simplified: "换乘", traditional: "換乘"),
                    detail: transferEssentialDetail,
                    confidence: nil
                )
                Divider()
                essentialRow(
                    icon: "arrow.up.forward.circle.fill",
                    title: AppLocalization.text(english: "Exit", simplified: "出站", traditional: "出站"),
                    detail: accessSummary(route.destinationAccessGuide),
                    confidence: arrival?.confidence
                )
                Divider()
                essentialRow(
                    icon: "bell",
                    title: AppLocalization.text(english: "Alert", simplified: "提醒", traditional: "提醒"),
                    detail: AppLocalization.text(
                        english: "Arrival reminder available in step-by-step navigation",
                        simplified: "分步导航中可设置到站提醒",
                        traditional: "分步導航中可設定到站提醒"
                    ),
                    confidence: nil
                )
            }
        }
    }

    private func essentialRow(icon: String, title: String, detail: String, confidence: DataConfidence?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    if let confidence, confidence != .unknown {
                        DataConfidenceChip(confidence: confidence, compact: true)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Station name plus a specific exit/entrance when one is known; just the station otherwise.
    private func accessSummary(_ guide: RouteAccessGuide?) -> String {
        guard let guide else { return AppLocalization.localized("Not available") }
        if let point = guide.accessPoint, point.source != .stationPOI {
            return "\(guide.stationName) · \(point.name)"
        }
        return guide.stationName
    }

    private var transferEssentialDetail: String {
        if route.transferCount == 0 {
            return AppLocalization.text(english: "Direct — no transfers", simplified: "直达，无需换乘", traditional: "直達，無需換乘")
        }
        let minutes = route.transferWalkingMinutes
        let base = AppLocalization.transfers(route.transferCount)
        if minutes > 0 {
            return "\(base) · \(AppLocalization.minutes(Int(minutes)))"
        }
        return base
    }

    /// Maps an access-point source to a confidence label for the access guidance card.
    /// Returns nil for the generic placeholder so the chip is hidden when no specific exit exists.
    func accessConfidence(for guide: RouteAccessGuide) -> DataConfidence? {
        guard let source = guide.accessPoint?.source else { return nil }
        switch source {
        case .specificEntrance, .localStationData: return .official
        case .inferred, .mapKit: return .estimated
        case .stationPOI, .routeBoundary: return nil
        }
    }

    @ViewBuilder
    var accessGuidanceCard: some View {
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
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 26)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(guide.title)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        if let confidence = accessConfidence(for: guide) {
                                            DataConfidenceChip(confidence: confidence, compact: true)
                                        }
                                    }
                                    Text(guide.primaryInstruction)
                                        .font(.subheadline)
                                    Text(guide.formattedWalk)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(guide.accessibilityNotes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }

                            if let firstStep = guide.walkingSteps.first,
                               !firstStep.instruction.isEmpty {
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

    var segmentsTimeline: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppLocalization.localized("Route Steps"))
                    .font(.headline)

                ForEach(Array(route.segments.enumerated()), id: \.element.id) { index, segment in
                    segmentTimelineRow(segment, isLast: index == route.segments.count - 1)
                }
            }
        }
    }

    private func segmentTimelineRow(_ segment: RouteSegment, isLast: Bool) -> some View {
        let rowContent = HStack(alignment: .top, spacing: 12) {
            VStack {
                segmentIcon(segment)
                if !isLast {
                    Rectangle()
                        .fill(segmentColor(segment).opacity(0.65))
                        .frame(width: 2, height: 20)
                }
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

                if segment.duration >= 60 {
                    Text(segment.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let firstDirection = segment.walkingDirections?.first?.instruction,
                   !firstDirection.isEmpty,
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
                    .foregroundStyle(Color.accentColor)
                }
            }

            Spacer()

            if segment.type == .transfer {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // A plain-style Button only hit-tests its label's content — the Spacer and padding
        // between the short text and the chevron were dead zones covering most of the row.
        .contentShape(Rectangle())
        return Group {
            if segment.type == .transfer {
                Button { detailDestination = .transfer(segment) } label: { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private func segmentIcon(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Image(systemName: "figure.walk")
                    .foregroundStyle(segmentColor(segment))
                    .padding(6)
                    .background(Color.gray.opacity(0.2), in: Circle())
            case .subway, .transit:
                Image(systemName: "tram.fill")
                    .foregroundStyle(segmentColor(segment))
                    .padding(6)
                    .background(Color(hex: segment.lineColorHex ?? "#000000").opacity(0.2), in: Circle())
            case .transfer:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(segmentColor(segment))
                    .padding(6)
                    .background(Color.orange.opacity(0.2), in: Circle())
            }
        }
    }

    private func segmentColor(_ segment: RouteSegment) -> Color {
        switch segment.type {
        case .walking:
            return .gray
        case .subway, .transit:
            return Color.adaptive(hex: segment.lineColorHex ?? "#007AFF")
        case .transfer:
            return .orange
        }
    }
}

extension RouteFeasibilityLevel {
    var color: Color {
        switch self {
        case .good:
            return .green
        case .caution:
            return .orange
        case .risky:
            return .red
        case .unknown:
            return .gray
        }
    }

    var iconName: String {
        switch self {
        case .good:
            return "checkmark.circle.fill"
        case .caution:
            return "exclamationmark.triangle.fill"
        case .risky:
            return "xmark.octagon.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}
