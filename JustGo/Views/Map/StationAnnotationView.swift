import SwiftUI

struct StationAnnotationView: View {
    let station: Station

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(station.isTransferStation ? Color.orange : Color.blue)
                    .frame(width: 24, height: 24)

                if station.accessibility?.hasElevator == true {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
            }

            Text(station.name)
                .font(.caption2)
                .fontWeight(.medium)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(station.accessibilityLabel)
    }
}

extension Station {
    var accessibilityLabel: String {
        var label = name
        if let en = nameEn { label += ", \(en)" }
        if isTransferStation { label += ", transfer station" }
        if accessibility?.hasElevator == true { label += ", has elevator" }
        if accessibility?.isFullyAccessible == true { label += ", fully accessible" }
        return label
    }
}
