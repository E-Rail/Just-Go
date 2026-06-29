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
        return Group {
            if segment.type == .transfer {
                Button { selectedTransferSegment = segment } label: { rowContent }
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
