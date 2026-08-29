import SwiftUI

struct RouteTabs: View {
    let routes: [Route]
    @Binding var selection: UUID
    /// Drawn over the map rather than on a page background. `Color.appSurface` and a 15% accent
    /// tint are both partly transparent, which is fine against a solid page and unreadable against
    /// moving cartography, so the floating form swaps in a material and an opaque selected fill.
    var floating = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                    Button {
                        selection = route.id
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(route.formattedDuration)
                                .font(floating ? .title3 : .subheadline)
                                .fontWeight(selection == route.id ? .semibold : .regular)
                                .lineLimit(1)

                            routeColorBar(route)
                                .frame(height: 3)
                                .clipShape(Capsule())

                            // Only on the floating card, which is the one a rider compares
                            // alternatives on. The inline row sits under a list that already
                            // says this.
                            if floating {
                                Text(route.formattedTransfers)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(minWidth: floating ? 104 : 0, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, floating ? 11 : 9)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                            if floating {
                                shape.fill(.regularMaterial)
                                    .overlay(shape.fill(
                                        selection == route.id
                                            ? Color.accentColor.opacity(0.22)
                                            : Color.clear
                                    ))
                                    .elevated(.floating)
                            } else {
                                shape.fill(
                                    selection == route.id ? Color.accentColor.opacity(0.15) : Color.appSurface
                                )
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
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
            .padding(.horizontal, floating ? 12 : 0)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                Text(title)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            // Tinted rather than filled. `Color.accentColor` is the theme lightened for *foreground*
            // legibility in dark mode, so using it as a fill under white text collapses the contrast
            // it exists to protect: the selected chip was pale green with white text on it.
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.appSurface, in: Capsule())
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .overlay(Capsule().stroke(isSelected ? Color.accentColor.opacity(0.55) : Color(.separator), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
