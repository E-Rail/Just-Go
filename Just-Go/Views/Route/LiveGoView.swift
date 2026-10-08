import SwiftUI
import MapKit
import AVFoundation
import CoreLocation

private struct LiveTransferGuidance {
    let stepID: Int
    let stationTitle: String
    let externalResources: [ExternalTransitResource]
}

private struct LiveTransferGuidanceRequest: Hashable {
    let routeID: UUID
    let stepID: Int
}

/// The step-by-step trip companion: a full-screen interactive map with the whole route drawn on it,
/// a compact instruction panel, and off-route re-planning while walking.
///
/// The trip itself lives in `TripSession`, which moves it on by the clock and by location, so this
/// screen shows a trip and does not own one: leaving it leaves the trip running.
struct LiveGoView: View {
    /// Rendered inside the route detail rather than over it: this drops the navigation chrome only
    /// a presented copy needs and hands the exit to its host. One navigator, two containers.
    var embedded = false
    let onExit: () -> Void

    /// The route this screen was opened with. The session's own route replaces it once the trip
    /// has started, and a re-plan from the rider's location replaces that.
    private let initialRoute: Route
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(DIContainer.self) private var container
    @AppStorage("arrivalAlertEnabled") private var arrivalAlertEnabled = true
    // Read directly rather than via `Color.accentColor`: in a full-screen cover the first frame
    // does not yet have the root `.tint` and would flash system blue.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue
    @Environment(AppState.self) private var appState
    @State private var showGetOffBanner = false
    @State private var getOffBannerTask: Task<Void, Never>?
    // Accessibility step-change effects (无障碍 sheet): speech, haptics, visual banner.
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var announcedStep: TripStep?
    @State private var announcementTask: Task<Void, Never>?
    // Live-navigation map + off-route recovery.
    @State private var mapRegion: MapVisibleRegion?
    @State private var isRerouting = false
    @State private var offRouteStrikes = 0
    @State private var lastRerouteAt = Date.distantPast
    /// How long to wait before the next reroute, doubling until the rider advances. Each re-plan is
    /// a full plan (several MapKit legs and a metered transit call), so a rider taking their own
    /// street is backed off, while a genuine wrong turn is still answered quickly.
    @State private var rerouteInterval: TimeInterval = 45
    @State private var rerouteNotice: String?
    @State private var rerouteNoticeTask: Task<Void, Never>?
    @State private var rerouteTask: Task<Void, Never>?
    // Transfer guidance is loaded lazily only while its transfer step is current.
    @State private var transferGuidance: LiveTransferGuidance?
    @State private var isLoadingTransferGuidance = false
    /// Speech during guidance, persisted so a muted rider stays muted. On by default: "Navigate"
    /// means speaking. The Accessibility toggle overrides it; see `onAppear`.
    @AppStorage("guidanceVoiceEnabled") private var voiceEnabled = true
    /// Whether the camera tracks the rider: on while guiding, off when stepping through manually so
    /// the map stays on the step being read.
    @State private var followsRider = true

    private var themeColor: Color { Color.adaptive(hex: selectedThemeHex) }

    private var session: TripSession { container.tripSession }
    private var route: Route { session.route ?? initialRoute }

    init(route: Route, embedded: Bool = false, onExit: @escaping () -> Void) {
        self.embedded = embedded
        self.onExit = onExit
        initialRoute = route
    }

    /// Presented, this owns a navigation stack; embedded, the host already has one.
    private var navigatorSurface: some View {
        Group {
            if embedded {
                surface
            } else {
                NavigationStack { surface }
            }
        }
    }

    private var surface: some View {
        Group {
                if isActiveTransferStep {
                    transferStepSurface
                } else {
                    // The panel is a safe-area inset, not a `ZStack` overlay, so MapKit knows the
                    // space is taken and lays out its labels, controls and legal attribution where
                    // the rider can see them, while the map still draws full-bleed.
                    liveMap
                        .ignoresSafeArea(edges: .bottom)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            instructionPanel
                        }
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if isRerouting {
                        noticeBanner(
                            text: AppLocalization.text(english: "Rerouting…", simplified: "正在重新规划…", traditional: "正在重新規劃…"),
                            icon: "arrow.triangle.2.circlepath",
                            showsSpinner: true
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else if let rerouteNotice {
                        noticeBanner(text: rerouteNotice, icon: "arrow.triangle.2.circlepath")
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if showGetOffBanner {
                        getOffBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let announcedStep {
                        announcementBanner(announcedStep)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle(embedded ? "" : transferNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    // Presented, there is no back button to leave by, and End is not leaving.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onExit()
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .accessibilityLabel(AppLocalization.text(
                            english: "Hide guidance, keep the trip running",
                            simplified: "收起导航，行程继续",
                            traditional: "收起導航，行程繼續"
                        ))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(AppLocalization.localized("Done")) { exit() }
                    }
                }
            }
    }

    /// End or Done: the trip is over, and the session completes it in the rider's history.
    private func exit() {
        session.end()
        onExit()
    }

    var body: some View {
        navigatorSurface
        .onAppear {
            // Starts the trip, or finds it already running: the session keeps the fixes, the clock
            // and the alerts going whether or not this screen is up.
            session.start(initialRoute)
            // The Accessibility toggle is a promise, not a preference: a rider who turned on
            // Audio Navigation gets it, whatever the mute button was last left at.
            if appState.accessibilityPreference.audioNavigation { voiceEnabled = true }
            followsRider = true
            keepScreenOnWhileWalking()
            frameCurrentStep()
            announceCurrentStep()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            getOffBannerTask?.cancel()
            showGetOffBanner = false
            speechSynthesizer.stopSpeaking(at: .immediate)
            announcementTask?.cancel()
            rerouteNoticeTask?.cancel()
            rerouteTask?.cancel()
        }
        .onChange(of: session.currentIndex) { _, _ in
            // Follow-me is turned off by the Back and Next buttons themselves, not here: the trip
            // also moves on by itself, and the rider did not ask to stop being followed.
            keepScreenOnWhileWalking()
            frameCurrentStep()
            announceCurrentStep()
        }
        .onChange(of: session.alightingSoonStep) { _, step in
            raiseGetOffBanner(for: step)
        }
        .onChange(of: arrivalAlertEnabled) { _, _ in session.alertPreferenceChanged() }
        // Observes the raw fix, which is what changes, but hands on the corrected one: off-route
        // detection, the arrival alert and the reroute origin measure against GCJ-02 route
        // geometry, and a raw WGS-84 fix is ~540 m off. See `LocationService.mapSpaceCorrection`.
        .onChange(of: container.locationService.currentLocation) { _, _ in
            handleLocationUpdate(container.locationService.mapSpaceLocation)
        }
        .task(id: transferGuidanceRequest) {
            guard let request = transferGuidanceRequest else {
                transferGuidance = nil
                isLoadingTransferGuidance = false
                return
            }
            await loadTransferGuidance(for: request)
        }
        .task(id: route.id) {
            await container.officialStationData.prefetchTransferAssets(for: route)
        }
    }

    // MARK: - Transfer step

    private var transferGuidanceRequest: LiveTransferGuidanceRequest? {
        guard let step = session.currentStep, step.kind == .transfer else { return nil }
        return LiveTransferGuidanceRequest(routeID: route.id, stepID: step.id)
    }

    private var isActiveTransferStep: Bool {
        session.currentStep?.kind == .transfer
    }

    private var transferNavigationTitle: String {
        guard isActiveTransferStep else {
            return AppLocalization.text(english: "Go", simplified: "出发", traditional: "出發")
        }
        return activeTransferGuidance?.stationTitle
            ?? session.currentStep?.fromStationName
            ?? AppLocalization.localized("Transfer station")
    }

    private var activeTransferGuidance: LiveTransferGuidance? {
        guard let step = session.currentStep,
              step.kind == .transfer,
              let transferGuidance,
              transferGuidance.stepID == step.id else { return nil }
        return transferGuidance
    }

    private var transferStepSurface: some View {
        VStack(spacing: 0) {
            transferStatusContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            instructionPanel
        }
        .background(Color.appBackground)
    }

    /// The measured walk between the two platforms, read off the leg the planner already costed.
    /// When nothing was measured (an in-station change often has nothing), this shows nothing
    /// rather than an invented number.
    @ViewBuilder
    private var transferCorridorSection: some View {
        if let metres = session.currentStep.flatMap(measuredCorridorMetres(for:)) {
            let pace = TransferPace(distanceMetres: metres)
            HStack(spacing: 10) {
                Image(systemName: pace.icon)
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // "Walking distance", not "transfer time": the metres were measured, the
                    // seconds were not.
                    Text(AppLocalization.text(
                        english: "Walking distance between platforms",
                        simplified: "站台之间的步行距离",
                        traditional: "月台之間的步行距離"
                    ))
                    .rowMeta()
                    // Leads with the metres, the observed part; the bucket is this app's walking
                    // model applied to them. The unit comes from `AppLocalization.distance`: the
                    // localization validator skips interpolated literals, so a spliced " m " would
                    // pass it.
                    Text("\(AppLocalization.distance(Double(metres))) · \(pace.title)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .padding(.horizontal, 24)
        }
    }

    /// The corridor the planner measured for this step's change, matched by the two stations the
    /// leg joins.
    private func measuredCorridorMetres(for step: TripStep) -> Int? {
        guard step.kind == .transfer, let station = step.fromStationName else { return nil }
        return route.segments.first {
            $0.type == .transfer && $0.fromStationName == station && $0.measuredCorridorMetres != nil
        }?.measuredCorridorMetres
    }

    @ViewBuilder
    private var transferStatusContent: some View {
        if isLoadingTransferGuidance, activeTransferGuidance == nil {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(AppLocalization.text(
                    english: "Loading transfer information…",
                    simplified: "正在加载换乘信息…",
                    traditional: "正在載入轉乘資訊…"
                ))
                .font(.headline)
            }
            .padding(24)
            .accessibilityElement(children: .combine)
        } else if let guidance = activeTransferGuidance {
            VStack(spacing: 12) {
                Image(systemName: SegmentType.transfer.symbolName)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color(hex: SegmentType.transfer.colorHex(line: nil)))
                    .accessibilityHidden(true)
                Text(guidance.stationTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text(AppLocalization.text(
                    english: "Follow station signs for this transfer",
                    simplified: "本次换乘请以站内标识为准",
                    traditional: "本次轉乘請以站內標識為準"
                ))
                .font(.headline)
                .multilineTextAlignment(.center)
                transferNotes
                ForEach(guidance.externalResources.filter(\.kind.isTransferRelevant)) { resource in
                    OfficialTransitResourceButton(resource: resource, compact: true)
                }
                if guidance.externalResources.contains(where: { $0.kind.isTransferRelevant }) {
                    Text(AppLocalization.text(
                        english: "Straight from the operator, for reference.",
                        simplified: "由运营方提供，仅供参考。",
                        traditional: "由營運方提供，僅供參考。"
                    ))
                        .rowMeta()
                        .multilineTextAlignment(.center)
                }
                transferCorridorSection
                    .padding(.horizontal, -24)
            }
            .padding(24)
            .accessibilityElement(children: .contain)
        } else {
            VStack(spacing: 18) {
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(
                            english: "Transfer information unavailable",
                            simplified: "暂无换乘信息",
                            traditional: "暫無轉乘資訊"
                        ),
                        systemImage: "signpost.right"
                    )
                } description: {
                    Text(AppLocalization.text(
                        english: "Follow station signs for this transfer.",
                        simplified: "本次换乘请以站内标识为准。",
                        traditional: "本次轉乘請以站內標識為準。"
                    ))
                }
                transferNotes
                    .padding(.horizontal, 24)
                transferCorridorSection
            }
            .padding(.vertical, 24)
        }
    }

    /// What the route worked out about this change, shown where the rider is making it: whether it
    /// leaves the paid area and, only where the operator says so, that it still counts as one
    /// journey. Silence where the fare is unknown comes from the assembler: the rider can read the
    /// gates.
    @ViewBuilder
    private var transferNotes: some View {
        let notes = session.currentStep?.kind == .transfer ? (session.currentStep?.notes ?? []) : []
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private func loadTransferGuidance(for request: LiveTransferGuidanceRequest) async {
        transferGuidance = nil
        isLoadingTransferGuidance = true
        defer {
            if request == transferGuidanceRequest {
                isLoadingTransferGuidance = false
            }
        }
        guard request == transferGuidanceRequest,
              let step = session.currentStep,
              step.id == request.stepID,
              let segmentIndex = step.segmentIndex,
              route.segments.indices.contains(segmentIndex) else { return }

        let transferSegment = route.segments[segmentIndex]
        let context = step.transferContext ?? transferSegment.transferContext
        let cityID = context?.cityID ?? route.networkCityID ?? ""
        let stationName = context?.stationName
            ?? step.fromStationName
            ?? AppLocalization.localized("Transfer station")
        let stationID = context?.stationID
            ?? transferSegment.toStationID
            ?? transferSegment.fromStationID
            ?? stationName
        guard !cityID.isEmpty else { return }

        let coordinate = step.transferCLCoordinate
        let station = Station(
            stationID: stationID,
            name: stationName,
            latitude: coordinate?.latitude ?? 0,
            longitude: coordinate?.longitude ?? 0,
            cityID: cityID,
            isTransferStation: true
        )
    let externalResources = await container.officialStationData.externalResources(for: station)
    guard !Task.isCancelled, request == transferGuidanceRequest else { return }

    transferGuidance = LiveTransferGuidance(
        stepID: step.id,
        stationTitle: stationName,
        externalResources: externalResources
    )
    isLoadingTransferGuidance = false
}

    // MARK: - Map

    /// The same map, drawn by the same code, as the route detail: a leg looks identical on both.
    private var liveMap: some View {
        TransitMapView(
            visibleRegion: $mapRegion,
            stations: route.mapStations,
            alwaysShowsStations: true,
            metroNetworks: [],
            route: route,
            showsUserLocation: true,
            onUserLocationChanged: { container.locationService.observeMapSpaceUserLocation($0) },
            onRegionChanged: { mapRegion = $0 },
            onStationSelected: { _ in }
        )
    }

    /// Frames the current step's geometry. The rider stays free to pan and zoom afterwards; only a
    /// step change, a reroute or turning follow-me off moves the camera.
    private func frameCurrentStep() {
        guard let step = session.currentStep else { return }
        let segment = step.segmentIndex.flatMap { route.segments.indices.contains($0) ? route.segments[$0] : nil }
        var coordinates: [CodableCoordinate]
        switch step.kind {
        case .walkToStation, .walkToDestination: coordinates = step.walkingPathCoordinates
        case .transfer: coordinates = step.transferCoordinate.map { [$0] } ?? []
        case .ride: coordinates = segment?.drawableCoordinates ?? []
        case .arrive: coordinates = route.groundDestination.map { [$0] } ?? []
        }
        let points = coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        if let region = MapVisibleRegion(fitting: points, minimumSpan: 0.006) {
            mapRegion = region
        }
    }

    // MARK: - Off-route recovery

    /// Metres a second. Faster than a rider runs for a train, and slower than a train anywhere but
    /// its last few metres into a platform. An unknown speed is reported as negative and passes.
    private static let fastestWalk: CLLocationSpeed = 4

    /// Off-route detection runs only on walking steps with a decent fix: underground, GPS drifts or
    /// vanishes, and rerouting on tunnel noise would re-plan a trip the rider is following
    /// correctly.
    private func handleLocationUpdate(_ location: CLLocation?) {
        // Centre on the rider while they follow, at `MapCameraSpan.station`, the app's tightest
        // existing scale.
        if followsRider, let location, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 {
            mapRegion = MapVisibleRegion(
                center: location.coordinate,
                latitudeDelta: MapCameraSpan.station,
                longitudeDelta: MapCameraSpan.station
            )
        }
        guard let location,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 65,
              let step = session.currentStep,
              // Only a walk the rider is known to be on. One the clock alone has reached is a
              // guess: a train running a minute late above ground is still on the track, far from
              // a walk the estimate has already begun, and re-planning from there replaces a trip
              // the rider is following correctly.
              session.position?.basis != .estimated,
              // And nobody walks at this speed. A fix can end a ride a few hundred metres short of
              // the platform, and the train is then still rolling in, off the walk's path.
              location.speed <= Self.fastestWalk,
              // Only walking legs: off-route detection is tuned to a 100 m pedestrian corridor, and
              // a bike or car leg is handed to another app.
              step.accessMode == .walking,
              step.kind == .walkToStation || step.kind == .walkToDestination else {
            offRouteStrikes = 0
            return
        }
        let path = step.walkingPathCLCoordinates
        guard path.count >= 2 else { return }
        if distance(from: location.coordinate, toPolyline: path) > 100 {
            offRouteStrikes += 1
        } else {
            offRouteStrikes = 0
        }
        // Two consecutive off-corridor fixes (the distance filter is 10 m, so this is movement, not
        // jitter) and a cooldown, so a failed or just-finished re-plan does not fire again at once.
        guard offRouteStrikes >= 2, !isRerouting,
              Date().timeIntervalSince(lastRerouteAt) > rerouteInterval else { return }
        offRouteStrikes = 0
        // Stored, so closing the navigator cancels it; a reroute left running would write its route
        // into `ActiveTripStore` for a journey the rider has left.
        rerouteTask?.cancel()
        rerouteTask = Task { await reroute(from: location.coordinate) }
    }

    @MainActor
    private func reroute(from coordinate: CLLocationCoordinate2D) async {
        guard let ground = route.groundDestination else { return }
        let destination = CLLocationCoordinate2D(latitude: ground.latitude, longitude: ground.longitude)
        // Read now: the plan below takes seconds, and the trip's clock does not wait for it.
        let headedForATrain = session.currentStep?.kind == .walkToStation
            && route.boardingTransitSegment != nil
        isRerouting = true
        lastRerouteAt = Date()
        rerouteInterval = min(rerouteInterval * 2, 480)
        defer { isRerouting = false }

        let preference = appState.accessibilityPreference
        do {
            let routes = try await container.routePlanningService.planRoute(
                from: TransitPlace(
                    name: AppLocalization.localized("Current Location"),
                    coordinate: coordinate,
                    source: .currentLocation
                ),
                to: TransitPlace(name: session.plan.destination, coordinate: destination, source: .mapKit),
                accessibilityFilter: AccessibilityFilter(
                    requiresWheelchairAccess: preference.requiresWheelchairAccess,
                    requiresElevator: preference.prefersElevator,
                    avoidStairs: preference.avoidStairs,
                    maxWalkingDistance: preference.maxWalkingDistance
                )
            )
            // Ranked the way the results list ranks them, boardable first; the planner's own order
            // can put a drive or a shut line first. A rider walking to their train is re-planned
            // onto a train trip, where time alone would bring a short one back as something else.
            // One already off their last train wants the quickest way from here.
            let ranked = container.routePlanningService.sortRoutes(
                routes,
                by: headedForATrain ? .metroFirst : .fastest,
                preferences: preference
            )
            // On foot, as the rider is: off-route detection runs on walking legs only, and nobody
            // who strayed from a walk wants to be told to get in a car.
            let onFoot = ranked.first { $0.segments.allSatisfy { $0.accessLegMode == .walking } }
            guard let newRoute = onFoot ?? ranked.first else { throw RoutePlanningError.noRouteFound }
            // The plan can outlive the screen (`MKLocalSearch` ignores cancellation), and nothing
            // below should happen to a trip the rider has left.
            guard !Task.isCancelled else { return }
            // From any step but the first, the index change runs framing and the announcement
            // through `onChange`; doing it here too would speak the step twice.
            let indexChanges = session.currentIndex != 0
            // A fresh plan from where the rider actually is: the next divergence is new information.
            rerouteInterval = 45
            session.reroute(with: newRoute)
            transferGuidance = nil
            if !indexChanges {
                frameCurrentStep()
                announceCurrentStep()
            }
            showRerouteNotice(AppLocalization.text(
                english: "Route updated from your location",
                simplified: "已根据您的位置更新路线",
                traditional: "已根據您的位置更新路線"
            ))
        } catch {
            showRerouteNotice(AppLocalization.text(
                english: "Couldn't reroute, so the original route stands",
                simplified: "重新规划失败，继续按原路线导航",
                traditional: "重新規劃失敗，繼續按原路線導航"
            ))
        }
    }

    private func showRerouteNotice(_ text: String) {
        rerouteNoticeTask?.cancel()
        withAnimation { rerouteNotice = text }
        rerouteNoticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { rerouteNotice = nil }
        }
    }

    /// Minimum distance from a point to a polyline (point-to-segment projections in a
    /// small local planar frame: exact enough at street scale).
    private func distance(from coordinate: CLLocationCoordinate2D, toPolyline path: [CLLocationCoordinate2D]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for index in 0..<(path.count - 1) {
            let a = path[index]
            let b = path[index + 1]
            let metersPerDegreeLongitude = 111_320.0 * cos(a.latitude * .pi / 180)
            let metersPerDegreeLatitude = 110_540.0
            let ax = a.longitude * metersPerDegreeLongitude, ay = a.latitude * metersPerDegreeLatitude
            let bx = b.longitude * metersPerDegreeLongitude, by = b.latitude * metersPerDegreeLatitude
            let px = coordinate.longitude * metersPerDegreeLongitude, py = coordinate.latitude * metersPerDegreeLatitude
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
            let qx = ax + t * dx, qy = ay + t * dy
            best = min(best, ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot())
        }
        return best
    }

    // MARK: - Instruction panel

    private var instructionPanel: some View {
        VStack(spacing: 12) {
            ProgressView(value: session.progressFraction)
                .tint(themeColor)

            if let step = session.currentStep {
                stepSummary(step)
                    .id(step.id)
                    .transition(.opacity)
            }

            controls
        }
        .padding(16)
        // `.thickMaterial`: a thinner one lets parks and water tint the panel, and this is the one
        // surface that must stay readable while walking.
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .elevated(.floating)
        .padding([.horizontal, .bottom], 12)
        // Clear of a tab bar the system has moved to the trailing edge. Outside the material, so
        // the panel moves rather than its background stretching.
        .safeAreaPadding(.horizontal)
    }

    private func stepSummary(_ step: TripStep) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(for: step))
                    .font(.title)
                    .foregroundStyle(color(for: step))
                    // The glyph is the one thing on this panel that says what the rider is doing
                    // right now, so it animates when it changes rather than swapping silently.
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    if let detail = step.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(session.progressText)
                        .rowMeta()
                    basisLabel
                }
            }

            roadHandoff(for: step)

            if stopsLeftText(for: step) != nil || (step.kind == .ride && step.exitHint?.isEmpty == false) {
                HStack(spacing: 12) {
                    if let stopsLeft = stopsLeftText(for: step) {
                        Text(stopsLeft)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(themeColor)
                            .contentTransition(.numericText())
                    }
                    if step.kind == .ride, let exit = step.exitHint, !exit.isEmpty {
                        Label(
                            AppLocalization.text(english: "Get off toward \(exit)", simplified: "下车走向\(exit)", traditional: "下車走向\(exit)"),
                            systemImage: "arrow.up.forward.circle.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(themeColor)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(0.8)
                    }
                    Spacer()
                }
            }

            // Where to stand up, named by the stop before the rider's: "one more stop" and "get off
            // next" are different instructions.
            if let readyToAlight = step.readyToAlightText {
                HStack(spacing: 12) {
                    Label(readyToAlight, systemImage: "figure.stand")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                }
            }

            if step.kind == .ride, session.position?.departureKnown == false {
                boardedButton
            }

            if step.kind == .ride {
                Toggle(isOn: $arrivalAlertEnabled) {
                    Label(
                        AppLocalization.text(english: "Alert before getting off", simplified: "下车前提醒我", traditional: "下車前提醒我"),
                        systemImage: "bell.badge"
                    )
                    .font(.subheadline)
                }
                .tint(themeColor)
            }
        }
        // `.contain`, not `.combine`: combining folds the exit chip, the get-ready cue and the
        // alert toggle into one label, leaving VoiceOver without the exit hint or a focusable
        // switch.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(step.accessibilityLabel)
    }

    /// Stops still ahead on a ride, counted down as the trip moves. The step's own count until the
    /// session has a position to read.
    private func stopsLeftText(for step: TripStep) -> String? {
        guard step.kind == .ride else { return nil }
        guard let remaining = session.position?.stopsRemaining else { return step.rideStopsRemainingText }
        if remaining == 1 {
            return AppLocalization.text(english: "Get off at the next stop", simplified: "下一站下车", traditional: "下一站下車")
        }
        guard let next = session.position?.nextStopName else { return AppLocalization.stopsLeft(remaining) }
        return AppLocalization.text(
            english: "\(AppLocalization.stopsLeft(remaining)) · next \(next)",
            simplified: "\(AppLocalization.stopsLeft(remaining)) · 下一站\(next)",
            traditional: "\(AppLocalization.stopsLeft(remaining)) · 下一站\(next)"
        )
    }

    /// How the step on screen is known. Nothing when the rider said so themselves: they know.
    @ViewBuilder
    private var basisLabel: some View {
        switch session.position?.basis {
        case .located:
            Label(
                AppLocalization.text(english: "Located", simplified: "已定位", traditional: "已定位"),
                systemImage: "location.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
        case .estimated:
            Label(
                AppLocalization.text(english: "Estimated", simplified: "估算", traditional: "估算"),
                systemImage: "clock"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        case .confirmed, nil:
            EmptyView()
        }
    }

    /// The one moment the clock cannot work out: when the train left. Offered until the rider says,
    /// or a later stop is seen.
    private var boardedButton: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.notify(.success)
                session.confirmBoarded()
            } label: {
                Label(
                    AppLocalization.text(english: "I'm on the train", simplified: "我已上车", traditional: "我已上車"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline)
                .fontWeight(.medium)
                // The button keeps its one line and the note beside it takes the wrapping.
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: Metrics.minimumTapTarget)
                .background(themeColor.opacity(0.18), in: Capsule())
                .foregroundStyle(themeColor)
            }
            .buttonStyle(.plain)
            Text(AppLocalization.text(
                english: "Counts the stops from now",
                simplified: "从现在开始计站",
                traditional: "從現在開始計站"
            ))
            .rowMeta()
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// A bike or car leg inside guidance. The step stays in the sequence (the rider does cross this
    /// ground), but with no turn-by-turn for a road, the panel offers the apps that have it.
    @ViewBuilder
    private func roadHandoff(for step: TripStep) -> some View {
        if step.accessMode != .walking,
           step.kind == .walkToStation || step.kind == .walkToDestination,
           let start = step.walkingPathCLCoordinates.first,
           let end = step.walkingPathCLCoordinates.last {
            ExternalRouteHandoffCard(
                mode: step.accessMode,
                origin: start,
                originName: step.fromStationName ?? route.origin,
                target: end,
                destinationName: step.toStationName ?? route.destination
            )
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                guidanceToggle(
                    isOn: voiceEnabled,
                    onImage: "speaker.wave.2.fill",
                    offImage: "speaker.slash.fill",
                    label: voiceEnabled
                        ? AppLocalization.text(english: "Mute voice", simplified: "静音", traditional: "靜音")
                        : AppLocalization.text(english: "Unmute voice", simplified: "取消静音", traditional: "取消靜音")
                ) {
                    voiceEnabled.toggle()
                    if !voiceEnabled { speechSynthesizer.stopSpeaking(at: .immediate) }
                }

                guidanceToggle(
                    isOn: followsRider,
                    onImage: "location.fill",
                    offImage: "location",
                    label: AppLocalization.text(
                        english: "Follow my location",
                        simplified: "跟随我的位置",
                        traditional: "跟隨我的位置"
                    )
                ) {
                    followsRider.toggle()
                    if followsRider {
                        handleLocationUpdate(container.locationService.mapSpaceLocation)
                    } else {
                        frameCurrentStep()
                    }
                }

                Spacer(minLength: 0)

                Button { exit() } label: {
                    Text(AppLocalization.text(english: "End", simplified: "结束", traditional: "結束"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 14)
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .background(Color.secondary.opacity(0.16), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }

            StepControlPair(back: { backButton }, next: { nextButton })
        }
    }

    private func guidanceToggle(
        isOn: Bool,
        onImage: String,
        offImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? onImage : offImage)
                .font(.subheadline)
                .tappable()
                .background(isOn ? themeColor.opacity(0.18) : Color.secondary.opacity(0.16), in: Circle())
                .foregroundStyle(isOn ? themeColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var backButton: some View {
        Button {
            // Reading back is an explicit request to look at that step, not at where you are.
            followsRider = false
            withAnimation { session.goBack() }
        } label: {
            StepSecondaryButtonLabel(
                title: AppLocalization.text(english: "Back", simplified: "上一步", traditional: "上一步"),
                systemImage: "chevron.left"
            )
        }
        .buttonStyle(.plain)
        .disabled(!session.canGoBack)
        .opacity(session.canGoBack ? 1 : 0.4)
    }

    private var nextButton: some View {
        Button {
            if session.canAdvance {
                followsRider = false
                withAnimation { session.advance() }
            } else {
                exit()
            }
        } label: {
            StepPrimaryButtonLabel(
                title: session.canAdvance
                    ? AppLocalization.text(english: "Next", simplified: "下一步", traditional: "下一步")
                    : AppLocalization.localized("Done"),
                systemImage: session.canAdvance ? "chevron.right" : "checkmark",
                fillHex: selectedThemeHex
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Announcements & alerts

    /// Applies the enabled accessibility effects for the step now showing: spoken
    /// instruction (语音导航), haptic (振动提醒), and a transient banner (视觉播报).
    private func announceCurrentStep() {
        guard let step = session.currentStep else { return }
        let preference = appState.accessibilityPreference
        if preference.vibrationAlerts {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        if voiceEnabled {
            speechSynthesizer.stopSpeaking(at: .immediate)
            let separator = AppLocalization.isChinese ? "。" : ". "
            let utterance = AVSpeechUtterance(string: [step.title, step.detail].compactMap { $0 }.joined(separator: separator))
            utterance.voice = AVSpeechSynthesisVoice(language: AppLocalization.isChinese ? "zh-CN" : "en-US")
            speechSynthesizer.speak(utterance)
        }
        if preference.visualAnnouncements {
            announcementTask?.cancel()
            withAnimation { announcedStep = step }
            announcementTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation { announcedStep = nil }
            }
        }
    }

    private func announcementBanner(_ step: TripStep) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: step))
            Text(step.title)
                .fontWeight(.semibold)
                .lineLimit(2)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(hex: selectedThemeHex), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    private func noticeBanner(text: String, icon: String, showsSpinner: Bool = false) -> some View {
        HStack(spacing: 10) {
            if showsSpinner {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: icon)
            }
            Text(text)
                .fontWeight(.semibold)
                .lineLimit(2)
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: selectedThemeHex), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .elevated(.floating)
    }

    /// Takes the step, not just its kind: the two access kinds cover walking, cycling and driving.
    private func icon(for step: TripStep) -> String {
        switch step.kind {
        case .walkToStation, .walkToDestination: return step.accessMode.symbolName
        case .ride: return SegmentType.subway.symbolName
        case .transfer: return SegmentType.transfer.symbolName
        case .arrive: return "flag.checkered"
        }
    }

    /// The leg's own colour, as the rail and the map draw it. Arrival is not a leg.
    private func color(for step: TripStep) -> Color {
        step.colorHex.map { Color(hex: $0) } ?? .green
    }

    private var getOffBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.text(english: "Get ready to get off", simplified: "准备下车", traditional: "準備下車"))
                    .font(.headline)
                if let to = session.currentStep?.toStationName {
                    Text(to)
                        .font(.subheadline)
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: selectedThemeHex), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .foregroundStyle(.white)
        .elevated(.floating)
    }

    /// The in-app half of a "get ready" alert, for a rider with the screen up: the session times
    /// it and schedules the notification, which reaches a locked phone.
    private func raiseGetOffBanner(for step: Int?) {
        getOffBannerTask?.cancel()
        guard step != nil else {
            withAnimation { showGetOffBanner = false }
            return
        }
        Haptics.notify(.warning)
        withAnimation { showGetOffBanner = true }
        getOffBannerTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation { showGetOffBanner = false }
        }
    }

    /// The screen is held on only while the rider is following a map on foot. On a train they are
    /// not looking at it, and the alerts reach a locked phone.
    private func keepScreenOnWhileWalking() {
        let kind = session.currentStep?.kind
        UIApplication.shared.isIdleTimerDisabled = kind == .walkToStation || kind == .walkToDestination
    }
}

/// The app's single entry point for haptic feedback.
enum Haptics {
    @MainActor
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
