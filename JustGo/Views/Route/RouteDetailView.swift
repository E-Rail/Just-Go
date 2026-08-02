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
    @State private var scheduledReminderRouteID: UUID?
    @State var tripLoggedConfirmation = false
    @State private var showReminderDenied = false
    @State private var showReminderTooLate = false
    @State var tripNote = ""
    @State var detailDestination: RouteDetailDestination?
    @State private var expandedLegs: Set<UUID> = []
    @State private var boardingServiceWindows: [StationServiceWindow] = []
    /// Which of the three stops the trip sheet is resting at.
    @State private var tripCardDetent: PresentationDetent = .medium
    @State private var showsTripCard = false
    /// Guidance replaces this page's content rather than covering it — "but in the same page".
    @State private var isGuiding = false
    @State private var cityResources: [ExternalTransitResource] = []
    @State private var serviceNotices: [OperatorServiceNotice] = []
    @State private var openedNotice: OperatorServiceNotice?
    @State private var officialNoticeResource: ExternalTransitResource?
    // Raw theme hex for the "Navigate" button's solid fill — see RouteEntryView's
    // identical declaration for why `Color.accentColor` (dark-mode-lightened for
    // foreground use) isn't used as a fill under white text.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue
    // Once per detail instance, NOT reset on disappear: leaving the auto-entered navigator
    // re-fires onAppear, and a reset would immediately re-enter it.
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
        // Map on top, trip underneath, the boundary draggable — the shape every transit app the
        // rider already uses has. The map used to be a 200pt card buried between the journey and
        // the details, which is a strange place to put the only thing on the screen that shows
        // where the trip actually goes.
        return Group {
            if isGuiding {
                // The page becomes the navigator rather than presenting a second one over itself.
                // Same implementation as the full-screen entries below — the off-route recovery,
                // the arrival alert and the transfer surface all live in there, and a second
                // navigator built to sit inline would drift from this one.
                LiveGoView(route: route, embedded: true) {
                    isGuiding = false
                    ActiveTripStore.clear()
                }
                .safeAreaInset(edge: .bottom) { EmptyView() }
            } else {
                mapHeader()
            }
        }
        .background(Color.appBackground)
        // The trip rides in a real sheet with real detents, which is the system's own three-stop
        // slider: it snaps, it rubber-bands, it has the standard grabber, and VoiceOver and
        // Dynamic Type already know what it is. The hand-rolled drag handle this replaces had to
        // reimplement every one of those and got the snapping wrong.
        .sheet(isPresented: $showsTripCard) {
            tripCard(feasibility: feasibility, confidence: confidence)
        }
        // Presented from `.task` rather than inline so the sheet goes up after the push has
        // settled — a presentation raised during a navigation transition is the one that fails
        // with "whose view is not in the window hierarchy".
        .task { showsTripCard = !isGuiding }
        .onChange(of: isGuiding) { _, guiding in showsTripCard = !guiding }
        .navigationTitle(isGuiding
            ? AppLocalization.text(english: "Guidance", simplified: "导航中", traditional: "導航中")
            : AppLocalization.localized("Route Details"))
        .navigationBarTitleDisplayMode(.inline)
        // The trip is the whole screen from here on. A tab bar under the journey invites the rider
        // to leave mid-plan and takes a row of height from the thing they are reading.
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            // Step-by-Step Guidance (cognitive accessibility): go straight into the
            // guided navigator instead of the dense detail screen; dismissing it lands
            // on the full detail as usual.
            if appState.accessibilityPreference.stepByStepGuidance, !didAutoPresentLiveGo {
                didAutoPresentLiveGo = true
                ActiveTripStore.save(route)
                isGuiding = true
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["JUSTGO_DEBUG_SCREEN"] == "guiding" {
                ActiveTripStore.save(route)
                isGuiding = true
            }
            // The map divider is a drag, and drags cannot be injected in this environment, so its
            // range is verified by driving it to each end and screenshotting instead.
            switch ProcessInfo.processInfo.environment["JUSTGO_DEBUG_MAP_FRACTION"] {
            case "low": tripCardDetent = .fraction(0.3)
            case "medium": tripCardDetent = .medium
            case "top": tripCardDetent = .fraction(0.92)
            default: break
            }
            #endif
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
        .onChange(of: selectedRouteID) { _, _ in
            tripLoggedConfirmation = false
        }
        .onChange(of: routeSelectionSignature) {
            ensureSelectedRouteIsCurrent()
        }
        .task(id: routeDataKey) {
            boardingServiceWindows = []
            async let transferAssets: Void = container.officialStationData.prefetchTransferAssets(
                for: route
            )
            if let cityID = route.networkCityID ?? appState.selectedCity?.id {
                cityResources = await container.officialStationData
                    .cityExternalResources(for: [cityID])[cityID] ?? []
                if cityID == BeijingServiceNoticeProvider.cityID {
                    // Best effort by design: a failed or slow fetch leaves the card showing what
                    // is already verifiable. Operator notices are never a blocker.
                    serviceNotices = (try? await container.serviceNoticeProvider.notices()) ?? []
                }
                await loadServiceHours(cityID: cityID)
            }
            await transferAssets
        }
        .sheet(item: $officialNoticeResource) { resource in
            OfficialTransitResourceViewer(resource: resource)
        }
        .sheet(item: $openedNotice) { item in
            OfficialTransitResourceViewer(resource: Self.resource(for: item))
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
        let cityID = route.networkCityID ?? appState.selectedCity?.id ?? ""
        return cityID + "|" + selectedRouteID.uuidString
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
        VStack(alignment: .leading, spacing: 10) {
            // Duration and walking on the left, arrival on the right — the three numbers a rider
            // reads together when deciding whether this is the route they are taking.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(route.formattedDuration)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    // Three numbers on one line, and "1 hr 52 min" in a large rounded face is wide.
                    // Shrinking beats wrapping: a duration broken across two lines stops reading as
                    // one number at all.
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
            if let concern = heroConcern(feasibility: feasibility, confidence: confidence) {
                Label(concern.title, systemImage: concern.icon)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(concern.tint)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Stops, transfers and which door to go in by — the line Amap spends on "13站 · ¥5 · 玉泉路
    /// (C2东南口) 进站". There is no fare here and there will not be one: JustGo holds no fare data
    /// for any city, and a fare inferred from a stop count is exactly the guess this app refuses
    /// to make. The entrance is real — it is the door the plan actually routed the rider to.
    private var heroSummary: String {
        let stops = AppLocalization.text(
            english: "\(route.totalStops) stops",
            simplified: "\(route.totalStops) 站",
            traditional: "\(route.totalStops) 站"
        )
        var parts = [stops, route.formattedTransfers]
        if let entrance = route.originAccessGuide?.accessPoint?.namedDoor {
            parts.append(AppLocalization.text(
                english: "Enter at \(entrance)",
                simplified: "\(entrance) 进站",
                traditional: "\(entrance) 進站"
            ))
        }
        return parts.joined(separator: " · ")
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
        .padding(.top, 8)
        .padding(.bottom, 8)
        // Opaque now that this sits inside a sheet. It was transparent when the trip was the whole
        // page and the safeAreaInset alone kept content clear of it; in a sheet at the shortest
        // detent the scroll view is taller than the visible card, so rows ran on underneath the
        // capsule and showed either side of it.
        .background(Color.appBackground)
    }

    /// The trip as something to read, in the sheet over the map.
    private func tripCard(
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
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        // A `List` was the wrong container. Inset-grouped spacing is tuned for Settings, where
        // every section is an unrelated peer, and it opened this screen with roughly 250 pt of
        // empty space above the duration; worse, a list row cannot draw the unbroken vertical rail
        // that makes the legs read as one journey rather than five separate rows.
        .background(Color.appBackground)
        .safeAreaInset(edge: .bottom) { navigateBar }
        .presentationDetents(Self.tripCardDetents, selection: $tripCardDetent)
        .presentationDragIndicator(.visible)
        // The map behind stays live at the two lower stops — the whole point of putting the trip
        // on a sheet is that the map does not stop existing while it is up.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // There is nowhere for this to be dismissed *to*: the page underneath is the map for this
        // one route, and a trip card swiped away would leave a screen with no trip on it.
        .interactiveDismissDisabled()
    }

    // MARK: - Official notices

    /// What the operator says about riding this route today.
    ///
    /// Amap fills this space with live advisory text scraped from the operator. JustGo has no
    /// advisory feed, so it shows the two things it can actually stand behind and says where each
    /// came from: the service warnings it derives from official first/last-train data, and a link
    /// to the operator's own service-status page carrying the provider's name and the date that
    /// URL was last verified. An unverified guess dressed as an official notice is worse than an
    /// empty card, so when a city has neither, this draws nothing at all.
    @ViewBuilder
    private var officialNoticeCard: some View {
        let notice = route.serviceStatus.bannerText
        if notice != nil || officialResource != nil || !serviceNotices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if notice != nil {
                    ServiceStatusBanner(status: route.serviceStatus)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                ForEach(serviceNotices) { item in
                    if notice != nil || item.id != serviceNotices.first?.id { rowDivider }
                    Button { openedNotice = item } label: { noticeRow(item) }
                        .buttonStyle(.plain)
                }
                if !serviceNotices.isEmpty, officialResource != nil { rowDivider }
                if let resource = officialResource {
                    if notice != nil, serviceNotices.isEmpty { rowDivider.padding(.top, 8) }
                    Button {
                        officialNoticeResource = resource
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
                    // Provenance, not decoration: a rider deciding whether to trust this needs to
                    // know whose page it is and how stale our pointer to it might be.
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
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    /// The operator's own page for this city, best kind first.
    ///
    /// Only 3 of 58 cities publish a `serviceStatus` page — Beijing, the largest network here,
    /// publishes `operatorInformation` instead — so keying strictly on service status would draw
    /// nothing almost everywhere. The row is labelled with the resource's own title rather than a
    /// generic "Service status", so an operator-information page is never presented as an
    /// advisory feed it is not.

    /// Wraps a fetched notice so the existing official-resource viewer can open it — same
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
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                // The date is not decoration. Beijing publishes these irregularly, so a rider has
                // to be able to see they are reading something from May before acting on it.
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

    /// The three stops the trip card rests at. `.medium` and the two fractions rather than
    /// `.large`: a truly full-height sheet covers the navigation bar, and the rider would have no
    /// way back to the route list. The top stop deliberately leaves the bar showing.
    static let tripCardDetents: Set<PresentationDetent> = [.fraction(0.3), .medium, .fraction(0.92)]

    private func mapHeader() -> some View {
        TransitMapView(
            visibleRegion: .constant(route.previewRegion),
            stations: [],
            metroNetworks: [],
            route: route,
            showsUserLocation: false,
            onRegionChanged: nil,
            onStationSelected: { _ in }
        )
        .ignoresSafeArea(edges: .bottom)
        // Floating over the map's bottom edge rather than sitting in the scroll content: which
        // alternative is being shown is a property of the whole screen, and scrolling the journey
        // used to carry the answer off the top of it.
        .overlay(alignment: .bottom) {
            if alternatives.count > 1 {
                RouteTabs(routes: alternatives, selection: $selectedRouteID, floating: true)
                    .padding(.bottom, 10)
            }
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
    private func detailsCard(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        VStack(spacing: 0) {
            if let hours = boardingServiceHours {
                detailRow(
                    icon: "clock.fill",
                    tint: .blue,
                    title: AppLocalization.text(english: "Service hours", simplified: "运营时间", traditional: "營運時間")
                ) {
                    Text(verbatim: "\(hours.first) – \(hours.last)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                rowDivider
            }

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
                    showTripNote = true
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
            // Provenance needs a subject. On its own the chip said "Not available" under a section
            // header, naming nothing — a red badge for the rider to worry about with no way to tell
            // what it referred to.
            detailRow(
                icon: "building.columns.fill",
                tint: .secondary,
                title: AppLocalization.text(english: "Station data", simplified: "车站数据", traditional: "車站資料")
            ) {
                DataConfidenceChip(confidence: decisionDataConfidence, compact: true)
            }
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    /// The journey as one continuous path: an unbroken vertical rail running the height of the
    /// card, solid in each line's colour while riding and dashed while on foot, with the line's own
    /// badge marking where the rider boards.
    ///
    /// The legs used to be list rows carrying a 34 pt colour chip each — five disconnected bars
    /// that never said "this is one trip". Transit legs open to reveal the stations they pass,
    /// which is what a separate "Stations" card used to do a whole screen further down.
    private var journeyCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(route.segments.enumerated()), id: \.element.id) { index, segment in
                legRow(segment, index: index)
            }
            arrivalRow
        }
        .padding(.vertical, 2)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private static let railWidth: CGFloat = 44
    private static let markerSize: CGFloat = 30
    /// Distance from a row's top edge to the top of its marker, so the marker lands on the title
    /// line rather than floating above it.
    private static let markerInset: CGFloat = 13

    private func legRow(_ segment: RouteSegment, index: Int) -> some View {
        let isWalk = segment.type == .walking
        let isExpanded = expandedLegs.contains(segment.id)
        return HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                JourneyRail(color: journeyColor(segment), dashed: isWalk)
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
                if let detail = journeyDetail(segment, index: index) {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // What we do not know about this door — that an exit is estimated rather than
                // surveyed, or that nothing here is recorded as step-free. It rides with the leg
                // it qualifies, so removing the card it used to live in loses nothing.
                ForEach(accessNotes(for: index), id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
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
                            .strokeBorder(journeyColor(segment), lineWidth: 2)
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

    /// Where the rider ends up, and when. The last leg is a walk *from* a station, so without this
    /// the path simply stopped mid-air with no destination on it.
    private var arrivalRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                JourneyRail(color: journeyColor(route.segments.last))
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
        let timing = TripTimeContext(anchor: tripAnchor, totalDuration: route.totalDuration)
        let arrival = timing.arrivalDate.formatted(.dateTime.hour().minute())
        return AppLocalization.text(
            english: "Arrive \(arrival)",
            simplified: "\(arrival) 到达",
            traditional: "\(arrival) 到達"
        )
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
        case .transfer, .walking:
            Image(systemName: segment.type == .transfer ? "arrow.triangle.swap" : "figure.walk")
                .font(.system(size: Self.markerSize * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.markerSize, height: Self.markerSize)
                .background(journeyColor(segment), in: Circle())
        }
    }

    private func journeyColor(_ segment: RouteSegment?) -> Color {
        switch segment?.type {
        case .subway: return Color(hex: segment?.lineColorHex ?? "#007AFF")
        case .transfer: return .orange
        case .walking, nil: return .gray
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
                // Capture the route ID with the plan: the auth prompt inside
                // scheduleReminder awaits user input, and a tab switch during it
                // would otherwise file this plan under the newly-shown route.
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
