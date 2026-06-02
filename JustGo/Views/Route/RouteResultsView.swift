import SwiftUI

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    @Environment(DIContainer.self) private var container
    @Environment(AccessibilityReportService.self) private var accessibilityReportService
    @Environment(TripMemoryService.self) private var tripMemoryService
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
                RouteCard(
                    route: route,
                    feasibility: container.routeFeasibilityService.feasibility(
                        for: route,
                        personalReports: accessibilityReportService.reports(affecting: route)
                    )
                ) {
                    _ = tripMemoryService.recordPlannedTrip(
                        route: route,
                        cityID: viewModel.selectedCity?.id ?? "",
                        accessibilityFilter: viewModel.accessibilityFilter
                    )
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
    let feasibility: RouteFeasibility
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

                    feasibilityBadge
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
                let explanations = Array(feasibility.allExplanations.prefix(2))
                if !explanations.isEmpty {
                    ForEach(explanations, id: \.self) { explanation in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(feasibility.level.warningColor)
                            Text(explanation)
                                .font(.caption)
                                .foregroundStyle(feasibility.level.warningColor)
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

    private var feasibilityBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: feasibility.level.iconName)
            Text(feasibility.title)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(feasibility.level.color.opacity(0.16), in: Capsule())
        .foregroundStyle(feasibility.level.color)
    }

}

private extension RouteFeasibilityLevel {
    var color: Color {
        switch self {
        case .good:
            return .green
        case .caution:
            return .orange
        case .risky:
            return .red
        case .unknown:
            return .gray
        }
    }

    var warningColor: Color {
        self == .risky ? .red : .orange
    }

    var iconName: String {
        switch self {
        case .good:
            return "checkmark.circle.fill"
        case .caution:
            return "exclamationmark.triangle.fill"
        case .risky:
            return "xmark.octagon.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
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
