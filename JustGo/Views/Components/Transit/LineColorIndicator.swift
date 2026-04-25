import SwiftUI

struct LineColorIndicator: View {
    let colorHex: String
    var size: CGFloat = 10
    var shape: IndicatorShape = .circle

    enum IndicatorShape {
        case circle
        case roundedRectangle
        case capsule
    }

    var body: some View {
        Group {
            switch shape {
            case .circle:
                Circle()
                    .fill(Color(hex: colorHex))
            case .roundedRectangle:
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: colorHex))
            case .capsule:
                Capsule()
                    .fill(Color(hex: colorHex))
            }
        }
        .frame(width: size, height: size)
    }
}

struct TransferIndicator: View {
    let fromLineColor: String
    let toLineColor: String

    var body: some View {
        HStack(spacing: 4) {
            LineColorIndicator(colorHex: fromLineColor, size: 8)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LineColorIndicator(colorHex: toLineColor, size: 8)
        }
    }
}

struct ArrivalCountdown: View {
    let arrival: RealTimeArrival

    var body: some View {
        HStack(spacing: 8) {
            LineColorIndicator(colorHex: arrival.lineColorHex, size: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.lineName)
                    .font(.caption)
                    .fontWeight(.medium)
                Text("to \(arrival.destination)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if arrival.isArriving {
                Text("Arriving")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)
            } else {
                Text(arrival.formattedArrival)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.lineName) to \(arrival.destination), \(arrival.formattedArrival)")
    }
}
