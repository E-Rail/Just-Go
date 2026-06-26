import SwiftUI

struct RouteStationTimeline: View {
    let stops: [RouteStationStop]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: 10, height: 10)
                            .overlay {
                                Circle()
                                    .stroke(Color(hex: stop.lineColorHex ?? "#007AFF"), lineWidth: 2.5)
                            }

                        if index < stops.count - 1 {
                            Rectangle()
                                .fill(Color(hex: stop.lineColorHex ?? "#007AFF"))
                                .frame(width: 3)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name)
                            .font(.subheadline)
                            .fontWeight(index == 0 || index == stops.count - 1 ? .semibold : .regular)
                        HStack(spacing: 6) {
                            if let lineColor = stop.lineColorHex {
                                LineColorIndicator(colorHex: lineColor, size: 8)
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
                        if index < stops.count - 1 {
                            Spacer(minLength: 8)
                        }
                    }

                    Spacer()
                }
            }
        }
        .padding(.top, 4)
    }
}
