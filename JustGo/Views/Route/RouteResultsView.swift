import SwiftUI

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    @Environment(DIContainer.self) private var container
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
        .listStyle(.plain)
        .background(Color.appBackground)
        .navigationTitle(AppLocalization.localized("Routes"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureRouteSelection()
        }
        .onChange(of: routeSelectionSignature) {
            ensureRouteSelection()
        }
        .navigationDestination(isPresented: $showRouteDetail) {
            if let route = selectedRoute {
                RouteDetailView(
                    route: route,
                    preference: viewModel.sortStrategy,
                    alternatives: viewModel.routes,
                    tripAnchor: viewModel.tripAnchor,
                    accessibilityFilter: viewModel.accessibilityFilter
                )
            }
        }
    }

    private var activeTimeChip: some View {
        Group {
            switch viewModel.tripAnchor {
            case .departBy(let date):
                timeChip(
                    label: AppLocalization.text(
                        english: "Departing \(date.formatted(.dateTime.hour().minute()))",
                        simplified: "\(date.formatted(.dateTime.hour().minute()))出发",
                        traditional: "\(date.formatted(.dateTime.hour().minute()))出發"
                    )
                )
            case .arriveBy(let date):
                timeChip(
                    label: AppLocalization.text(
                        english: "Arriving by \(date.formatted(.dateTime.hour().minute()))",
                        simplified: "\(date.formatted(.dateTime.hour().minute()))前到达",
                        traditional: "\(date.formatted(.dateTime.hour().minute()))前到達"
                    )
                )
            case .now:
                EmptyView()
            }
        }
    }

    private func timeChip(label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
            Button {
                // Re-plan rather than re-sort: serviceStatus (and its last-train warnings)
                // was enriched for the explicit anchor at plan time, so keeping the old
                // routes would keep stale warnings under a chip that now says "now". The
                // list already renders isLoading/errorMessage during the re-search.
                viewModel.tripAnchor = .now
                Task { await viewModel.searchRoutes() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor, in: Capsule())
        .foregroundStyle(.white)
    }

    private var sortOptionsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if viewModel.tripAnchor.isExplicit {
                        activeTimeChip
                    }
                    ForEach(RoutePreference.primary) { strategy in
                        SortChip(
                            title: strategy.title,
                            icon: strategy.icon,
                            isSelected: viewModel.sortStrategy == strategy
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.sortStrategy = strategy
                                viewModel.sortRoutes()
                            }
                        }
                    }

                    Menu {
                        ForEach(RoutePreference.allCases.filter { !$0.isPrimary }) { strategy in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.sortStrategy = strategy
                                    viewModel.sortRoutes()
                                }
                            } label: {
                                Label(strategy.title, systemImage: strategy.icon)
                            }
                        }
                    } label: {
                        Label(
                            viewModel.sortStrategy.isPrimary
                                ? AppLocalization.localized("More")
                                : viewModel.sortStrategy.title,
                            systemImage: viewModel.sortStrategy.isPrimary ? "ellipsis.circle" : viewModel.sortStrategy.icon
                        )
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(viewModel.sortStrategy.isPrimary ? Color(.systemGray5) : Color.accentColor)
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
            ForEach(Array(viewModel.routes.enumerated()), id: \.element.id) { index, route in
                comparisonRow(route, rank: index + 1)
            }
        } header: {
            Text(viewModel.routes.count == 1
                ? AppLocalization.text(english: "1 route found", simplified: "找到 1 条路线", traditional: "找到 1 條路線")
                : AppLocalization.text(
                    english: "\(viewModel.routes.count) routes found",
                    simplified: "找到 \(viewModel.routes.count) 条路线",
                    traditional: "找到 \(viewModel.routes.count) 條路線"
                ))
        }
    }

    /// One comparison row per alternative — duration, walking, transfer effort, exit confidence,
    /// and a cross-route "best for" reason. Tapping records the planned trip and opens the detail.
    private func comparisonRow(_ route: Route, rank: Int) -> some View {
        let metrics = comparisonMetrics(for: route, rank: rank)
        let isSelected = route.id == (selectedRouteID ?? viewModel.routes.first?.id)
        return Button {
            selectedRouteID = route.id
            _ = tripMemoryService.recordPlannedTrip(
                route: route,
                cityID: route.networkCityID ?? viewModel.selectedCity?.id ?? "",
                accessibilityFilter: viewModel.accessibilityFilter
            )
            showRouteDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AppLocalization.text(
                        english: "Route \(metrics.rank)",
                        simplified: "路线 \(metrics.rank)",
                        traditional: "路線 \(metrics.rank)"
                    ))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    if let line = route.boardingTransitSegment?.lineName {
                        LineColorIndicator(colorHex: route.boardingTransitSegment?.lineColorHex ?? "#007AFF", size: 8)
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(metrics.durationText)
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        resultMetricChip(metrics.walkingText, icon: "figure.walk")
                        resultMetricChip(metrics.transferEffort, icon: "arrow.triangle.2.circlepath")
                        DataConfidenceChip(confidence: metrics.exitConfidence, compact: true)
                        Text(metrics.bestForReason)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func resultMetricChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.systemGray6), in: Capsule())
    }

    private func comparisonMetrics(for route: Route, rank: Int) -> RouteComparisonMetrics {
        RouteComparisonMetrics(
            id: route.id,
            rank: rank,
            durationText: route.formattedDuration,
            transferText: route.formattedTransfers,
            walkingText: route.formattedWalkingDistance,
            transferEffort: transferEffort(for: route),
            exitConfidence: exitConfidence(for: route),
            bestForReason: bestForReason(for: route, in: viewModel.routes)
        )
    }

    private func transferEffort(for route: Route) -> String {
        if route.transferCount == 0 {
            return AppLocalization.text(english: "Direct", simplified: "直达", traditional: "直達")
        }
        let minutes = route.transferWalkingMinutes
        if minutes > 0 {
            return "\(route.formattedTransfers) · \(AppLocalization.minutes(Int(minutes)))"
        }
        return route.formattedTransfers
    }

    private func exitConfidence(for route: Route) -> DataConfidence {
        route.arrivalGuidance?.confidence ?? .unknown
    }

    /// The single most salient reason this route leads its alternatives.
    private func bestForReason(for route: Route, in routes: [Route]) -> String {
        guard routes.count > 1 else {
            return AppLocalization.text(english: "Recommended", simplified: "推荐", traditional: "推薦")
        }
        if route.totalDuration == routes.map(\.totalDuration).min() {
            return AppLocalization.localized("Fastest")
        }
        if route.transferCount == routes.map(\.transferCount).min() {
            return AppLocalization.text(english: "Fewest transfers", simplified: "换乘最少", traditional: "換乘最少")
        }
        if route.walkingDistance == routes.map(\.walkingDistance).min() {
            return AppLocalization.text(english: "Least walking", simplified: "步行最少", traditional: "步行最少")
        }
        if route.stepFreeAssessment == .confirmed {
            return AppLocalization.text(english: "Most accessible", simplified: "最无障碍", traditional: "最無障礙")
        }
        return AppLocalization.text(english: "Balanced", simplified: "均衡", traditional: "均衡")
    }

    private var selectedRoute: Route? {
        guard let selectedRouteID else { return viewModel.routes.first }
        return viewModel.routes.first { $0.id == selectedRouteID } ?? viewModel.routes.first
    }

    private var routeSelectionSignature: String {
        viewModel.routes.map(\.id.uuidString).joined(separator: "|")
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
