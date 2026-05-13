import SwiftUI

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    @State private var selectedRoute: Route?
    @State private var showRouteDetail = false

    var body: some View {
        List {
            sortOptionsSection

            if viewModel.isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(AppLocalization.localized("Finding routes..."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    Spacer()
                }
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView {
                    Label(AppLocalization.localized("No Routes Found"), systemImage: "map")
                } description: {
                    Text(error)
                }
            } else {
                routesSection
            }
        }
        .navigationTitle(AppLocalization.localized("Routes"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showRouteDetail) {
            if let route = selectedRoute {
                RouteDetailView(route: route)
            }
        }
    }

    private var sortOptionsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RouteSortStrategy.allCases) { strategy in
                        SortChip(
                            title: strategy.title,
                            icon: strategy.icon,
                            isSelected: viewModel.sortStrategy == strategy
                        ) {
                            viewModel.sortStrategy = strategy
                            viewModel.sortRoutes()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var routesSection: some View {
        Section {
            ForEach(viewModel.routes) { route in
                RouteCard(route: route) {
                    selectedRoute = route
                    showRouteDetail = true
                }
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

struct RouteCard: View {
    let route: Route
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.formattedDuration)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("\(route.strategy.localizedName) • \(route.formattedWalkingDistance)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if route.isFullyAccessible {
                        HStack(spacing: 4) {
                            Image(systemName: "figure.roll")
                            Text(AppLocalization.localized("Accessible"))
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                    }
                }

                // Route segments preview
                HStack(spacing: 2) {
                    ForEach(route.segments) { segment in
                        segmentBar(segment)
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())

                RouteStationTimeline(stops: route.stationTimelineStops)

                if let originGuide = route.originAccessGuide,
                   let destinationGuide = route.destinationAccessGuide {
                    VStack(alignment: .leading, spacing: 6) {
                        accessPreviewRow(guide: originGuide, icon: "arrow.down.forward.circle")
                        accessPreviewRow(guide: destinationGuide, icon: "arrow.up.forward.circle")
                    }
                }

                // Warnings
                if !route.warnings.isEmpty {
                    ForEach(route.warnings) { warning in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func segmentBar(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Color.gray
            case .subway:
                Color(hex: segment.lineColorHex ?? "#000000")
            case .transfer:
                Color.orange
            }
        }
        .frame(minWidth: segment.type == .walking ? 20 : 40)
    }

    private func accessPreviewRow(guide: RouteAccessGuide, icon: String) -> some View {
        Label {
            Text(guide.primaryInstruction)
                .font(.caption)
                .lineLimit(2)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(.secondary)
    }

}

struct RouteStationTimeline: View {
    let stops: [RouteStationStop]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: stop.isTransfer ? 14 : 10, height: stop.isTransfer ? 14 : 10)
                            .overlay {
                                Circle()
                                    .stroke(Color(hex: stop.lineColorHex ?? "#007AFF"), lineWidth: stop.isTransfer ? 4 : 3)
                            }

                        if index < stops.count - 1 {
                            Rectangle()
                                .fill(Color(hex: stop.lineColorHex ?? "#007AFF"))
                                .frame(width: 4, height: 22)
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
                            if stop.isTransfer {
                                Text(AppLocalization.localized("Transfer"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if let arrivalTimeText = stop.arrivalTimeText {
                                Text(arrivalTimeText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }
}
