import SwiftUI
import MapKit
import AVFoundation
import CoreLocation

@Observable
final class LiveGoViewModel {
    private(set) var route: Route
    /// The route as it was when guidance began. A reroute replaces `route` from "Current
    /// Location", and the trip history finds its planned row by the original two ends.
    let plannedRoute: Route
    private(set) var plan: LiveTripPlan
    var currentIndex = 0

    init(route: Route) {
        self.route = route
        self.plannedRoute = route
        self.plan = LiveGoTripBuilder().plan(for: route)
    }

    /// Swap in a freshly planned route (off-route recovery) and restart the steps.
    func reroute(with newRoute: Route) {
        route = newRoute
        plan = LiveGoTripBuilder().plan(for: newRoute)
        currentIndex = 0
    }

    var currentStep: TripStep? {
        plan.steps.indices.contains(currentIndex) ? plan.steps[currentIndex] : nil
    }

    var canAdvance: Bool { currentIndex < plan.steps.count - 1 }
    var canGoBack: Bool { currentIndex > 0 }

    func advance() { if canAdvance { currentIndex += 1 } }
    func goBack() { if canGoBack { currentIndex -= 1 } }

    var progressText: String {
        AppLocalization.stepProgress(current: currentIndex + 1, total: plan.steps.count)
    }

    var progressFraction: Double {
        guard plan.steps.count > 1 else { return 1 }
        return Double(currentIndex) / Double(plan.steps.count - 1)
    }
}

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
struct LiveGoView: View {
    /// Rendered inside the route detail rather than over it: this drops the navigation chrome only
    /// a presented copy needs and hands the exit to its host. One navigator, two containers.
    var embedded = false
    let onExit: () -> Void

    @State private var viewModel: LiveGoViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(DIContainer.self) private var container
    @AppStorage("arrivalAlertEnabled") private var arrivalAlertEnabled = true
    @AppStorage("arrivalAlertLeadMinutes") private var arrivalAlertLeadMinutes = 2
    // Read directly rather than via `Color.accentColor`: in a full-screen cover the first frame
    // does not yet have the root `.tint` and would flash system blue.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var showGetOffBanner = false
    /// When the rider reached the ride step being alerted for. Back, Next and the toggle all re-run
    /// the scheduling, which must count from this moment, not from the re-run, or the alert fires
    /// past the stop.
    @State private var alertRideStart: (stepID: TripStep.ID, at: Date)?
    @State private var alertTask: Task<Void, Never>?
    // Accessibility step-change effects (无障碍 sheet): speech, haptics, visual banner.
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var announcedStep: TripStep?
    @State private var announcementTask: Task<Void, Never>?
    @State private var reminderRegistrationTask: Task<Void, Never>?
    @State private var scheduledStationKey: String?
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

    init(route: Route, embedded: Bool = false, onExit: @escaping () -> Void) {
        self.embedded = embedded
        self.onExit = onExit
        _viewModel = State(initialValue: LiveGoViewModel(route: route))
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
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(AppLocalization.localized("Done")) { exit() }
                    }
                }
            }
    }

    /// Ending a trip completes it in the rider's history, whichever way guidance was entered. It
    /// asks nothing on the way out: the packs and the route provider carry what riders used to be
    /// asked.
    private func exit() {
        let planned = viewModel.plannedRoute
        tripMemoryService.markTripComplete(route: planned, cityID: planned.networkCityID ?? "")
        onExit()
    }

    var body: some View {
        navigatorSurface
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Continuous fixes drive the puck and off-route detection; ended on disappear.
            container.locationService.beginContinuousUpdates()
            // The Accessibility toggle is a promise, not a preference: a rider who turned on
            // Audio Navigation gets it, whatever the mute button was last left at.
            if appState.accessibilityPreference.audioNavigation { voiceEnabled = true }
            followsRider = true
            frameCurrentStep()
            refreshArrivalAlert()
            announceCurrentStep()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            container.locationService.endContinuousUpdates()
            cancelArrivalAlert()
            speechSynthesizer.stopSpeaking(at: .immediate)
            announcementTask?.cancel()
            rerouteNoticeTask?.cancel()
            rerouteTask?.cancel()
        }
        .onChange(of: viewModel.currentIndex) { _, _ in
            // Follow-me is turned off by the Back and Next buttons themselves, not here: a reroute
            // also resets the index, and the rider did not ask to stop being followed.
            frameCurrentStep()
            refreshArrivalAlert()
            announceCurrentStep()
        }
        .onChange(of: arrivalAlertEnabled) { _, _ in refreshArrivalAlert() }
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
        .task(id: viewModel.route.id) {
            await container.officialStationData.prefetchTransferAssets(for: viewModel.route)
        }
    }

    // MARK: - Transfer step

    private var transferGuidanceRequest: LiveTransferGuidanceRequest? {
        guard let step = viewModel.currentStep, step.kind == .transfer else { return nil }
        return LiveTransferGuidanceRequest(routeID: viewModel.route.id, stepID: step.id)
    }

    private var isActiveTransferStep: Bool {
        viewModel.currentStep?.kind == .transfer
    }

    private var transferNavigationTitle: String {
        guard isActiveTransferStep else {
            return AppLocalization.text(english: "Go", simplified: "出发", traditional: "出發")
        }
        return activeTransferGuidance?.stationTitle
            ?? viewModel.currentStep?.fromStationName
            ?? AppLocalization.localized("Transfer station")
    }

    private var activeTransferGuidance: LiveTransferGuidance? {
        guard let step = viewModel.currentStep,
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
        if let metres = viewModel.currentStep.flatMap(measuredCorridorMetres(for:)) {
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
        return viewModel.route.segments.first {
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
        let notes = viewModel.currentStep?.kind == .transfer ? (viewModel.currentStep?.notes ?? []) : []
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
              let step = viewModel.currentStep,
              step.id == request.stepID,
              let segmentIndex = step.segmentIndex,
              viewModel.route.segments.indices.contains(segmentIndex) else { return }

        let transferSegment = viewModel.route.segments[segmentIndex]
        let context = step.transferContext ?? transferSegment.transferContext
        let cityID = context?.cityID ?? viewModel.route.networkCityID ?? ""
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
            stations: viewModel.route.mapStations,
            alwaysShowsStations: true,
            metroNetworks: [],
            route: viewModel.route,
            showsUserLocation: true,
            onUserLocationChanged: { container.locationService.observeMapSpaceUserLocation($0) },
            onRegionChanged: { mapRegion = $0 },
            onStationSelected: { _ in }
        )
    }

    /// Frames the current step's geometry. The rider stays free to pan and zoom afterwards; only a
    /// step change, a reroute or turning follow-me off moves the camera.
    private func frameCurrentStep() {
        guard let step = viewModel.currentStep else { return }
        let segment = step.segmentIndex.flatMap { viewModel.route.segments.indices.contains($0) ? viewModel.route.segments[$0] : nil }
        var coordinates: [CodableCoordinate]
        switch step.kind {
        case .walkToStation, .walkToDestination: coordinates = step.walkingPathCoordinates
        case .transfer: coordinates = step.transferCoordinate.map { [$0] } ?? []
        case .ride: coordinates = segment?.drawableCoordinates ?? []
        case .arrive: coordinates = viewModel.route.groundDestination.map { [$0] } ?? []
        }
        let points = coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        if let region = MapVisibleRegion(fitting: points, minimumSpan: 0.006) {
            mapRegion = region
        }
    }

    // MARK: - Off-route recovery

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
              let step = viewModel.currentStep,
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
        guard let ground = viewModel.route.groundDestination else { return }
        let destination = CLLocationCoordinate2D(latitude: ground.latitude, longitude: ground.longitude)
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
                to: TransitPlace(name: viewModel.plan.destination, coordinate: destination, source: .mapKit),
                accessibilityFilter: AccessibilityFilter(
                    requiresWheelchairAccess: preference.requiresWheelchairAccess,
                    requiresElevator: preference.prefersElevator,
                    avoidStairs: preference.avoidStairs,
                    maxWalkingDistance: preference.maxWalkingDistance
                )
            )
            // Ranked the way the results list ranks them, boardable first; the planner's own order
            // can put a drive or a shut line first.
            let ranked = container.routePlanningService.sortRoutes(routes, by: .fastest, preferences: preference)
            guard let newRoute = ranked.first else { throw RoutePlanningError.noRouteFound }
            // The plan can outlive the screen (`MKLocalSearch` ignores cancellation), and nothing
            // below should happen to a trip the rider has left.
            guard !Task.isCancelled else { return }
            // From any step but the first, the index change runs framing, the alert and the
            // announcement through `onChange`; doing it here too would speak the step twice.
            let indexChanges = viewModel.currentIndex != 0
            // A fresh plan from where the rider actually is: the next divergence is new information.
            rerouteInterval = 45
            viewModel.reroute(with: newRoute)
            // Step IDs restart with the new plan, so the old ride's start would pass for the new one.
            alertRideStart = nil
            transferGuidance = nil
            // Keep the resume banner's stored trip in step with what's actually guiding.
            ActiveTripStore.save(newRoute)
            if !indexChanges {
                frameCurrentStep()
                refreshArrivalAlert()
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
            ProgressView(value: viewModel.progressFraction)
                .tint(themeColor)

            if let step = viewModel.currentStep {
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
                Text(viewModel.progressText)
                    .rowMeta()
            }

            roadHandoff(for: step)

            if step.rideStopsRemainingText != nil || (step.kind == .ride && step.exitHint?.isEmpty == false) {
                HStack(spacing: 12) {
                    if let stopsLeft = step.rideStopsRemainingText {
                        Text(stopsLeft)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(themeColor)
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
                originName: step.fromStationName ?? viewModel.route.origin,
                target: end,
                destinationName: step.toStationName ?? viewModel.route.destination
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
            withAnimation { viewModel.goBack() }
        } label: {
            StepSecondaryButtonLabel(
                title: AppLocalization.text(english: "Back", simplified: "上一步", traditional: "上一步"),
                systemImage: "chevron.left"
            )
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canGoBack)
        .opacity(viewModel.canGoBack ? 1 : 0.4)
    }

    private var nextButton: some View {
        Button {
            if viewModel.canAdvance {
                followsRider = false
                withAnimation { viewModel.advance() }
            } else {
                exit()
            }
        } label: {
            StepPrimaryButtonLabel(
                title: viewModel.canAdvance
                    ? AppLocalization.text(english: "Next", simplified: "下一步", traditional: "下一步")
                    : AppLocalization.localized("Done"),
                systemImage: viewModel.canAdvance ? "chevron.right" : "checkmark",
                fillHex: selectedThemeHex
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Announcements & alerts

    /// Applies the enabled accessibility effects for the step now showing: spoken
    /// instruction (语音导航), haptic (振动提醒), and a transient banner (视觉播报).
    private func announceCurrentStep() {
        guard let step = viewModel.currentStep else { return }
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
                if let to = viewModel.currentStep?.toStationName {
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

    /// Re-arms the estimated "get off" alert for the current step: cancels any prior alert, then,
    /// for a ride step with the toggle on, schedules a local notification and an in-app timer that
    /// buzzes and shows a banner if the app is still foreground.
    @MainActor
    private func refreshArrivalAlert() {
        cancelArrivalAlert()
        guard arrivalAlertEnabled,
              let step = viewModel.currentStep,
              step.kind == .ride else { return }

        let key = "\(step.id)"
        if alertRideStart?.stepID != step.id { alertRideStart = (step.id, Date()) }
        let rideStart = alertRideStart?.at ?? Date()
        let leadSeconds = TimeInterval(arrivalAlertLeadMinutes * 60)
        let fireDate = rideStart.addingTimeInterval(step.duration - leadSeconds)
        let fireInterval = max(0, fireDate.timeIntervalSinceNow)
        scheduledStationKey = key

        let stationName = step.toStationName ?? ""
        let exitHint = step.exitHint
        reminderRegistrationTask = Task { @MainActor in
            guard await container.tripReminderService.requestAuthorization() else { return }
            // Authorization can wait on a first-run prompt. If the rider advanced meanwhile, the
            // cancel already ran with nothing registered, and registering now would leave an alert
            // for a stop already passed.
            guard !Task.isCancelled, scheduledStationKey == key else { return }
            await container.tripReminderService.scheduleArrivalReminder(
                stationID: key,
                stationName: stationName,
                exitHint: exitHint,
                fireDate: fireDate
            )
        }

        alertTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(fireInterval))
            guard !Task.isCancelled, viewModel.currentStep?.kind == .ride else { return }
            Haptics.notify(.warning)
            withAnimation { showGetOffBanner = true }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled {
                withAnimation { showGetOffBanner = false }
            }
        }
    }

    @MainActor
    private func cancelArrivalAlert() {
        alertTask?.cancel()
        alertTask = nil
        reminderRegistrationTask?.cancel()
        reminderRegistrationTask = nil
        showGetOffBanner = false
        if let key = scheduledStationKey {
            container.tripReminderService.cancelArrivalReminder(stationID: key)
            scheduledStationKey = nil
        }
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
