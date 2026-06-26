import SwiftUI

struct RouteStationTimeline: View {
    let stops: [RouteStationStop]

    var body: some View {
        if !stops.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    let lineColor = Color(hex: stop.lineColorHex ?? "#007AFF")
                    let isLast = index == stops.count - 1
                    HStack(alignment: .top, spacing: 10) {
                        // Left rail: fixed circle on top, flexible connector below.
                        // The connector uses maxHeight: .infinity so it stretches to the
                        // full row height — which is driven by the text column (definite
                        // height via .padding, NOT a Spacer, so the row never collapses).
                        VStack(spacing: 0) {
                            Circle()
                                // Fill with the card surface (adaptive light/dark) so the dot
                                // reads as a hollow ring in both modes — Color(.systemBackground)
                                // would be black on the dark-green card in dark mode.
                                .fill(Color.appSurface)
                                .frame(width: 10, height: 10)
                                .overlay { Circle().stroke(lineColor, lineWidth: 2.5) }
                            if !isLast {
                                Rectangle()
                                    .fill(lineColor)
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
                        }
                        .padding(.bottom, isLast ? 0 : 14)

                        Spacer()
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}
