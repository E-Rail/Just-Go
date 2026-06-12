import SwiftUI

struct RouteTabs: View {
    let routes: [Route]
    @Binding var selection: UUID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                    Button {
                        selection = route.id
                    } label: {
                        VStack(spacing: 7) {
                            Text(AppLocalization.text(
                                english: "Route \(index + 1) · \(route.formattedDuration)",
                                chinese: "路线 \(index + 1) · \(route.formattedDuration)"
                            ))
                            .font(.subheadline)
                            .fontWeight(selection == route.id ? .semibold : .regular)
                            .lineLimit(1)

                            routeColorBar(route)
                                .frame(height: 3)
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            selection == route.id ? Color.accentColor.opacity(0.12) : Color(.systemGray6),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selection == route.id ? Color.accentColor : .clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLocalization.text(
                        english: "Route \(index + 1), \(route.formattedDuration), \(route.formattedTransfers)",
                        chinese: "路线 \(index + 1)，\(route.formattedDuration)，\(route.formattedTransfers)"
                    ))
                    .accessibilityAddTraits(selection == route.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func routeColorBar(_ route: Route) -> some View {
        HStack(spacing: 1) {
            let subwaySegments = route.segments.filter { $0.type.isTransit }
            ForEach(subwaySegments) { segment in
                Color(hex: segment.lineColorHex ?? "#007AFF")
                    .frame(minWidth: 20)
            }
            if subwaySegments.isEmpty {
                Color.gray.frame(minWidth: 20)
            }
        }
    }
}

struct SortChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(AppLocalization.localized(title))
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
