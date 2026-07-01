import SwiftUI

struct RouteStationTimeline: View {
    let stops: [RouteStationStop]
    /// When provided, each station row becomes tappable (with a chevron affordance) and invokes
    /// this with the tapped stop. When nil, rows render as plain non-interactive layout.
    var onStationTap: ((RouteStationStop) -> Void)? = nil

    var body: some View {
        if !stops.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    let isLast = index == stops.count - 1
                    let rail = TimelineRail.info(for: stops, at: index)
                    if let onStationTap {
                        Button { onStationTap(stop) } label: {
                            row(stop: stop, index: index, rail: rail, isLast: isLast, tappable: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        row(stop: stop, index: index, rail: rail, isLast: isLast, tappable: false)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func row(stop: RouteStationStop, index: Int, rail: TimelineRail.Info, isLast: Bool, tappable: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Left rail: fixed circle on top, flexible connector below.
            // The connector uses maxHeight: .infinity so it stretches to the
            // full row height — which is driven by the text column (definite
            // height via .padding, NOT a Spacer, so the row never collapses).
            VStack(spacing: 0) {
                if rail.isRouteTransfer {
                    transferMarker
                } else {
                    Circle()
                        // Fill with the card surface (adaptive light/dark) so the dot
                        // reads as a hollow ring in both modes — Color(.systemBackground)
                        // would be black on the dark-green card in dark mode.
                        .fill(Color.appSurface)
                        .frame(width: 10, height: 10)
                        .overlay { Circle().stroke(rail.stopColor, lineWidth: 2.5) }
                }
                if !isLast {
                    // Colored by the OUTGOING line (the one carrying the rider to the next
                    // stop), not this stop's own line — see TimelineRail's doc comment.
                    Rectangle()
                        .fill(rail.outgoingColor)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.subheadline)
                    .fontWeight(index == 0 || isLast ? .semibold : .regular)
                HStack(spacing: 6) {
                    if let colorHex = stop.lineColorHex {
                        LineColorIndicator(colorHex: colorHex, size: 8)
                    }
                    if let lineName = stop.lineName {
                        Text(lineName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let arrivalTimeText = stop.arrivalTimeText {
                        Text(arrivalTimeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if rail.isRouteTransfer, let outgoingLineName = rail.outgoingLineName {
                    Label(
                        AppLocalization.text(
                            english: "Transfer to \(outgoingLineName)",
                            simplified: "换乘\(outgoingLineName)",
                            traditional: "換乘\(outgoingLineName)"
                        ),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption2)
                    .foregroundStyle(rail.outgoingColor)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)

            Spacer()

            if tappable {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
    }

    /// Marks the exact station where the rider must change lines — a filled orange badge
    /// with the transfer glyph, replacing the plain ring dot used at pass-through stops.
    private var transferMarker: some View {
        ZStack {
            Circle().fill(Color.orange)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 16, height: 16)
        .overlay { Circle().stroke(Color.appSurface, lineWidth: 2) }
        .accessibilityLabel(AppLocalization.text(english: "Transfer station", simplified: "换乘站", traditional: "換乘站"))
    }
}

/// Single source of truth for station-timeline rail colors and transfer markers.
///
/// A station stop's own `lineColorHex` is the line that carried the rider TO that stop —
/// at a transfer station that's the arriving line, not the one departing toward the next
/// stop. Coloring the connector below a stop with the stop's own color (instead of the
/// next stop's) draws the old line all the way past the transfer point. Every timeline
/// row must go through `info(for:at:)` rather than reading `stop.lineColorHex` directly
/// for its outgoing connector, so this class of bug can't be reintroduced piecemeal.
private enum TimelineRail {
    struct Info {
        let stopColor: Color
        let outgoingColor: Color
        let isRouteTransfer: Bool
        let outgoingLineName: String?
    }

    static func info(for stops: [RouteStationStop], at index: Int) -> Info {
        let stop = stops[index]
        let stopColor = color(stop.lineColorHex)
        let nextIndex = index + 1
        guard stops.indices.contains(nextIndex) else {
            return Info(stopColor: stopColor, outgoingColor: stopColor, isRouteTransfer: false, outgoingLineName: nil)
        }
        let next = stops[nextIndex]
        let outgoingColor = color(next.lineColorHex ?? stop.lineColorHex)
        let isRouteTransfer = stop.lineName != nil && next.lineName != nil && stop.lineName != next.lineName
        return Info(
            stopColor: stopColor,
            outgoingColor: outgoingColor,
            isRouteTransfer: isRouteTransfer,
            outgoingLineName: isRouteTransfer ? next.lineName : nil
        )
    }

    private static func color(_ hex: String?) -> Color {
        Color.adaptive(hex: hex ?? "#007AFF")
    }
}
