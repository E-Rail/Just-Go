import SwiftUI

/// Now / Depart at / Arrive by: a segmented control needs a case without a date, which
/// `TripTimeAnchor` does not have.
private enum TripTimingMode: CaseIterable {
    case now
    case departAt
    case arriveBy

    var title: String {
        switch self {
        case .now:
            return AppLocalization.text(english: "Now", simplified: "现在", traditional: "現在")
        case .departAt:
            return AppLocalization.text(english: "Depart at", simplified: "出发时间", traditional: "出發時間")
        case .arriveBy:
            return AppLocalization.text(english: "Arrive by", simplified: "到达时间", traditional: "抵達時間")
        }
    }
}

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    /// Pushing is the map stack's job: it owns plan → results → detail, so a chosen route is handed
    /// back.
    let onSelect: (Route) -> Void
    /// Open the search page to refill one end. Handed back for the same reason as `onSelect`.
    let onEditEndpoint: (RouteInputField) -> Void
    /// Refill the start from the device: its own control, since "start from where I am" is the most
    /// common correction here.
    let onUseCurrentLocation: () -> Void
    let onSwap: () -> Void
    /// Re-run the plan. Setting `tripAnchor` alone invalidates the in-flight search but leaves
    /// `routes` standing, which would re-time old results against a new clock.
    let onReplan: () -> Void
    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedRouteID: UUID?
    @State private var timingMode: TripTimingMode = .now
    @State private var chosenDate = Date()

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
                    // A change underneath this screen (an accessibility setting, a city) clears the
                    // routes; say so rather than showing a blank page.
                    StaleRoutesNotice()
                } else {
                    routesSection
                }
            }
            .listRowBackground(Color.clear)
            // `.plain` would draw a hairline above and below every row.
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        // The chips sort the list directly below them, so no stock gap between them.
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        // Pinned: where the trip starts and ends is what the rider checks first and changes most.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                endpointHeader
                timingHeader
            }
        }
        .navigationTitle(AppLocalization.localized("Routes"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureRouteSelection()
        }
        .onChange(of: routeSelectionSignature) {
            ensureRouteSelection()
        }
    }

    /// From and To, always visible and editable in place, on the screen that shows the consequence
    /// of changing them. Stacked on a phone; side by side, with the swap control between them, when
    /// there is width.
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
        // A trailing tab bar runs the screen's full height, so the header clears it too; inside the
        // material, so the band still spans the width.
        .safeAreaPadding(.horizontal)
        .readableColumn()
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// When, beside where: the trip's third input, shown with its consequence immediately below.
    private var timingHeader: some View {
        VStack(spacing: Metrics.s) {
            Picker(selection: $timingMode) {
                ForEach(TripTimingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)

            if timingMode != .now {
                DatePicker(
                    selection: $chosenDate,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text(timingMode.title)
                }
                .datePickerStyle(.compact)
                // The picker's clock is China time, like every time the results print; a phone set
                // to Tokyo would pick the wrong hour.
                .environment(\.timeZone, ChinaClock.calendar.timeZone)
            }
        }
        .padding(.horizontal, Metrics.l)
        .padding(.bottom, Metrics.s)
        .safeAreaPadding(.horizontal)
        .readableColumn()
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: timingMode) { _, mode in
            // A stale time is worse than none: returning to "Depart at" later must not offer the
            // moment the screen first opened.
            if mode == .now { chosenDate = Date() }
            applyTiming()
        }
        .onChange(of: chosenDate) { _, _ in applyTiming() }
        // The control is local state, so adopt whatever the trip is anchored to (a deep link can
        // set it). Assigning the current anchor is a no-op: `applyTiming` compares before
        // re-planning.
        .onAppear { adoptAnchor(viewModel.tripAnchor) }
        .onChange(of: viewModel.tripAnchor) { _, anchor in adoptAnchor(anchor) }
    }

    private func adoptAnchor(_ anchor: TripTimeAnchor) {
        switch anchor {
        case .now:
            timingMode = .now
        case .departBy(let date):
            timingMode = .departAt
            chosenDate = date
        case .arriveBy(let date):
            timingMode = .arriveBy
            chosenDate = date
        }
    }

    private func applyTiming() {
        let anchor: TripTimeAnchor
        switch timingMode {
        case .now: anchor = .now
        case .departAt: anchor = .departBy(chosenDate)
        case .arriveBy: anchor = .arriveBy(chosenDate)
        }
        guard viewModel.tripAnchor != anchor else { return }
        viewModel.tripAnchor = anchor
        onReplan()
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

    /// From the size class, not a raw width, so a narrow split-screen iPad window keeps the phone
    /// layout.
    private var isWide: Bool { horizontalSizeClass == .regular }

    private func endpointRow(_ field: RouteInputField) -> some View {
        let name = viewModel.name(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
        let showsLocate = field == .origin && container.locationService.isAuthorized
        // The locate button is a sibling, not an overlay, so a long name (广州白云国际机场T2航站楼) truncates
        // before it rather than under it.
        return HStack(spacing: 0) {
            Button {
                onEditEndpoint(field)
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(field == .origin ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    // An unfilled end says what to do; this header is where the trip's ends are
                    // corrected.
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

            if showsLocate {
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
                    ForEach(RoutePreference.allCases) { strategy in
                        Chip(
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
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var routesSection: some View {
        Section {
            ForEach(viewModel.routes) { route in
                // No `.scrollTransition`: inside a `List` its phase never reaches `.identity`, and
                // every card rendered at 60% opacity.
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

    /// One row per alternative: the lines it rides, how long, when it lands, and the single thing
    /// wrong with it. Tapping records the planned trip and opens the detail.
    private func comparisonRow(_ route: Route) -> some View {
        let isSelected = route.id == selectedRouteID
        let metrics = comparisonMetrics(for: route)
        let feasibility = container.routeFeasibilityService.feasibility(for: route)
        let confidence = routeConfidence(for: route, feasibility: feasibility)
        return Button {
            selectedRouteID = route.id
            tripMemoryService.recordPlannedTrip(
                route: route,
                cityID: route.networkCityID ?? ""
            )
            onSelect(route)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Why this route is listed, but only when there is something to compare it against.
                if viewModel.routes.count > 1 {
                    Text(metrics.bestForReason)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.accentColor)
                }

                // At accessibility text sizes two columns truncate the arrival time, so the card
                // stacks, as `StepControlPair` does.
                AdaptiveStack(isVertical: dynamicTypeSize.isAccessibilitySize, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        // The lines this route rides, in order and in their colours: alternatives
                        // are compared by the shape of the journey.
                        JourneyBadgeChain(segments: route.segments)

                        Text(metrics.summaryLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
                           spacing: Metrics.hairline) {
                        // Re-sorting swaps these numbers in place; animated digits read as the row
                        // updating.
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
                        // Absent for every unpriced route: a blank is the honest rendering of
                        // "nobody told us".
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

                // A ride's own caveat (a premium fare), said where routes are compared.
                ForEach(route.segments.filter { $0.type == .subway }.flatMap(\.accessibilityNotes).uniqued(), id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // The app does not plan buses, but names a cheaper one it knows about.
                if let bus = route.fare?.cheaperBus {
                    Label(
                        cheaperBusLine(bus, against: route),
                        systemImage: "bus"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                // Whether this trip can be ridden at the hour it departs, shown on the screen the
                // rider chooses from. Only on routes that ride trains: a drive has no last train
                // and no station data to grade.
                if route.boardingTransitSegment != nil, route.serviceStatus.bannerText != nil {
                    // The shared banner, which carries the taxi price: being told the last train
                    // has gone without what the alternative costs is half an answer.
                    ServiceStatusBanner(
                        status: route.serviceStatus,
                        compact: true,
                        missedTrainTaxiYuan: route.missedTrainTaxiYuan,
                        hail: route.hailRequest
                    )
                } else if route.boardingTransitSegment != nil, let unverified = unverifiedServiceHoursNotice(
                    status: route.serviceStatus,
                    departing: TripTimeContext(
                        anchor: viewModel.tripAnchor,
                        totalDuration: route.totalDuration
                    ).departureDate
                ) {
                    Label(unverified, systemImage: RouteServiceStatus.unknown.iconName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Full width, below everything, and only in words: only what is wrong.
                if let concern = RouteConcern.worst(
                    feasibility: feasibility,
                    confidence: confidence,
                    gradesData: route.boardingTransitSegment != nil
                ) {
                    Label(concern.title, systemImage: concern.icon)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(concern.tint)
                }
            }
            .padding(Metrics.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            // The row the rider last opened, marked, and announced to VoiceOver. A tinted stroke
            // rather than a fill: the accent is lifted for foreground use.
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // Capped and centred on a wide screen; on a phone the cap is wider than the screen.
        .readableColumn()
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func comparisonMetrics(for route: Route) -> RouteComparisonMetrics {
        let timing = TripTimeContext(anchor: viewModel.tripAnchor, totalDuration: route.totalDuration)
        return RouteComparisonMetrics(
            id: route.id,
            durationText: route.formattedDuration,
            bestForReason: bestForReason(for: route, in: viewModel.routes),
            arrivalText: timing.arrivalDetail,
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

    /// The route's 0–100 confidence from the same comfort → feasibility → confidence chain as the
    /// detail screen, so a route is flagged the same way after tapping in.
    private func routeConfidence(for route: Route, feasibility: RouteFeasibility) -> RouteConfidence {
        container.routeConfidenceService.confidence(
            for: route,
            feasibility: feasibility,
            preference: viewModel.sortStrategy,
            alternatives: viewModel.routes
        )
    }

    /// One line naming a cheaper bus and saying this app will not plan it, with the time difference
    /// stated in whichever direction it runs.
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
        // A drive or a walk is the alternative to every train plan, not one of them, so none of
        // these labels applies; the mode badge says what it is.
        guard route.boardingTransitSegment != nil else {
            return route.segments.first?.type == .driving
                ? AppLocalization.text(english: "By car", simplified: "驾车", traditional: "駕車")
                : AppLocalization.text(english: "On foot", simplified: "步行", traditional: "步行")
        }
        // Every test is strictly better than every alternative, never equal-best: two ¥5 routes are
        // not one cheap and one expensive.
        func onlyOne(_ isBetter: (Route) -> Bool) -> Bool {
            routes.allSatisfy { $0.id == route.id || isBetter($0) }
        }

        if onlyOne({ $0.totalDuration > route.totalDuration }) {
            return AppLocalization.localized("Fastest")
        }
        // Cost needs every alternative priced: an unpriced route is not an expensive one. `??
        // false` blocks the claim and covers a single priced route.
        if let fare = route.fare?.yuan,
           onlyOne({ ($0.fare?.yuan).map { $0 > fare } ?? false }) {
            return AppLocalization.text(english: "Cheapest", simplified: "最便宜", traditional: "最便宜")
        }
        if onlyOne({ $0.transferCount > route.transferCount }) {
            return AppLocalization.text(english: "Fewest transfers", simplified: "换乘最少", traditional: "換乘最少")
        }
        if onlyOne({ $0.walkingDistance > route.walkingDistance }) {
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

/// Routes that were cleared while a screen showing them was up.
struct StaleRoutesNotice: View {
    var body: some View {
        ContentUnavailableView {
            Label(AppLocalization.localized("No Routes Found"), systemImage: "map")
        } description: {
            Text(AppLocalization.text(
                english: "This search is no longer current. Go back and search again.",
                simplified: "此次搜索已失效，请返回重新搜索。",
                traditional: "此次搜尋已失效，請返回重新搜尋。"
            ))
        }
    }
}
