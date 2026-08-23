import SwiftUI

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    /// Pushing is the map stack's job, not this screen's. It owns the whole plan → results →
    /// detail chain, so a route chosen here is handed back rather than presented from inside.
    let onSelect: (Route) -> Void
    /// Open the search page to refill one end. Handed back for the same reason as `onSelect`.
    let onEditEndpoint: (RouteInputField) -> Void
    /// Refill the start from the device. Its own control rather than a row in the search page,
    /// because "start from where I am" is the single most common correction to make here and
    /// sending it through a search screen to answer a question the phone already knows is silly.
    let onUseCurrentLocation: () -> Void
    let onSwap: () -> Void
    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedRouteID: UUID?
    // Raw theme hex for the solid-fill chip below. See RouteEntryView's identical
    // declaration for why `Color.accentColor` (dark-mode-lightened for foreground use)
    // isn't used as a fill under white text.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue

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
        // result: the chips sort the list directly below them and belong next to it.
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        // Pinned, not the first row of the list. Where the trip starts and ends is the thing the
        // rider checks first and changes most; scrolling it away to compare the fourth alternative
        // means scrolling back up to fix a wrong start.
        .safeAreaInset(edge: .top, spacing: 0) { endpointHeader }
        .navigationTitle(AppLocalization.localized("Routes"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureRouteSelection()
        }
        .onChange(of: routeSelectionSignature) {
            ensureRouteSelection()
        }
    }

    /// From and To, always visible, both editable in place. This is the whole reason the entry
    /// page is no longer in the way: everything it existed to collect is here, on the screen that
    /// shows the consequence of changing it.
    ///
    /// Two one-line fields sit stacked on a phone because that is all the width there is. Given
    /// more, they sit side by side with the swap control between them, which is both what they
    /// mean and what the control does.
    private var endpointHeader: some View {
        HStack(spacing: Metrics.m) {
            if isWide {
                endpointRow(.origin)
                swapButton
                endpointRow(.destination)
            } else {
                VStack(spacing: 0) {
                    endpointRow(.origin)
                    Divider().padding(.leading, 26)
                    endpointRow(.destination)
                }
                swapButton
            }
        }
        .padding(.horizontal, Metrics.l)
        .padding(.vertical, Metrics.s)
        .readableColumn()
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var swapButton: some View {
        Button(action: onSwap) {
            Image(systemName: isWide ? "arrow.left.arrow.right" : "arrow.up.arrow.down")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .tappable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.text(
            english: "Swap start and destination",
            simplified: "交换起点和终点",
            traditional: "交換起點和終點"
        ))
    }

    /// Wide enough to stop being one tall column. Read from the size class rather than a raw width
    /// so a split-screen iPad window, which is genuinely narrow, keeps the phone layout.
    private var isWide: Bool { horizontalSizeClass == .regular }

    private func endpointRow(_ field: RouteInputField) -> some View {
        let name = viewModel.name(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            onEditEndpoint(field)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(field == .origin ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                // An unfilled end says what to do about it rather than sitting blank. This
                // header is the only place the trip's ends can be corrected now.
                Text(name.isEmpty ? placeholder(for: field) : name)
                    .font(.subheadline)
                    .fontWeight(name.isEmpty ? .regular : .medium)
                    .foregroundStyle(name.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if field == .origin, container.locationService.isAuthorized {
                Button(action: onUseCurrentLocation) {
                    Image(systemName: "location.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .tappable()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.text(
                    english: "Start from my location",
                    simplified: "从我的位置出发",
                    traditional: "從我的位置出發"
                ))
            }
        }
    }

    private func placeholder(for field: RouteInputField) -> String {
        field == .origin
            ? AppLocalization.text(english: "Choose a start", simplified: "选择起点", traditional: "選擇起點")
            : AppLocalization.text(english: "Choose a destination", simplified: "选择终点", traditional: "選擇終點")
    }

    private var sortOptionsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // The active strategy leads, whether or not it is one of the three that get
                    // their own chip. The default sort is "Transit First", which is *not* primary,
                    // so it rendered only inside the overflow chip at the far right. Off the edge
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

    /// The headline strategies, preceded by whatever is actually sorting the list when that is
    /// something else, so a sort picked from "More" still shows as the selected chip rather than
    /// leaving the row looking like nothing is chosen.
    private var sortChipStrategies: [RoutePreference] {
        let primary = RoutePreference.primary
        guard !primary.contains(viewModel.sortStrategy) else { return primary }
        return [viewModel.sortStrategy] + primary
    }

    private var routesSection: some View {
        Section {
            ForEach(viewModel.routes) { route in
                comparisonRow(route)
                    // Cards settle in as they enter rather than appearing fully formed at the
                    // edge. Subtle on purpose: this is a list a rider scans, not one they admire.
                    .scrollTransition(.interactive) { content, phase in
                        content
                            .opacity(phase.isIdentity ? 1 : 0.6)
                            .scaleEffect(phase.isIdentity ? 1 : 0.97)
                    }
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

    /// One comparison row per alternative. The lines it rides, how long it takes, when it lands,
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
                cityID: route.networkCityID ?? "",
                accessibilityFilter: viewModel.accessibilityFilter
            )
            onSelect(route)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Why this route is in the list at all, but only when there is something to
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

                    VStack(alignment: .trailing, spacing: Metrics.hairline) {
                        // Re-sorting the list swaps these numbers in place. Animating the digits
                        // rather than cross-fading whole labels is the difference between the row
                        // visibly updating and the row appearing to have always said that.
                        Text(metrics.durationText)
                            .font(.title2)
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(metrics.arrivalText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        // Absent for every unpriced route, which is every city outside the
                        // provider's coverage. A blank is the honest rendering of "nobody told us".
                        if let fare = route.fare {
                            Text(fare.formatted)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                                .contentTransition(.numericText())
                        }
                    }
                }

                // The app does not plan bus routes and is not about to start. Naming the cheaper
                // one is what an honest app does with a fact it happens to hold.
                if let bus = route.fare?.cheaperBus {
                    Label(
                        cheaperBusLine(bus, against: route),
                        systemImage: "bus"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                // Full width, below everything: sharing a line with the duration column squeezed
                // "Walking-heavy route" into a two-line stub. Only what is wrong, and only in
                // words: this row used to lead with a 50 pt red "38", an unexplained score on a
                // scale the rider had never been shown.
                if let concern = RouteConcern.worst(feasibility: feasibility, confidence: confidence) {
                    Label(concern.title, systemImage: concern.icon)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(concern.tint)
                }
            }
            .padding(Metrics.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(.plain)
        // A route card stretched across a 1366-point iPad is a phone layout that got wider, not a
        // design. Capped and centred; on a phone the cap is larger than the screen and does nothing.
        .readableColumn()
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

    /// One line naming a cheaper bus, and saying plainly that this app will not plan it.
    ///
    /// The time difference is stated in whichever direction it actually runs. A bus that is both
    /// cheaper and faster is unusual and not impossible, and printing "slower" over it would be a
    /// small lie in service of a tidier sentence.
    private func cheaperBusLine(_ bus: RouteFare.BusAlternative, against route: Route) -> String {
        let fare = RouteFare.formatted(bus.yuan)
        let deltaMinutes = Int((bus.duration - route.totalDuration) / 60)
        guard abs(deltaMinutes) >= 1 else {
            return AppLocalization.text(
                english: "A bus does this for \(fare). Just-Go plans rail only.",
                simplified: "公交 \(fare) 可达。Just-Go 只规划轨道交通。",
                traditional: "公車 \(fare) 可達。Just-Go 只規劃軌道交通。"
            )
        }
        let minutes = abs(deltaMinutes)
        return deltaMinutes > 0
            ? AppLocalization.text(
                english: "A bus does this for \(fare), about \(minutes) min slower. Just-Go plans rail only.",
                simplified: "公交 \(fare) 可达，约慢 \(minutes) 分钟。Just-Go 只规划轨道交通。",
                traditional: "公車 \(fare) 可達，約慢 \(minutes) 分鐘。Just-Go 只規劃軌道交通。"
            )
            : AppLocalization.text(
                english: "A bus does this for \(fare), about \(minutes) min faster. Just-Go plans rail only.",
                simplified: "公交 \(fare) 可达，约快 \(minutes) 分钟。Just-Go 只规划轨道交通。",
                traditional: "公車 \(fare) 可達，約快 \(minutes) 分鐘。Just-Go 只規劃軌道交通。"
            )
    }

    private func transferEffort(for route: Route) -> String {
        if route.transferCount == 0 {
            return AppLocalization.text(english: "Direct", simplified: "直达", traditional: "直達")
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
        // Only claimable when something else was priced to compare against. One priced route among
        // four unpriced ones is not the cheapest of anything.
        let fares = routes.compactMap(\.fare?.yuan)
        if fares.count > 1, let fare = route.fare?.yuan, fare == fares.min() {
            return AppLocalization.text(english: "Cheapest", simplified: "最便宜", traditional: "最便宜")
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
