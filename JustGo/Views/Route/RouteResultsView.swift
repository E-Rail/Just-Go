import SwiftUI

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    /// Pushing is the map stack's job, not this screen's — it owns the whole plan → results →
    /// detail chain, so a route chosen here is handed back rather than presented from inside.
    let onSelect: (Route) -> Void
    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var selectedRouteID: UUID?
    // Raw theme hex for the solid-fill chip below — see RouteEntryView's identical
    // declaration for why `Color.accentColor` (dark-mode-lightened for foreground use)
    // isn't used as a fill under white text.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue

    var body: some View {
        List {
            Group {
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
                } else if viewModel.routes.isEmpty {
                    // Reachable even though the entry page only pushes on a successful search: a
                    // city change while this screen is up clears the routes underneath it, and the
                    // result was a completely blank page with no explanation and nothing to do.
                    ContentUnavailableView {
                        Label(AppLocalization.localized("No Routes Found"), systemImage: "map")
                    } description: {
                        Text(AppLocalization.text(
                            english: "This search is no longer current. Go back and search again.",
                            simplified: "此次搜索已失效，请返回重新搜索。",
                            traditional: "此次搜尋已失效，請返回重新搜尋。"
                        ))
                    }
                } else {
                    routesSection
                }
            }
            .listRowBackground(Color.clear)
            // `.plain` draws a hairline above and below every row, which under the sort chips read
            // as two stray rules floating in the middle of the screen with nothing between them.
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        // Stock spacing put a third of a screen of nothing between the sort chips and the first
        // result — the chips sort the list directly below them and belong next to it.
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(AppLocalization.localized("Routes"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureRouteSelection()
        }
        .onChange(of: routeSelectionSignature) {
            ensureRouteSelection()
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
        .background(Color(hex: selectedThemeHex), in: Capsule())
        .foregroundStyle(.white)
    }

    private var sortOptionsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if viewModel.tripAnchor.isExplicit {
                        activeTimeChip
                    }
                    // The active strategy leads, whether or not it is one of the three that get
                    // their own chip. The default sort is "Transit First", which is *not* primary,
                    // so it rendered only inside the overflow chip at the far right — off the edge
                    // of the screen, leaving a sort row where nothing looked selected.
                    ForEach(sortChipStrategies) { strategy in
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
                        Label(AppLocalization.localized("More"), systemImage: "ellipsis.circle")
                            .font(.caption)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.appSurface, in: Capsule())
                            .foregroundStyle(Color.primary)
                            .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// The three headline strategies, preceded by whatever is actually sorting the list when that
    /// is something else.
    private var sortChipStrategies: [RoutePreference] {
        let primary = RoutePreference.primary
        guard !primary.contains(viewModel.sortStrategy) else { return primary }
        return [viewModel.sortStrategy] + primary
    }

    private var routesSection: some View {
        Section {
            ForEach(viewModel.routes) { route in
                comparisonRow(route)
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

    /// One comparison row per alternative — the lines it rides, how long it takes, when it lands,
    /// and the single thing wrong with it if there is one. Tapping records the planned trip and
    /// opens the detail.
    private func comparisonRow(_ route: Route) -> some View {
        let metrics = comparisonMetrics(for: route)
        let feasibility = container.routeFeasibilityService.feasibility(for: route)
        let confidence = routeConfidence(for: route, feasibility: feasibility)
        return Button {
            selectedRouteID = route.id
            _ = tripMemoryService.recordPlannedTrip(
                route: route,
                cityID: route.networkCityID ?? viewModel.selectedCity?.id ?? "",
                accessibilityFilter: viewModel.accessibilityFilter
            )
            onSelect(route)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Why this route is in the list at all — but only when there is something to
                // compare it against. With a single result it said "Recommended", which is a
                // label for a choice the rider was never offered.
                if viewModel.routes.count > 1 {
                    Text(metrics.bestForReason)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.accentColor)
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        // The lines this route rides, in order, in their own colours. A rider
                        // comparing alternatives is choosing between *shapes* of journey, and three
                        // chips of grey text made every row look the same until you read all of them.
                        JourneyBadgeChain(segments: route.segments)

                        Text(metrics.summaryLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(metrics.durationText)
                            .font(.title2)
                            .fontWeight(.bold)
                            .monospacedDigit()
                        Text(metrics.arrivalText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                // Full width, below everything: sharing a line with the duration column squeezed
                // "Walking-heavy route" into a two-line stub. Only what is wrong, and only in
                // words — this row used to lead with a 50 pt red "38", an unexplained score on a
                // scale the rider had never been shown.
                if let concern = RouteConcern.worst(feasibility: feasibility, confidence: confidence) {
                    Label(concern.title, systemImage: concern.icon)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(concern.tint)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func comparisonMetrics(for route: Route) -> RouteComparisonMetrics {
        let timing = TripTimeContext(anchor: viewModel.tripAnchor, totalDuration: route.totalDuration)
        let arrival = timing.arrivalDate.formatted(.dateTime.hour().minute())
        return RouteComparisonMetrics(
            id: route.id,
            durationText: route.formattedDuration,
            bestForReason: bestForReason(for: route, in: viewModel.routes),
            arrivalText: AppLocalization.text(
                english: "Arrive \(arrival)",
                simplified: "\(arrival) 到达",
                traditional: "\(arrival) 到達"
            ),
            summaryLine: [
                transferEffort(for: route),
                AppLocalization.text(
                    english: "\(route.formattedWalkingDistance) walk",
                    simplified: "步行 \(route.formattedWalkingDistance)",
                    traditional: "步行 \(route.formattedWalkingDistance)"
                )
            ].joined(separator: " · ")
        )
    }

    /// The route's 0-100 confidence, computed from the identical comfort → feasibility →
    /// confidence chain the detail screen uses (all synchronous), so a route flagged here is
    /// flagged the same way after tapping in.
    private func routeConfidence(for route: Route, feasibility: RouteFeasibility) -> RouteConfidence {
        container.routeConfidenceService.confidence(
            for: route,
            feasibility: feasibility,
            preference: viewModel.sortStrategy,
            alternatives: viewModel.routes
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
