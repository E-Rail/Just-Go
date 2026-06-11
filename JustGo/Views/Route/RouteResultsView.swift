import SwiftUI

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    @Environment(DIContainer.self) private var container
    @Environment(AccessibilityReportService.self) private var accessibilityReportService
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var selectedRouteID: UUID?
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
        .onAppear {
            ensureRouteSelection()
        }
        .onChange(of: viewModel.routes.map(\.id)) {
            ensureRouteSelection()
        }
        .navigationDestination(isPresented: $showRouteDetail) {
            if let route = selectedRoute {
                RouteDetailView(
                    route: route,
                    preference: viewModel.sortStrategy,
                    alternatives: viewModel.routes
                )
            }
        }
    }

    private var sortOptionsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RoutePreference.primary) { strategy in
                        SortChip(
                            title: strategy.title,
                            icon: strategy.icon,
                            isSelected: viewModel.sortStrategy == strategy
                        ) {
                            viewModel.sortStrategy = strategy
                            viewModel.sortRoutes()
                        }
                    }

                    Menu {
                        ForEach(RoutePreference.allCases.filter { !$0.isPrimary }) { strategy in
                            Button {
                                viewModel.sortStrategy = strategy
                                viewModel.sortRoutes()
                            } label: {
                                Label(AppLocalization.localized(strategy.title), systemImage: strategy.icon)
                            }
                        }
                    } label: {
                        Label(
                            viewModel.sortStrategy.isPrimary
                                ? AppLocalization.localized("More")
                                : AppLocalization.localized(viewModel.sortStrategy.title),
                            systemImage: viewModel.sortStrategy.isPrimary ? "ellipsis.circle" : viewModel.sortStrategy.icon
                        )
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(viewModel.sortStrategy.isPrimary ? Color(.systemGray5) : Color.blue)
                        .foregroundStyle(viewModel.sortStrategy.isPrimary ? Color.primary : Color.white)
                        .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var routesSection: some View {
        Section {
            if !viewModel.routes.isEmpty {
                RouteTabs(
                    routes: viewModel.routes,
                    selection: Binding(
                        get: { selectedRouteID ?? viewModel.routes[0].id },
                        set: { selectedRouteID = $0 }
                    )
                )

                if let route = selectedRoute {
                    let feasibility = container.routeFeasibilityService.feasibility(
                        for: route,
                        personalReports: accessibilityReportService.reports(affecting: route)
                    )
                    RouteCard(
                        route: route,
                        confidence: container.routeConfidenceService.confidence(
                            for: route,
                            feasibility: feasibility,
                            preference: viewModel.sortStrategy,
                            alternatives: viewModel.routes
                        )
                    ) {
                        _ = tripMemoryService.recordPlannedTrip(
                            route: route,
                            cityID: viewModel.selectedCity?.id ?? "",
                            accessibilityFilter: viewModel.accessibilityFilter
                        )
                        showRouteDetail = true
                    }
                }
            }
        } header: {
            Text(AppLocalization.localized("Choose a route"))
        }
    }

    private var selectedRoute: Route? {
        guard let selectedRouteID else { return viewModel.routes.first }
        return viewModel.routes.first { $0.id == selectedRouteID } ?? viewModel.routes.first
    }

    private func ensureRouteSelection() {
        guard !viewModel.routes.isEmpty else {
            selectedRouteID = nil
            return
        }
        if !viewModel.routes.contains(where: { $0.id == selectedRouteID }) {
            selectedRouteID = viewModel.routes[0].id
        }
    }
}

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

struct RouteCard: View {
    let route: Route
    let confidence: RouteConfidence
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
                        Text(DataConfidence.mapKit.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    confidenceBadge
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

                Text(confidence.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let warning = confidence.warnings.first {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(confidence.level.color)
                        .lineLimit(2)
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .overlay(alignment: .leading) {
                routeColorAccent
                    .frame(width: 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var routeColorAccent: some View {
        VStack(spacing: 0) {
            let subwaySegments = route.segments.filter { $0.type.isTransit }
            ForEach(subwaySegments) { segment in
                Color(hex: segment.lineColorHex ?? "#007AFF")
            }
            if subwaySegments.isEmpty {
                Color.gray
            }
        }
    }

    private func segmentBar(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Color.gray
            case .subway, .transit:
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

    private var confidenceBadge: some View {
        VStack(spacing: 2) {
            Image(systemName: confidence.level.iconName)
            Text("\(confidence.score)")
                .fontWeight(.semibold)
            Text(confidence.level.title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption)
        .frame(minWidth: 74)
        .padding(.vertical, 6)
        .foregroundStyle(confidence.level.color)
        .accessibilityLabel("\(confidence.level.title), \(confidence.score) \(AppLocalization.localized("out of 100"))")
    }

}

private extension RouteConfidenceLevel {
    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    var iconName: String {
        switch self {
        case .high: return "checkmark.seal.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "xmark.octagon.fill"
        }
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
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel(AppLocalization.localized("Transfer"))
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
