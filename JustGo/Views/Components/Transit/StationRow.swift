import SwiftUI

struct StationRow: View {
    let station: Station
    var showDistance: Bool = false
    var distance: Double?
    var action: (() -> Void)?

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: 12) {
                lineIndicators

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(station.name)
                            .font(.body)
                            .fontWeight(.medium)

                        if station.isTransferStation {
                            Text("Transfer")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }

                    if let en = station.nameEn {
                        Text(en)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    accessibilityBadges
                }

                Spacer()

                if showDistance, let distance = distance {
                    Text(formatDistance(distance))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(station.accessibilityLabel)
    }

    private var lineIndicators: some View {
        VStack(spacing: 2) {
            ForEach(station.lines.prefix(3)) { line in
                Circle()
                    .fill(Color(hex: line.colorHex))
                    .frame(width: 10, height: 10)
            }
        }
    }

    private var accessibilityBadges: some View {
        HStack(spacing: 8) {
            if station.accessibility?.hasElevator == true {
                AccessibilityIcon(icon: "arrow.up.arrow.down.circle.fill", label: "Elevator")
            }
            if station.accessibility?.hasWheelchairRamp == true {
                AccessibilityIcon(icon: "figure.roll", label: "Wheelchair")
            }
            if station.accessibility?.hasTactilePath == true {
                AccessibilityIcon(icon: "hand.raised.fill", label: "Tactile")
            }
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        } else {
            return String(format: "%.1fkm", meters / 1000)
        }
    }
}

struct AccessibilityIcon: View {
    let icon: String
    let label: String

    var body: some View {
        Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(.green)
            .accessibilityLabel(label)
    }
}
