import SwiftUI
import CoreLocation

/// The two pushes this screen can make, unified so they share ONE
/// `navigationDestination(item:)` registration.
enum RouteDetailDestination: Hashable {
    case transfer(RouteSegment)
    case station(RouteStationStop)
    /// Carries the route id rather than the values, which are recomputed on arrival: the
    /// confidence and feasibility types are not `Hashable`, and a navigation value that went stale
    /// while pushed would show numbers the screen behind it no longer agrees with.
    case confidence(UUID)
}

struct RouteDetailView: View {
    private let initialRoute: Route
    let preference: RoutePreference
    let alternatives: [Route]
    let tripAnchor: TripTimeAnchor
    let accessibilityFilter: AccessibilityFilter
    @State var selectedRouteID: UUID
    @State var showTripNote = false
    @State var showExpandedRouteMap = false
    @State var showLiveGo = false
    @State private var scheduledReminderRouteID: UUID?
    @State var tripLoggedConfirmation = false
    @State private var showReminderDenied = false
    @State private var showReminderTooLate = false
    @State var tripNote = ""
    @State var detailDestination: RouteDetailDestination?
    @State private var boardingServiceWindows: [StationServiceWindow] = []
    // Raw theme hex for the "Navigate" button's solid fill — see RoutePlannerView's
    // identical declaration for why `Color.accentColor` (dark-mode-lightened for
    // foreground use) isn't used as a fill under white text.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue
    // Once per detail instance, NOT reset on disappear: dismissing the auto-presented
    // navigator re-fires onAppear, and a reset would immediately re-present it.
    @State private var didAutoPresentLiveGo = false
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) var appState
    @Environment(TripMemoryService.self) var tripMemoryService
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5

    var body: some View {
        // Compute the feasibility → confidence chain once per render and pass the values down,
        // instead of letting each card recompute them (previously 2× feasibility/personal-reports
        // per body evaluation).
        let feasibility = currentFeasibility()
        let confidence = currentConfidence(feasibility: feasibility)
        return List {
            Section {
                if alternatives.count > 1 {
                    RouteTabs(routes: alternatives, selection: $selectedRouteID)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                routeHero(feasibility: feasibility, confidence: confidence)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if let departurePlan {
                Section { DeparturePlanBanner(plan: departurePlan) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            // Checked here rather than letting the banner return an empty body: an empty view still
            // draws a `Section`, which is a blank inset card with nothing in it.
            if route.serviceStatus.bannerText != nil {
                Section { ServiceStatusBanner(status: route.serviceStatus) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            journeySection
            mapSection
            detailsSection(feasibility: feasibility, confidence: confidence)
        }
        .listStyle(.insetGrouped)
        // The default inset-grouped gap is tuned for Settings, where every section is a peer. Here
        // the hero, the journey and the details are one continuous read, and the stock spacing put
        // a third of a screen of nothing between them.
        .listSectionSpacing(14)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .safeAreaInset(edge: .bottom) { navigateBar }
        .navigationTitle(AppLocalization.localized("Route Details"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Step-by-Step Guidance (cognitive accessibility): go straight into the
            // guided navigator instead of the dense detail screen; dismissing it lands
            // on the full detail as usual.
            if appState.accessibilityPreference.stepByStepGuidance, !didAutoPresentLiveGo {
                didAutoPresentLiveGo = true
                ActiveTripStore.save(route)
                showLiveGo = true
            }
        }
        .sheet(isPresented: $showTripNote) {
            tripNoteSheet
        }
        // A single destination registration: two navigationDestination(item:) modifiers on
        // the same node is a historically unreliable SwiftUI pattern (one registration can
        // shadow the other), and both pushes share this screen anyway.
        .navigationDestination(item: $detailDestination) { destination in
            switch destination {
            case .transfer(let segment):
                TransferStationSheet(
                    transferSegment: segment,
                    nextTransitSegment: nextTransitSegment(after: segment),
                    cityID: route.networkCityID ?? appState.selectedCity?.id ?? "",
                    accessibilityFilter: accessibilityFilter
                )
            case .station(let stop):
                RouteStationGuideSheet(
                    stop: stop,
                    cityID: route.networkCityID ?? appState.selectedCity?.id ?? ""
                )
            case .confidence:
                let feasibility = currentFeasibility()
                RouteConfidenceDetailView(
                    confidence: currentConfidence(feasibility: feasibility),
                    feasibility: feasibility
                )
            }
        }
        .fullScreenCover(isPresented: $showExpandedRouteMap) {
            FullScreenRouteMapView(route: route)
        }
        .fullScreenCover(isPresented: $showLiveGo, onDismiss: { ActiveTripStore.clear() }) {
            LiveGoView(route: route)
        }
        .onChange(of: selectedRouteID) { _, _ in
            tripLoggedConfirmation = false
        }
        .onChange(of: routeSelectionSignature) {
            ensureSelectedRouteIsCurrent()
        }
        .task(id: "\(route.networkCityID ?? appState.selectedCity?.id ?? "")|\(selectedRouteID)") {
            boardingServiceWindows = []
            async let transferAssets: Void = container.officialStationData.prefetchTransferAssets(
                for: route
            )
            if let cityID = route.networkCityID ?? appState.selectedCity?.id {
                await loadServiceHours(cityID: cityID)
            }
            await transferAssets
        }
    }

    init(
        route: Route,
        preference: RoutePreference = .fastest,
        alternatives: [Route] = [],
        tripAnchor: TripTimeAnchor = .now,
        accessibilityFilter: AccessibilityFilter = .none
    ) {
        initialRoute = route
        self.preference = preference
        self.alternatives = alternatives.contains(where: { $0.id == route.id })
            ? alternatives
            : [route] + alternatives
        self.tripAnchor = tripAnchor
        self.accessibilityFilter = accessibilityFilter
        _selectedRouteID = State(initialValue: route.id)
    }

    var route: Route {
        alternatives.first { $0.id == selectedRouteID } ?? initialRoute
    }

    private var routeSelectionSignature: String {
        alternatives.map(\.id.uuidString).joined(separator: "|")
    }

    /// Derived from the single tracked route id so switching tabs to browse never silently
    /// drops a reminder the user set; "set" shows again when they return to that route.
    private var reminderScheduled: Bool {
        scheduledReminderRouteID == selectedRouteID
    }

    private func ensureSelectedRouteIsCurrent() {
        guard !alternatives.contains(where: { $0.id == selectedRouteID }),
              let firstRoute = alternatives.first else { return }
        selectedRouteID = firstRoute.id
    }

    func nextTransitSegment(after transferSegment: RouteSegment) -> RouteSegment? {
        guard let idx = route.segments.firstIndex(where: { $0.id == transferSegment.id }) else { return nil }
        return route.segments[(idx + 1)...].first { $0.type.isTransit }
    }

    /// The one number the rider came for, then where the trip runs and how long it takes.
    ///
    /// This replaced a header that led with the route string, put the duration second, and then
    /// stacked two status chips that the two cards further down said again in full. One chip
    /// survives, and only when there is something wrong to say — a green "high confidence" badge
    /// on a route with nothing wrong with it is decoration.
    private func routeHero(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(route.formattedDuration)
                .font(.largeTitle)
                .fontWeight(.bold)
                .monospacedDigit()
            Text("\(route.origin) → \(route.destination)")
                .font(.title3)
                .lineLimit(2)
            Text(heroSummary)
                .rowMeta()
            if let concern = heroConcern(feasibility: feasibility, confidence: confidence) {
                Label(concern.title, systemImage: concern.icon)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(concern.tint)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// Arrival time, stops and transfers on one line — the three things that decide between two
    /// routes, where they can be read together instead of hunted for.
    private var heroSummary: String {
        let timing = TripTimeContext(anchor: tripAnchor, totalDuration: route.totalDuration)
        let arrival = timing.arrivalDate.formatted(.dateTime.hour().minute())
        let stops = AppLocalization.text(
            english: "\(route.totalStops) stops",
            simplified: "\(route.totalStops) 站",
            traditional: "\(route.totalStops) 站"
        )
        let arrive = AppLocalization.text(
            english: "Arrive \(arrival)",
            simplified: "\(arrival) 到达",
            traditional: "\(arrival) 到達"
        )
        return "\(arrive) · \(stops) · \(route.formattedTransfers)"
    }

    /// The single worst thing about this route, or nothing at all when there is nothing to warn
    /// about. Feasibility outranks confidence: "there are stairs" is a fact about the trip, while a
    /// confidence score is a fact about our data.
    private func heroConcern(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> (title: String, icon: String, tint: Color)? {
        if feasibility.level != .good, feasibility.level != .unknown {
            return (feasibility.title, feasibility.level.iconName, feasibility.level.color)
        }
        if confidence.level != .high {
            return (confidence.level.title, confidenceIcon(for: confidence.level), confidence.level.color)
        }
        return nil
    }

    /// Pinned rather than scrolled past. It is the only thing on this screen the rider must be able
    /// to reach at any scroll position, and it used to sit inside the top card.
    private var navigateBar: some View {
        Button {
            ActiveTripStore.save(route)
            showLiveGo = true
        } label: {
            Label(
                AppLocalization.text(english: "Navigate", simplified: "开始导航", traditional: "開始導航"),
                systemImage: "figure.walk.circle.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color(hex: selectedThemeHex), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var mapSection: some View {
        Section {
            TransitMapView(
                visibleRegion: .constant(route.previewRegion),
                stations: [],
                metroNetworks: [],
                route: route,
                showsUserLocation: false,
                onRegionChanged: nil,
                onStationSelected: { _ in }
            )
            .frame(height: 200)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(10)
            }
            .contentShape(Rectangle())
            .onTapGesture { showExpandedRouteMap = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(AppLocalization.localized("Open route map full screen"))
            .listRowInsets(EdgeInsets())
        }
    }

    private var decisionDataConfidence: DataConfidence {
        let coverage = route.dataCoverage
        if coverage.scheduleConfidence == .official,
           coverage.accessibilityConfidence == .official,
           coverage.stationMapConfidence == .official {
            return .official
        }
        if coverage.hasOfficialCoreData {
            return .sourcePending
        }
        return .unavailable
    }

    private func confidenceIcon(for level: RouteConfidenceLevel) -> String {
        switch level {
        case .high:
            return "checkmark.seal.fill"
        case .medium:
            return "exclamationmark.triangle.fill"
        case .low:
            return "exclamationmark.octagon.fill"
        }
    }

    /// Everything that is not the journey itself, one row each. These were nine stacked cards —
    /// confidence, feasibility, trip essentials, access guidance, service hours, reminder, notes —
    /// most of which the rider reads once, if ever.
    private func detailsSection(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        Section {
            if let hours = boardingServiceHours {
                LabeledContent {
                    Text(AppLocalization.text(
                        english: "\(hours.first) – \(hours.last)",
                        simplified: "\(hours.first) – \(hours.last)",
                        traditional: "\(hours.first) – \(hours.last)"
                    ))
                    .rowValue()
                    .monospacedDigit()
                } label: {
                    Label(
                        AppLocalization.text(english: "Service hours", simplified: "运营时间", traditional: "營運時間"),
                        systemImage: "clock"
                    )
                }
            }

            Button { detailDestination = .confidence(route.id) } label: {
                HStack(spacing: 12) {
                    Label(
                        AppLocalization.text(english: "Confidence", simplified: "可信度", traditional: "可信度"),
                        systemImage: "checkmark.seal"
                    )
                    Spacer()
                    ConfidenceScoreRing(
                        score: confidence.score,
                        color: confidence.level.color,
                        size: 32,
                        lineWidth: 3
                    )
                    Image(systemName: "chevron.right").rowMeta()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            reminderRow

            if tripLoggedConfirmation {
                Label(
                    AppLocalization.text(english: "Trip logged", simplified: "行程已记录", traditional: "行程已記錄"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                Button {
                    tripNote = ""
                    showTripNote = true
                } label: {
                    Label(
                        AppLocalization.text(english: "Log this trip", simplified: "记录这次行程", traditional: "記錄這次行程"),
                        systemImage: "checkmark.circle"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Provenance needs a subject. On its own the chip said "Not available" under a section
            // header, naming nothing — a red badge for the rider to worry about with no way to tell
            // what it referred to.
            LabeledContent {
                DataConfidenceChip(confidence: decisionDataConfidence, compact: true)
            } label: {
                Label(
                    AppLocalization.text(english: "Station data", simplified: "车站数据", traditional: "車站資料"),
                    systemImage: "building.columns"
                )
            }
        } header: {
            Text(AppLocalization.text(english: "Details", simplified: "详情", traditional: "詳情"))
        }
    }

    private var departurePlan: DeparturePlan? {
        route.departurePlan(anchor: tripAnchor)
    }

    /// Scheduled first/last train times for the boarding line (official city-pack data).
    /// This is NOT a live countdown — the data sources have no real-time arrival feed.
    private var boardingServiceHours: (first: String, last: String)? {
        let firsts = boardingServiceWindows.compactMap(\.firstTime).filter { !$0.isEmpty }
        let lasts = boardingServiceWindows.compactMap(\.lastTime).filter { !$0.isEmpty }
        guard let first = firsts.min(), let last = lasts.max() else { return nil }
        return (first, last)
    }

    private func loadServiceHours(cityID: String) async {
        guard let stationName = route.boardingTransitSegment?.fromStationName else {
            boardingServiceWindows = []
            return
        }
        let windows = await container.officialStationData.serviceWindows(cityID: cityID, stationName: stationName)
        // .task(id:) cancelled this load because the rider switched route tabs — without this
        // guard a slow (e.g. network-bound) load for the OLD route lands after the new route's
        // cached one and shows the wrong service hours.
        guard !Task.isCancelled else { return }
        if let lineName = route.boardingTransitSegment?.lineName {
            let matched = windows.filter {
                $0.lineName == lineName || $0.lineName.contains(lineName) || lineName.contains($0.lineName)
            }
            boardingServiceWindows = matched.isEmpty ? windows : matched
        } else {
            boardingServiceWindows = windows
        }
    }

    /// One row per leg. Transit legs open to reveal the stations they pass, which is what the
    /// separate "Stations" card used to do a whole screen further down; transfer legs still push
    /// to the transfer guide.
    private var journeySection: some View {
        Section {
            ForEach(Array(route.segments.enumerated()), id: \.element.id) { index, segment in
                switch segment.type {
                case .subway:
                    DisclosureGroup {
                        ForEach(segment.stationStops) { stop in
                            Button { detailDestination = .station(stop) } label: {
                                HStack {
                                    Text(stop.name).rowValue()
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .rowMeta()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        journeyRow(segment, index: index)
                    }
                case .transfer:
                    Button { detailDestination = .transfer(segment) } label: {
                        HStack {
                            journeyRow(segment, index: index)
                            Image(systemName: "chevron.right").rowMeta()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                case .walking:
                    journeyRow(segment, index: index)
                }
            }
        } header: {
            Text(AppLocalization.text(english: "Route", simplified: "行程", traditional: "行程"))
        }
    }

    private func journeyRow(_ segment: RouteSegment, index: Int) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(journeyColor(segment))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(journeyTitle(segment, index: index))
                    .rowValue()
                    .fontWeight(.medium)
                if let detail = journeyDetail(segment, index: index) {
                    Text(detail).rowMeta()
                }
                // What we do not know about this door — that an exit is estimated rather than
                // surveyed, or that nothing here is recorded as step-free. It rides with the leg
                // it qualifies, so removing the card it used to live in loses nothing.
                ForEach(accessNotes(for: index), id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
            if segment.duration >= 60 {
                Text(segment.formattedDuration)
                    .rowMeta()
                    .monospacedDigit()
            }
        }
    }

    private func journeyColor(_ segment: RouteSegment) -> Color {
        switch segment.type {
        case .walking: return .gray
        case .subway: return Color.adaptive(hex: segment.lineColorHex ?? "#007AFF")
        case .transfer: return .orange
        }
    }

    private func journeyTitle(_ segment: RouteSegment, index: Int) -> String {
        switch segment.type {
        case .subway:
            return segment.lineName ?? AppLocalization.localized("Transit")
        case .transfer:
            return AppLocalization.text(english: "Transfer", simplified: "换乘", traditional: "換乘")
        case .walking:
            // The door is the point of a walking leg, and the walk is now actually measured to it
            // — so name it here rather than in a separate card the rider has to go looking for.
            guard let exit = exitName(for: index) else { return segment.summaryLabel }
            return AppLocalization.text(
                english: index == 0 ? "Walk to \(exit)" : "Walk from \(exit)",
                simplified: index == 0 ? "步行至 \(exit)" : "从 \(exit) 步行",
                traditional: index == 0 ? "步行至 \(exit)" : "從 \(exit) 步行"
            )
        }
    }

    private func journeyDetail(_ segment: RouteSegment, index: Int) -> String? {
        switch segment.type {
        case .subway:
            guard let from = segment.fromStationName, let to = segment.toStationName else { return nil }
            return "\(from) → \(to) · \(AppLocalization.stops(segment.stops))"
        case .transfer:
            return segment.fromStationName
        case .walking:
            return AppLocalization.distance(segment.distance)
        }
    }

    /// The chosen door for whichever end this leg belongs to, when one was actually resolved.
    /// `.stationPOI` means no specific entrance is known, so there is nothing honest to name.
    private func exitName(for index: Int) -> String? {
        guard let point = accessGuide(for: index)?.accessPoint,
              point.source != .stationPOI else { return nil }
        return point.name
    }

    private func accessNotes(for index: Int) -> [String] {
        accessGuide(for: index)?.accessibilityNotes ?? []
    }

    private func accessGuide(for index: Int) -> RouteAccessGuide? {
        if index == 0 { return route.originAccessGuide }
        if index == route.segments.count - 1 { return route.destinationAccessGuide }
        return nil
    }

    @ViewBuilder
    private var reminderRow: some View {
        if let departurePlan {
            Button {
                // Capture the route ID with the plan: the auth prompt inside
                // scheduleReminder awaits user input, and a tab switch during it
                // would otherwise file this plan under the newly-shown route.
                Task { await scheduleReminder(plan: departurePlan, routeID: route.id) }
            } label: {
                Label(
                    reminderScheduled
                        ? AppLocalization.text(english: "Reminder set", simplified: "提醒已设置", traditional: "提醒已設定")
                        : AppLocalization.text(
                            english: "Remind me \(reminderLeadMinutes) min before departure",
                            simplified: "出发前\(reminderLeadMinutes)分钟提醒我",
                            traditional: "出發前\(reminderLeadMinutes)分鐘提醒我"
                        ),
                    systemImage: reminderScheduled ? "bell.fill" : "bell"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(reminderScheduled)
            .alert(
                AppLocalization.text(english: "Notifications are off", simplified: "通知已关闭", traditional: "通知已關閉"),
                isPresented: $showReminderDenied
            ) {
                Button(AppLocalization.localized("OK"), role: .cancel) {}
            } message: {
                Text(AppLocalization.text(
                    english: "Enable notifications in Settings to get a leave-time reminder.",
                    simplified: "请在设置中开启通知以接收出发提醒。",
                    traditional: "請在設定中開啟通知以接收出發提醒。"
                ))
            }
            .alert(
                AppLocalization.text(english: "Too late to remind", simplified: "已来不及提醒", traditional: "已來不及提醒"),
                isPresented: $showReminderTooLate
            ) {
                Button(AppLocalization.localized("OK"), role: .cancel) {}
            } message: {
                Text(AppLocalization.text(
                    english: "The leave time is already here — no reminder was set.",
                    simplified: "出发时间已到，未设置提醒。",
                    traditional: "出發時間已到，未設定提醒。"
                ))
            }
        }
    }

    private func scheduleReminder(plan: DeparturePlan, routeID: UUID) async {
        guard plan.leaveByDate.addingTimeInterval(-Double(reminderLeadMinutes) * 60) > Date() else {
            showReminderTooLate = true
            return
        }
        guard await container.tripReminderService.requestAuthorization() else {
            showReminderDenied = true
            return
        }
        let scheduled = await container.tripReminderService.scheduleReminder(routeID: routeID, plan: plan, leadMinutes: reminderLeadMinutes)
        if scheduled {
            // Enforce a single active reminder: drop the one from a previously-reminded route
            // so scheduling on route A then route B can't leave two notifications pending.
            if let previous = scheduledReminderRouteID, previous != routeID {
                container.tripReminderService.cancelReminder(routeID: previous)
            }
            scheduledReminderRouteID = routeID
        }
        showReminderTooLate = !scheduled
    }

    func currentFeasibility() -> RouteFeasibility {
        container.routeFeasibilityService.feasibility(for: route)
    }

    private func currentConfidence(feasibility: RouteFeasibility) -> RouteConfidence {
        container.routeConfidenceService.confidence(
            for: route,
            feasibility: feasibility,
            preference: preference,
            alternatives: alternatives
        )
    }
}

/// Lightweight wrapper presented when a route's station timeline row is tapped. It resolves the
/// tapped stop to a full `Station` (loading city-pack data for that one station only) and shows
/// the standard `StationDetailView` — which lazy-loads exits/facilities/map via its own `.task`.
private struct RouteStationGuideSheet: View {
    let stop: RouteStationStop
    let cityID: String
    @Environment(DIContainer.self) private var container
    @State private var station: Station?
    @State private var didResolve = false

    var body: some View {
        Group {
            if let station {
                StationDetailView(station: station)
            } else if didResolve {
                StationDetailView(station: fallbackStation)
            } else {
                VStack(spacing: 14) {
                    Text(stop.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
            }
        }
        .task {
            // Only match when the stop carries a real coordinate — matching with a (0,0)
            // placeholder disambiguates same-named stations by distance to Null Island and
            // can pick the wrong one. A coordinate-less stop falls through to the
            // name-based fallback instead.
            if let coordinate = stop.coordinate {
                let place = TransitPlace(
                    name: stop.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    ),
                    source: .localStationData
                )
                station = await container.officialStationData.matchingStation(place: place, cityID: cityID)
            }
            didResolve = true
        }
    }

    private var fallbackStation: Station {
        stop.asStation(cityID: cityID)
    }
}
