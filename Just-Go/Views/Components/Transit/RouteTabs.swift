import SwiftUI

/// The alternatives over the route map, one tab each, in the map's own chrome: `Color.appSurface`
/// and a plain accent tint are partly transparent and unreadable over cartography, so a tab is
/// floating chrome, washed with the accent when selected.
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
                        VStack(alignment: .leading, spacing: 6) {
                            Text(route.formattedDuration)
                                .font(.title3)
                                .fontWeight(selection == route.id ? .semibold : .regular)
                                .lineLimit(1)

                            routeColorBar(route)
                                .frame(height: 3)
                                .clipShape(Capsule())

                            // A rider comparing alternatives compares changes too.
                            Text(route.formattedTransfers)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 104, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        // Not interactive glass: its press response grows past the 2 points the
                        // scroll view leaves above and below and is cut off. The button's own
                        // press dimming is the response.
                        .floatingChrome(
                            minimumRadius: Radius.medium,
                            tint: selection == route.id ? Color.accentColor.opacity(0.3) : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLocalization.text(
                        english: "Route \(index + 1), \(route.formattedDuration), \(route.formattedTransfers)",
                        simplified: "路线 \(index + 1)，\(route.formattedDuration)，\(route.formattedTransfers)",
                        traditional: "路線 \(index + 1)，\(route.formattedDuration)，\(route.formattedTransfers)"
                    ))
                    .accessibilityAddTraits(selection == route.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func routeColorBar(_ route: Route) -> some View {
        HStack(spacing: 1) {
            ForEach(route.segments.filter { $0.type != .transfer }) { segment in
                Color(hex: segment.colorHex)
                    .frame(minWidth: 20)
            }
        }
    }
}

/// A capsule that is on or off: the results' sort order and the search page's station filters.
/// Tinted rather than filled when on: `Color.accentColor` is lightened for foreground use in dark
/// mode, and as a fill under white text it measured 2.6:1.
struct Chip: View {
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
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.appSurface, in: Capsule())
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .overlay(Capsule().stroke(isSelected ? Color.accentColor.opacity(0.55) : Color(.separator), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
