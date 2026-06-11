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

struct ArrivalCountdown: View {
    let arrival: RealTimeArrival

    var body: some View {
        HStack(spacing: 8) {
            LineColorIndicator(colorHex: arrival.lineColorHex, size: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.lineName)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(AppLocalization.text(english: "to \(arrival.destination)", chinese: "开往 \(arrival.destination)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(arrival.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if arrival.isArriving {
                Text(AppLocalization.localized("Arriving"))
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
        .accessibilityLabel(AppLocalization.text(
            english: "\(arrival.lineName) to \(arrival.destination), \(arrival.formattedArrival)",
            chinese: "\(arrival.lineName) 开往 \(arrival.destination)，\(arrival.formattedArrival)"
        ))
    }
}
