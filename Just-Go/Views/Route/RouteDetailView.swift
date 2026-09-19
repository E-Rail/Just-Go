import SwiftUI
import CoreLocation

/// The pushes this screen can make, sharing one `navigationDestination(item:)` registration.
enum RouteDetailDestination: Hashable {
    case transfer(RouteSegment)
    case station(RouteStationStop)
    /// Carries the route id rather than the values, which are recomputed on arrival: the
    /// confidence and feasibility types are not `Hashable`, and a navigation value that went stale
    /// while pushed would show numbers the screen behind it no longer agrees with.
    case confidence(UUID)
}

extension RouteDetailDestination: Identifiable {
    /// `sheet(item:)` needs one, and `Hashable` already gives a stable answer. Presented as a sheet
    /// only on regular width; on a phone this is pushed and the id is unused.
    var id: Self { self }
}

/// Everything the trip card can raise over itself, as one value with one `.sheet` registration on
/// `tripCardContent`. A node presents one sheet at a time, and `body` already presents the card, so
/// a sheet registered there never shows.
enum TripCardSheet: Identifiable, Equatable {
    case tripNote
    case resource(ExternalTransitResource)
    case notice(OperatorServiceNotice)

    var id: String {
        switch self {
        case .tripNote: return "tripNote"
        case let .resource(resource): return "resource:\(resource.id)"
        case let .notice(notice): return "notice:\(notice.id)"
        }
    }
}

/// Why a leave-time reminder was not set. One value rather than a boolean per reason: two `.alert`s
/// on one node shadow each other.
enum ReminderAlert: Identifiable {
    /// The system refused the request. The reachable cause is iOS's 64-pending-notification cap.
    case notScheduled
    case tooLate
    case denied

    var id: Self { self }

    var title: String {
        switch self {
        case .notScheduled:
            return AppLocalization.text(english: "Reminder not set", simplified: "未设置提醒", traditional: "未設定提醒")
        case .tooLate:
            return AppLocalization.text(english: "Too late to remind", simplified: "已来不及提醒", traditional: "已來不及提醒")
        case .denied:
            return AppLocalization.text(english: "Notifications are off", simplified: "通知已关闭", traditional: "通知已關閉")
        }
    }

    var message: String {
        switch self {
        case .notScheduled:
            // Says what to do: the cap counts every app's pending notifications, so the fix is on
            // the phone.
            return AppLocalization.text(
                english: "This phone is holding as many scheduled notifications as it allows. Clear some and try again.",
                simplified: "本机待发送的通知已达上限。清理一些后再试。",
                traditional: "本機待發送的通知已達上限。清理一些後再試。"
            )
        case .tooLate:
            return AppLocalization.text(
                english: "The leave time is already here, so no reminder was set.",
                simplified: "出发时间已到，未设置提醒。",
                traditional: "出發時間已到，未設定提醒。"
            )
        case .denied:
            return AppLocalization.text(
                english: "Enable notifications in Settings to get a leave-time reminder.",
                simplified: "请在设置中开启通知以接收出发提醒。",
                traditional: "請在設定中開啟通知以接收出發提醒。"
            )
        }
    }
}

struct RouteDetailView: View {
    private let initialRoute: Route
    let preference: RoutePreference
    let alternatives: [Route]
    let tripAnchor: TripTimeAnchor
    let accessibilityFilter: AccessibilityFilter
    @State var selectedRouteID: UUID
    @State var tripCardSheet: TripCardSheet?
    @State private var scheduledReminderRouteID: UUID?
    @State var tripLoggedConfirmation = false
    @State private var reminderAlert: ReminderAlert?
    @State var tripNote = ""
    @State var detailDestination: RouteDetailDestination?
    @State private var expandedLegs: Set<UUID> = []
    @State private var boardingServiceHours: BoardingServiceHours = .none
    /// Which of the three stops the trip sheet is resting at.
    @State private var tripCardDetent: PresentationDetent = .medium
    /// The page is on screen and not being popped. Set on arrival, cleared as a pop starts.
    @State private var isOnScreen = false
    /// Where the header map is looking: seeded from the trip's bounds, then left to the rider.
    @State private var headerRegion: MapVisibleRegion?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Whether there is room to show the map and the trip side by side. The sheet's detents,
    /// background interaction and dismiss lock describe a card over a phone-sized map; on an iPad
    /// that card would float over a 1024 pt map with the route hidden behind it, so regular width
    /// gets a column instead.
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    /// Where the sheet was resting before a push raised it, so coming back restores it.
    @State private var stopBeforePush: PresentationDetent?
    /// Guidance replaces this page's content rather than covering it.
    @State private var isGuiding = false
    @State private var boardingArrivals: [RealTimeArrival] = []
    @State private var cityResources: [ExternalTransitResource] = []
    @State private var serviceNotices: [OperatorServiceNotice] = []
    // Raw theme hex for the Navigate button's solid fill: `Color.accentColor` is lightened for
    // foreground use in dark mode, and as a fill it loses contrast under white text.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue
    // Once per detail instance, not reset on disappear: leaving the auto-entered navigator re-fires
    // `onAppear`, and a reset would re-enter it.
    @State private var didAutoPresentLiveGo = false
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) var appState
    @Environment(TripMemoryService.self) var tripMemoryService
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5

    var body: some View {
        // The feasibility → confidence chain, computed once per render and passed down.
        let feasibility = currentFeasibility()
        let confidence = currentConfidence(feasibility: feasibility)
        // Map on top, trip in a sheet over it. A `ZStack`, not a `Group`: modifiers on a `Group`
        // attach to each branch, so swapping out of guidance would fire the page observer's
        // `onLeaving` and close the returning card.
        return ZStack {
            if isGuiding {
                // The page becomes the navigator rather than presenting a second one over itself.
                LiveGoView(route: route, embedded: true) {
                    withAnimation(.easeInOut(duration: 0.25)) { isGuiding = false }
                    ActiveTripStore.clear()
                }
            } else if isRegularWidth {
                splitLayout(feasibility: feasibility, confidence: confidence)
            } else {
                mapHeader()
            }
        }
        .background(Color.appBackground)
        // Derived, not stored: guiding, a wide layout and a pop in progress each hide the card, and
        // one expression cannot be left disagreeing with any of them. The card is never dismissed
        // any other way (`interactiveDismissDisabled`), so the setter has nothing to record.
        .sheet(isPresented: Binding(get: { isOnScreen && !isGuiding && !isRegularWidth }, set: { _ in })) {
            tripCard(feasibility: feasibility, confidence: confidence)
        }
        // From `.task`, after the push settles: a sheet raised during a navigation transition fails
        // with "whose view is not in the window hierarchy".
        .task { isOnScreen = true }
        // A sheet presented from a pushed view belongs to the navigation controller, so a pop does
        // not take it along. `PageTransitionObserver` reports the pop starting, for the back button
        // and a swipe alike, so the card slides down with the page; `onDisappear` is the backstop.
        .onDisappear { isOnScreen = false }
        .background(
            PageTransitionObserver(
                onLeaving: { isOnScreen = false },
                onReturned: { isOnScreen = true }
            )
            .frame(width: 0, height: 0)
        )
        .navigationTitle(isGuiding
            ? AppLocalization.text(english: "Guidance", simplified: "导航中", traditional: "導航中")
            : AppLocalization.localized("Route Details"))
        .navigationBarTitleDisplayMode(.inline)
        // The trip fills the screen: a tab bar under the journey invites leaving mid-plan and takes
        // height from it.
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            // Step-by-Step Guidance (cognitive accessibility): go straight to the guided navigator;
            // leaving it lands on the full detail.
            if appState.accessibilityPreference.stepByStepGuidance, !didAutoPresentLiveGo {
                didAutoPresentLiveGo = true
                ActiveTripStore.save(route)
                isGuiding = true
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SCREEN"] == "guiding" {
                ActiveTripStore.save(route)
                isGuiding = true
            }
            // The card's detent is a drag, which cannot be injected here, so its range is checked
            // by seeding each end.
            switch ProcessInfo.processInfo.environment["JUST_GO_DEBUG_MAP_FRACTION"] {
            case "low": tripCardDetent = .fraction(0.3)
            case "medium": tripCardDetent = .medium
            case "top": tripCardDetent = .fraction(0.92)
            default: break
            }
            #endif
        }
        .onChange(of: selectedRouteID) { _, _ in
            tripLoggedConfirmation = false
        }
        .onChange(of: routeSelectionSignature) {
            ensureSelectedRouteIsCurrent()
        }
        .task(id: routeDataKey) {
            // Everything the previous route put here, cleared together, so a walking alternative or
            // a trip in another pack never shows the last route's notices or resources.
            boardingServiceHours = .none
            cityResources = []
            serviceNotices = []
            // Operator content belongs to a trip that uses that operator. A walking-only route
            // rides nothing and has no `networkCityID`; wrong operator content is worse than none.
            guard route.boardingTransitSegment != nil else { return }
            async let transferAssets: Void = container.officialStationData.prefetchTransferAssets(
                for: route
            )
            if let cityID = route.networkCityID {
                cityResources = await container.officialStationData
                    .cityExternalResources(for: [cityID])[cityID] ?? []
                if cityID == BeijingServiceNoticeProvider.cityID {
                    // Best effort by design: a failed or slow fetch leaves the card showing what
                    // is already verifiable. Operator notices are never a blocker.
                    serviceNotices = (try? await container.serviceNoticeProvider.notices()) ?? []
                }
                await loadServiceHours(cityID: cityID)
                await loadBoardingArrivals(cityID: cityID)
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

    /// City + selected route: the two things every load on this screen is keyed to.
    private var routeDataKey: String {
        let cityID = route.networkCityID ?? ""
        return cityID + "|" + selectedRouteID.uuidString
    }

    private var routeSelectionSignature: String {
        alternatives.map(\.id.uuidString).joined(separator: "|")
    }

    /// Derived from the single tracked route id, so switching alternatives never silently drops a
    /// reminder; "set" shows again on returning to that route.
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

    /// The one number the rider came for, then where the trip runs and how long it takes, and the
    /// single thing wrong with it when there is one.
    private func routeHero(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Duration and walking on the left, arrival on the right: the three numbers read
            // together.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(route.formattedDuration)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    // Switching alternatives changes this number in place; animating the digits
                    // reads as one number changing.
                    .contentTransition(.numericText())
                    // "1 hr 52 min" in a large rounded face is wide; shrinking beats wrapping a
                    // duration across two lines.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(2)
                Text(AppLocalization.text(
                    english: "\(route.formattedWalkingDistance) walk",
                    simplified: "步行 \(route.formattedWalkingDistance)",
                    traditional: "步行 \(route.formattedWalkingDistance)"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(arrivalDetail)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }

            // The shape of the journey, readable before any of the words are: which lines, in
            // what order, with the walks between them.
            ScrollView(.horizontal, showsIndicators: false) {
                JourneyBadgeChain(segments: route.segments, size: 28)
                    .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize)

            Text(heroSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let concern = RouteConcern.worst(
                feasibility: feasibility,
                confidence: confidence,
                gradesData: route.boardingTransitSegment != nil
            ) {
                Label(concern.title, systemImage: concern.icon)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(concern.tint)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    /// Stops, fare, transfers and which door to enter by: the line Amap spends on "13站 · ¥5 · 玉泉路
    /// (C2东南口) 进站". The fare comes from a provider that priced the same two gates
    /// (`RoutePlanningService.pricing` discards it unless boarding and alighting match), never from
    /// a stop count; an unpriced trip prints nothing. The entrance is the door the plan routed to.
    private var heroSummary: String {
        let stops = AppLocalization.text(
            english: "\(route.totalStops) stops",
            simplified: "\(route.totalStops) 站",
            traditional: "\(route.totalStops) 站"
        )
        var parts = [stops]
        if let fare = route.fare {
            parts.append(fare.formatted)
        }
        parts.append(route.formattedTransfers)
        if let entrance = route.originAccessGuide?.accessPoint?.namedDoor {
            parts.append(AppLocalization.text(
                english: "Enter at \(entrance)",
                simplified: "\(entrance) 进站",
                traditional: "\(entrance) 進站"
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// Pinned rather than scrolled past: the one control reachable at any scroll position.
    private var navigateBar: some View {
        Button {
            ActiveTripStore.save(route)
            withAnimation(.easeInOut(duration: 0.25)) { isGuiding = true }
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
        // Clear of a tab bar the system may move to the trailing edge on a foldable. The background
        // is applied after, so it still spans the width.
        .safeAreaPadding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // Opaque: at the shortest detent the scroll view is taller than the visible card, and rows
        // would show either side of the capsule.
        .background(Color.appBackground)
    }

    /// Map and trip side by side, which a tablet has room for. The column has no `NavigationStack`
    /// of its own: one nested in a pushed destination makes the whole screen fail to appear, with
    /// no error. The phone's sheet can carry one because a sheet is its own presentation context.
    private func splitLayout(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        // The reader hands the column a real width; inferred from an ambient container it measured
        // zero points wide.
        GeometryReader { geo in
            HStack(spacing: 0) {
                mapHeader()
                    .frame(maxWidth: .infinity)
                Divider()
                tripCardContent(feasibility: feasibility, confidence: confidence)
                    .sideColumn(max: Metrics.tripColumnWidth, in: geo.size.width)
            }
        }
        // Sub-details are pushed inside the sheet on a phone and presented over the split here, so
        // the map and the trip both stay on screen behind them.
        .sheet(item: $detailDestination) { destination in
            NavigationStack { destinationView(for: destination) }
        }
    }

    /// A transfer, a station or the confidence breakdown, defined once: pushed inside the sheet's
    /// stack on a phone, presented over the split on a tablet.
    @ViewBuilder
    private func destinationView(for destination: RouteDetailDestination) -> some View {
        switch destination {
        case .transfer(let segment):
            TransferStationSheet(
                transferSegment: segment,
                nextTransitSegment: nextTransitSegment(after: segment),
                cityID: segment.packCityID ?? route.networkCityID ?? "",
                accessibilityFilter: accessibilityFilter
            )
        case .station(let stop):
            RouteStationGuideSheet(
                stop: stop,
                cityID: stop.packCityID ?? route.networkCityID ?? ""
            )
        case .confidence:
            let feasibility = currentFeasibility()
            RouteConfidenceDetailView(
                confidence: currentConfidence(feasibility: feasibility),
                feasibility: feasibility
            )
        }
    }

    /// The trip as something to read, in the sheet over the map.
    private func tripCard(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        // The sheet carries its own navigation stack, so a station or a transfer opens inside it,
        // as in Maps, and nothing outside the sheet moves.
        NavigationStack {
            tripCardContent(feasibility: feasibility, confidence: confidence)
            // Here, on the sheet's own stack: in the wide layout the same content sits in the page,
            // where hiding the bar took the back button with it.
            .toolbar(.hidden, for: .navigationBar)
            // One destination registration: two `navigationDestination(item:)` modifiers on one
            // node can shadow each other.
            .navigationDestination(item: $detailDestination) { destinationView(for: $0) }
        }
        // Detents, background interaction and the dismiss lock describe a card over a map, so they
        // apply only there; a column has no detent and nothing to dismiss.
        .presentationDetents(isRegularWidth ? [.large] : Self.tripCardDetents, selection: $tripCardDetent)
        .presentationDragIndicator(isRegularWidth ? .hidden : .visible)
        // The map stays live at the two lower stops.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // Nowhere to be dismissed to: a swiped-away card would leave this route's map with no trip
        // on it.
        .interactiveDismissDisabled()
        // A pushed screen in a 30%-tall sheet is a letterbox, so the sheet rises for a push and
        // returns to where the rider had it.
        .onChange(of: detailDestination) { previous, current in
            guard !isRegularWidth else { return }
            if previous == nil, current != nil {
                stopBeforePush = tripCardDetent
                withAnimation { tripCardDetent = .fraction(0.92) }
            } else if current == nil, let stopBeforePush {
                withAnimation { tripCardDetent = stopBeforePush }
                self.stopBeforePush = nil
            }
        }
    }

    private func tripCardContent(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                routeHero(feasibility: feasibility, confidence: confidence)
                if let departurePlan {
                    DeparturePlanBanner(plan: departurePlan)
                }
                officialNoticeCard
                journeyCard
                detailsCard(feasibility: feasibility, confidence: confidence)
            }
            .padding(.horizontal, 16)
            // Clear of the grab indicator, so the first card does not read as attached to the
            // sheet's edge.
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        // A `ScrollView`, not a `List`: inset-grouped spacing opens with empty space above the
        // duration, and a list row cannot draw the unbroken rail that makes the legs one journey.
        .background(Color.appBackground)
        .safeAreaInset(edge: .bottom) { navigateBar }
        // Here, not on `body`: `body` is already presenting this card, and a node presents one
        // sheet. `tripCardContent` is what both the phone sheet and the iPad column render.
        .sheet(item: $tripCardSheet) { sheet in
            switch sheet {
            case .tripNote:
                tripNoteSheet
            case let .resource(resource):
                OfficialTransitResourceViewer(resource: resource)
            case let .notice(notice):
                OfficialTransitResourceViewer(resource: Self.resource(for: notice))
            }
        }
    }

    // MARK: - Official notices

    /// What the operator says about riding this route today: service warnings derived from official
    /// first/last-train data, the operator's own notices, and a link to its page with the
    /// provider's name and the date the link was verified. When a city has none of these, nothing
    /// is drawn.
    @ViewBuilder
    private var officialNoticeCard: some View {
        let notice = route.serviceStatus.bannerText
        if notice != nil || officialResource != nil || !serviceNotices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if notice != nil {
                    ServiceStatusBanner(
                        status: route.serviceStatus,
                        missedTrainTaxiYuan: route.missedTrainTaxiYuan,
                        hail: route.hailRequest
                    )
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                ForEach(serviceNotices) { item in
                    if notice != nil || item.id != serviceNotices.first?.id { rowDivider }
                    Button { tripCardSheet = .notice(item) } label: { noticeRow(item) }
                        .buttonStyle(.plain)
                }
                if !serviceNotices.isEmpty, officialResource != nil { rowDivider }
                if let resource = officialResource {
                    if notice != nil, serviceNotices.isEmpty { rowDivider.padding(.top, 8) }
                    Button {
                        tripCardSheet = .resource(resource)
                    } label: {
                        detailRow(
                            icon: "building.columns.fill",
                            tint: .accentColor,
                            title: resource.title
                        ) {
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Provenance: whose page it is and how old our pointer to it might be.
                    Text(AppLocalization.text(
                        english: "\(resource.provider) · official site · link checked \(resource.verifiedAt)",
                        simplified: "\(resource.provider) · 官方网站 · 链接核对于 \(resource.verifiedAt)",
                        traditional: "\(resource.provider) · 官方網站 · 連結核對於 \(resource.verifiedAt)"
                    ))
                    .rowMeta()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        }
    }

    /// The operator's own page for this city, best kind first. Few cities publish a `serviceStatus`
    /// page (Beijing publishes `operatorInformation`), so the row is labelled with the resource's
    /// own title and never presented as an advisory feed it is not.

    /// Wraps a fetched notice so the existing official-resource viewer can open it. Same
    /// ephemeral web stack, same provenance header, no second browser.
    private static func resource(for item: OperatorServiceNotice) -> ExternalTransitResource {
        ExternalTransitResource(
            kind: .serviceStatus,
            title: item.title,
            targetURL: item.url.absoluteString,
            sourcePageURL: item.url.absoluteString,
            provider: AppLocalization.text(
                english: "Beijing Subway", simplified: "北京地铁", traditional: "北京地鐵"
            ),
            scope: .city,
            format: .webPage,
            verifiedAt: item.publishedOn,
            stationID: nil
        )
    }

    /// One operator notice, verbatim, with its own publication date under it.
    private func noticeRow(_ item: OperatorServiceNotice) -> some View {
        let attribution = AppLocalization.text(
            english: "Beijing Subway · published \(item.publishedOn)",
            simplified: "北京地铁 · 发布于 \(item.publishedOn)",
            traditional: "北京地鐵 · 發布於 \(item.publishedOn)"
        )
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                // The date matters: Beijing publishes irregularly, and a rider must see how old a
                // notice is before acting on it.
                Text(attribution).rowMeta()
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }


    private var officialResource: ExternalTransitResource? {
        let preference: [ExternalTransitResourceKind] = [
            .serviceStatus, .operatorInformation, .stationInformation
        ]
        for kind in preference {
            if let match = cityResources.first(where: { $0.kind == kind }) { return match }
        }
        return nil
    }

    // MARK: - Resizable map header

    /// The three stops the trip card rests at. The top one stops short of `.large`, which would
    /// cover the navigation bar and the way back.
    static let tripCardDetents: Set<PresentationDetent> = [.fraction(0.3), .medium, .fraction(0.92)]

    private func mapHeader() -> some View {
        TransitMapView(
            visibleRegion: $headerRegion,
            stations: route.mapStations,
            alwaysShowsStations: true,
            metroNetworks: [],
            route: route,
            showsUserLocation: false,
            onRegionChanged: { headerRegion = $0 },
            onStationSelected: { _ in }
        )
        .ignoresSafeArea(edges: .bottom)
        // Seeded once: assigning on every pass would fight the rider for the camera.
        .task(id: route.id) { headerRegion = route.previewRegion }
        // At the map's top edge, the part the trip sheet never covers.
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                if alternatives.count > 1 {
                    RouteTabs(routes: alternatives, selection: $selectedRouteID, floating: true)
                }
                // The trip's track is the bundled OSM geometry, so it carries the ODbL attribution,
                // placed where the trip card does not cover it.
                if route.segments.contains(where: { $0.type.isTransit }) {
                    MetroGeometryAttributionView()
                        .padding(.leading, 12)
                }
            }
            .padding(.top, 8)
        }
    }

    private var decisionDataConfidence: DataConfidence {
        let coverage = route.dataCoverage
        if coverage.scheduleConfidence == .official,
           coverage.accessibilityConfidence == .official {
            return .official
        }
        if coverage.hasOfficialCoreData {
            return .sourcePending
        }
        return .unavailable
    }

    /// Everything that is not the journey itself, one row each.
    private func detailsCard(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        VStack(spacing: 0) {
            // On every trip that rides anything: the estimator has no headway or first-train wait,
            // so every duration here is running time only, whatever a city's data.
            if route.boardingTransitSegment != nil {
                detailRow(
                    icon: "hourglass",
                    tint: .secondary,
                    title: AppLocalization.text(
                        english: "Times exclude waiting for the train",
                        simplified: "时间不含候车时间",
                        traditional: "時間不含候車時間"
                    )
                ) {
                    EmptyView()
                }
                rowDivider
            }

            if !boardingServiceHours.windows.isEmpty {
                detailRow(
                    icon: "clock.fill",
                    tint: .blue,
                    title: AppLocalization.text(english: "Service hours", simplified: "运营时间", traditional: "營運時間")
                ) {
                    // One row per service, never a merged range: merging the earliest first and
                    // latest last train turns 天通苑南's 22:51 southbound and 23:57 northbound into
                    // "5:03 – 23:57", true of neither platform.
                    let labels = distinguishedServiceLabels(boardingServiceHours.windows)
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Array(boardingServiceHours.windows.enumerated()), id: \.offset) { index, window in
                            VStack(alignment: .trailing, spacing: 1) {
                                if let label = labels[index] {
                                    Text(AppLocalization.text(
                                        english: "Toward \(label)",
                                        simplified: "开往 \(label)",
                                        traditional: "開往 \(label)"
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                                Text(verbatim: "\(window.firstTime ?? "—") – \(window.lastTime ?? "—")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        if let caveat = serviceDayCaveat(boardingServiceHours.serviceDayNote, on: Date()) {
                            Text(caveat)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                rowDivider
            }

            // The score grades station and network data, and a
            // walk uses neither.
            if route.boardingTransitSegment != nil {
            Button { detailDestination = .confidence(route.id) } label: {
                detailRow(
                    icon: "checkmark.seal.fill",
                    tint: confidence.level.color,
                    title: AppLocalization.text(english: "Confidence", simplified: "可信度", traditional: "可信度")
                ) {
                    ConfidenceScoreRing(
                        score: confidence.score,
                        color: confidence.level.color,
                        size: 30,
                        lineWidth: 3
                    )
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            }

            if departurePlan != nil {
                rowDivider
                reminderRow
            }

            rowDivider
            if tripLoggedConfirmation {
                detailRow(
                    icon: "checkmark.circle.fill",
                    tint: .green,
                    title: AppLocalization.text(english: "Trip logged", simplified: "行程已记录", traditional: "行程已記錄")
                ) { EmptyView() }
            } else {
                Button {
                    tripNote = ""
                    tripCardSheet = .tripNote
                } label: {
                    detailRow(
                        icon: "square.and.pencil",
                        tint: .accentColor,
                        title: AppLocalization.text(english: "Log this trip", simplified: "记录这次行程", traditional: "記錄這次行程")
                    ) { EmptyView() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            rowDivider
            // The chip needs a subject, and the subject needs to exist: on a walk or a drive there
            // are no stations, and "Not available" would claim a lookup failed that was never owed.
            if route.boardingTransitSegment != nil {
                detailRow(
                    icon: "building.columns.fill",
                    tint: .secondary,
                    title: AppLocalization.text(english: "Station data", simplified: "车站数据", traditional: "車站資料")
                ) {
                    DataConfidenceChip(confidence: decisionDataConfidence, compact: true)
                }
            }
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    /// Inset to clear the icon well, so the dividers separate the *text* column and the icons read
    /// as one vertical run.
    private var rowDivider: some View {
        Divider().padding(.leading, 56)
    }

    private func detailRow<Trailing: View>(
        icon: String,
        tint: Color,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var departurePlan: DeparturePlan? {
        route.departurePlan(anchor: tripAnchor)
    }

    /// Scheduled first and last trains for the boarding line, per direction; not a live countdown.
    /// Read from the operator through the planner, since no bundled pack carries operator
    /// timetables.
    private func loadServiceHours(cityID: String) async {
        guard let segment = route.boardingTransitSegment,
              let stationName = segment.fromStationName,
              let stationID = segment.fromStationID else {
            boardingServiceHours = .none
            return
        }
        let hours = await container.routePlanningService.boardingServiceWindows(
            stationID: stationID,
            stationName: stationName,
            cityID: segment.packCityID ?? cityID,
            lineName: segment.lineName
        )
        // Switching alternatives cancels this load; without the check a slow load for the old route
        // lands after the new one.
        guard !Task.isCancelled else { return }
        boardingServiceHours = hours
    }

    /// The journey as one continuous path: an unbroken vertical rail in each leg's colour and dash,
    /// with the line's badge where the rider boards. Ride legs expand to the stations they pass.
    private var journeyCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(route.segments.enumerated()), id: \.element.id) { index, segment in
                legRow(segment, index: index)
            }
            arrivalRow
        }
        .padding(.vertical, 2)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    private static let railWidth: CGFloat = 44
    private static let markerSize: CGFloat = 30
    /// Distance from a row's top edge to the top of its marker, so the marker lands on the title
    /// line rather than floating above it.
    private static let markerInset: CGFloat = 13

    private func legRow(_ segment: RouteSegment, index: Int) -> some View {
        let isExpanded = expandedLegs.contains(segment.id)
        return HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                JourneyRail(segment: segment)
                    // The first leg's rail starts at its own marker; drawn full height it would
                    // stick out of the top of the card like a trip that began somewhere else.
                    .padding(.top, index == 0 ? Self.markerInset + Self.markerSize / 2 : 0)
                legMarker(segment)
                    .padding(.top, Self.markerInset)
            }
            .frame(width: Self.railWidth)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(journeyTitle(segment, index: index))
                        .font(.body)
                        .fontWeight(.semibold)
                    Spacer(minLength: 4)
                    if segment.duration >= 60 {
                        Text(segment.formattedDuration)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if segment.type == .transfer {
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    } else if segment.type == .subway, !segment.stationStops.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                // Which way the train goes, the one question to answer before boarding. Absent when
                // the branch is ambiguous: the rider reads the sign rather than a guess.
                if let terminal = segment.transitContext?.directionTerminalStationName {
                    Text(AppLocalization.text(
                        english: "Toward \(terminal)",
                        simplified: "开往 \(terminal)",
                        traditional: "開往 \(terminal)"
                    ))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
                }
                // The stop after this one, which a rider checks against the platform sign when the
                // terminus is ambiguous or the sign lists a short-turn.
                if let next = segment.transitContext?.directionNextStationName {
                    Text(AppLocalization.text(
                        english: "Next stop \(next)",
                        simplified: "下一站 \(next)",
                        traditional: "下一站 \(next)"
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if let detail = journeyDetail(segment, index: index) {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // What is not known about this door (an estimated exit, nothing recorded step-free)
                // and the leg's own disclosures: an out-of-station change leaves the gates,
                // Beijing's 虚拟换乘 counts as one fare, a bike leg follows the pedestrian route or has
                // stairs, a distance is a straight-line guess. Kept with the leg they qualify.
                ForEach(legNotes(for: segment, index: index), id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
                liveArrivalsRow(for: segment)
                handoffRow(for: segment)
                bikeScannerRow(for: segment)
                if isExpanded {
                    stationStops(segment)
                }
            }
            .padding(.vertical, 12)
            .padding(.trailing, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch segment.type {
            case .transfer:
                detailDestination = .transfer(segment)
            case .subway where !segment.stationStops.isEmpty:
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedLegs.remove(segment.id) } else { expandedLegs.insert(segment.id) }
                }
            default:
                break
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stationStops(_ segment: RouteSegment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(segment.stationStops) { stop in
                Button { detailDestination = .station(stop) } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .strokeBorder(Color(hex: segment.colorHex), lineWidth: 2)
                            .frame(width: 7, height: 7)
                        Text(stop.name)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    /// Where the rider ends up, and when, so the path does not stop mid-air after the last leg.
    private var arrivalRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                JourneyRail(segment: route.segments.last)
                    .frame(height: Self.markerInset + Self.markerSize / 2)
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: Self.markerSize))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(.top, Self.markerInset)
            }
            .frame(width: Self.railWidth)

            VStack(alignment: .leading, spacing: 3) {
                Text(route.destination)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(arrivalDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 12)
            .padding(.trailing, 16)
            Spacer(minLength: 0)
        }
    }

    private var arrivalDetail: String {
        TripTimeContext(anchor: tripAnchor, totalDuration: route.totalDuration).arrivalDetail
    }

    @ViewBuilder
    private func legMarker(_ segment: RouteSegment) -> some View {
        switch segment.type {
        case .subway:
            LineBadge(
                name: segment.lineName ?? "",
                colorHex: segment.lineColorHex,
                size: Self.markerSize
            )
        case .transfer, .walking, .cycling, .driving:
            Image(systemName: segment.type.symbolName)
                .font(.system(size: Self.markerSize * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.markerSize, height: Self.markerSize)
                .background(Color(hex: segment.colorHex), in: Circle())
        }
    }

    /// Best effort, like the notices: no spinner, no error state; a route is usable without a
    /// countdown.
    private func loadBoardingArrivals(cityID: String) async {
        guard let boarding = route.boardingTransitSegment,
              let stationID = boarding.fromStationID else { return }
        let stations = await container.stationSearchService.stations(in: cityID)
        guard let station = stations.first(where: { $0.stationID == stationID }) else { return }
        let snapshot = await container.officialStationData.arrivalSnapshot(for: station)
        boardingArrivals = Array(
            snapshot.arrivals
                .filter(\.isLiveArrival)
                // The rider's own line: a countdown for another train is noise.
                .filter { boarding.lineName == nil || $0.lineName == boarding.lineName }
                .sorted { ($0.minutesRemaining ?? .max) < ($1.minutesRemaining ?? .max) }
                .prefix(3)
        )
    }

    /// When the next trains leave the platform the rider is about to stand on. Boarding segment
    /// only: a countdown for a later leg will have moved by the time they get there. Filtered to
    /// `isLiveArrival`, so no timetable is dressed as a countdown; cities without a live feed draw
    /// nothing.
    @ViewBuilder
    private func liveArrivalsRow(for segment: RouteSegment) -> some View {
        if segment.id == route.boardingTransitSegment?.id, !boardingArrivals.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.caption)
                Text(boardingArrivals.map(\.formattedArrival).joined(separator: " · "))
                    .font(.footnote)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.green)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AppLocalization.localized("Live arrivals"))
        }
    }

    /// The step between "cycle this bit" and cycling it: a shared bike in mainland China is
    /// unlocked by scanning its QR code in Alipay or WeChat.
    ///
    /// **It does not say a bike is here.** Just-Go has no bike-share data, so the button is named
    /// for its action and promises nothing about the outcome.
    @ViewBuilder
    private func bikeScannerRow(for segment: RouteSegment) -> some View {
        if segment.accessLegMode == .cycling {
            let scanners = ExternalRouteHandoff.bikeScanners()
            if !scanners.isEmpty {
                HStack(spacing: 8) {
                    ForEach(scanners) { scanner in
                        Button {
                            ExternalRouteHandoff.open(scanner)
                        } label: {
                            Label(scanner.title, systemImage: "qrcode.viewfinder")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// A bike or car leg's content: the apps that navigate a road, which this app does not. See
    /// `ExternalRouteHandoffCard`, shared with live guidance.
    @ViewBuilder
    private func handoffRow(for segment: RouteSegment) -> some View {
        let mode = segment.accessLegMode
        if segment.type.isAccessLeg, mode != .walking,
           let start = segment.polylineCoordinates.first,
           let end = segment.polylineCoordinates.last {
            ExternalRouteHandoffCard(
                mode: mode,
                origin: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude),
                originName: segment.fromStationName ?? route.origin,
                target: CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude),
                destinationName: segment.toStationName ?? route.destination
            )
        }
    }

    private func journeyTitle(_ segment: RouteSegment, index: Int) -> String {
        switch segment.type {
        case .subway:
            return segment.lineName ?? AppLocalization.localized("Transit")
        case .transfer:
            return AppLocalization.text(english: "Transfer", simplified: "换乘", traditional: "換乘")
        case .walking, .cycling, .driving:
            // The door is the point of an access leg, and the leg is measured to it, so it is named
            // here.
            guard let exit = exitName(for: index) else { return segment.summaryLabel }
            switch segment.type {
            case .cycling:
                return AppLocalization.text(
                    english: index == 0 ? "Cycle to \(exit)" : "Cycle from \(exit)",
                    simplified: index == 0 ? "骑行至 \(exit)" : "从 \(exit) 骑行",
                    traditional: index == 0 ? "騎行至 \(exit)" : "從 \(exit) 騎行"
                )
            case .driving:
                return AppLocalization.text(
                    english: index == 0 ? "Drive to \(exit)" : "Drive from \(exit)",
                    simplified: index == 0 ? "驾车至 \(exit)" : "从 \(exit) 驾车",
                    traditional: index == 0 ? "駕車至 \(exit)" : "從 \(exit) 駕車"
                )
            default:
                return AppLocalization.text(
                    english: index == 0 ? "Walk to \(exit)" : "Walk from \(exit)",
                    simplified: index == 0 ? "步行至 \(exit)" : "从 \(exit) 步行",
                    traditional: index == 0 ? "步行至 \(exit)" : "從 \(exit) 步行"
                )
            }
        }
    }

    /// Everything qualifying this leg, from the leg and from the door guide, deduplicated: one
    /// caveat printed twice reads as two problems.
    private func legNotes(for segment: RouteSegment, index: Int) -> [String] {
        var seen = Set<String>()
        let all = segment.accessibilityNotes + accessNotes(for: index) + doorAccessNotes(for: index)
        return all.filter { seen.insert($0).inserted }
    }

    /// What is known about the door just named: `RouteAccessPoint.isWheelchairLikely` and
    /// `.hasElevatorHint`. Positives only: the flags come from what a source asserted, so their
    /// absence is silence, not a negative finding.
    private func doorAccessNotes(for index: Int) -> [String] {
        guard let point = accessGuide(for: index)?.accessPoint else { return [] }
        var notes: [String] = []
        if point.isWheelchairLikely {
            notes.append(AppLocalization.text(
                english: "This entrance is recorded as step-free",
                simplified: "该出入口记录为无障碍",
                traditional: "該出入口記錄為無障礙"
            ))
        }
        if point.hasElevatorHint, !point.isWheelchairLikely {
            notes.append(AppLocalization.text(
                english: "This entrance is recorded as having a lift",
                simplified: "该出入口记录有电梯",
                traditional: "該出入口記錄有電梯"
            ))
        }
        return notes
    }

    private func journeyDetail(_ segment: RouteSegment, index: Int) -> String? {
        switch segment.type {
        case .subway:
            guard let from = segment.fromStationName, let to = segment.toStationName else { return nil }
            return "\(from) → \(to) · \(AppLocalization.stops(segment.stops))"
        case .transfer:
            return segment.fromStationName
        case .walking, .cycling, .driving:
            return AppLocalization.distance(segment.distance)
        }
    }

    /// The chosen door for whichever end this leg belongs to, when one was actually resolved.
    private func exitName(for index: Int) -> String? {
        accessGuide(for: index)?.accessPoint?.namedDoor
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
                // Capture the route id with the plan: the authorization prompt waits for the rider,
                // and switching alternatives meanwhile would file this under the other route.
                Task { await scheduleReminder(plan: departurePlan, routeID: route.id) }
            } label: {
                detailRow(
                    icon: reminderScheduled ? "bell.fill" : "bell",
                    tint: reminderScheduled ? .green : .orange,
                    title: reminderScheduled
                        ? AppLocalization.text(english: "Reminder set", simplified: "提醒已设置", traditional: "提醒已設定")
                        : AppLocalization.text(
                            english: "Remind me \(reminderLeadMinutes) min before departure",
                            simplified: "出发前\(reminderLeadMinutes)分钟提醒我",
                            traditional: "出發前\(reminderLeadMinutes)分鐘提醒我"
                        )
                ) { EmptyView() }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reminderScheduled)
            // One `.alert` registration for three reasons: two on one node shadow each other.
            .alert(
                reminderAlert?.title ?? "",
                isPresented: Binding(
                    get: { reminderAlert != nil },
                    set: { if !$0 { reminderAlert = nil } }
                ),
                presenting: reminderAlert
            ) { _ in
                Button(AppLocalization.localized("OK"), role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
        }
    }

    private func scheduleReminder(plan: DeparturePlan, routeID: UUID) async {
        guard plan.leaveByDate.addingTimeInterval(-Double(reminderLeadMinutes) * 60) > Date() else {
            reminderAlert = .tooLate
            return
        }
        guard await container.tripReminderService.requestAuthorization() else {
            reminderAlert = .denied
            return
        }
        let scheduled = await container.tripReminderService.scheduleReminder(plan: plan, leadMinutes: reminderLeadMinutes)
        if scheduled { scheduledReminderRouteID = routeID }
        // Not `.tooLate`, ruled out above: false means the system refused, most reachably the
        // 64-pending limit.
        if !scheduled { reminderAlert = .notScheduled }
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

/// Presented when a stop in the route's timeline is tapped: resolves it to a full `Station` and
/// shows the standard `StationDetailView`.
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
            // Match only with a real coordinate: a (0,0) placeholder disambiguates same-named
            // stations by distance to Null Island. Without one, the name-based fallback applies.
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
        // Resolves to a screen within 8 seconds whatever the lookup does, since `matchingStation`
        // can reach the network. The name-based fallback is a real screen; a late lookup still
        // wins, as it sets `station`.
        .task {
            try? await Task.sleep(for: .seconds(8))
            didResolve = true
        }
    }

    private var fallbackStation: Station {
        stop.asStation(cityID: cityID)
    }
}
