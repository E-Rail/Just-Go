import SwiftUI
import MapKit
import AVFoundation
import CoreLocation

@Observable
final class LiveGoViewModel {
    private(set) var route: Route
    private(set) var plan: LiveTripPlan
    var currentIndex = 0

    init(route: Route) {
        self.route = route
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

private struct LiveIndoorPathGuidance {
    let stationTitle: String
    let mapImageURL: URL?
    let indoorMap: StationIndoorMap
    let routeNodeIDs: [String]
    let routeEdgeIDs: [String]
    let destinationLineName: String?
    let transferContext: TransferContext?
}

private struct LiveTransferGuidance {
    let stepID: Int
    let stationTitle: String
    let indoorMap: StationIndoorMap?
    let transferContext: TransferContext?
    let indoorPath: LiveIndoorPathGuidance?
    let boardingZoneGuidance: IndoorBoardingZoneGuidance?
}

private struct LiveTransferGuidanceRequest: Hashable {
    let routeID: UUID
    let stepID: Int
}

/// Map-first, accessibility-first step-by-step trip companion: a full-screen interactive
/// map (pan/zoom, user-location puck, follow-me button) with the whole route drawn on it,
/// a compact instruction panel at the bottom, and off-route re-planning while walking.
struct LiveGoView: View {
    @State private var viewModel: LiveGoViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(DIContainer.self) private var container
    @AppStorage("arrivalAlertEnabled") private var arrivalAlertEnabled = true
    @AppStorage("arrivalAlertLeadMinutes") private var arrivalAlertLeadMinutes = 2
    // Read directly rather than via Color.accentColor: this view is presented in a
    // .fullScreenCover, whose first rendered frame doesn't yet have the root .tint(...)
    // environment value propagated and would otherwise flash system blue.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue
    @Environment(AppState.self) private var appState
    @State private var showGetOffBanner = false
    @State private var alertTask: Task<Void, Never>?
    // Accessibility step-change effects (无障碍 sheet): speech, haptics, visual banner.
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var announcedStep: TripStep?
    @State private var announcementTask: Task<Void, Never>?
    @State private var reminderRegistrationTask: Task<Void, Never>?
    @State private var scheduledStationKey: String?
    // Live-navigation map + off-route recovery.
    @State private var camera: MapCameraPosition = .automatic
    @State private var isRerouting = false
    @State private var offRouteStrikes = 0
    @State private var lastRerouteAt = Date.distantPast
    @State private var rerouteNotice: String?
    @State private var rerouteNoticeTask: Task<Void, Never>?
    // Transfer guidance is loaded lazily only while its transfer step is current.
    @State private var transferGuidance: LiveTransferGuidance?
    @State private var isLoadingTransferGuidance = false
    @State private var completedIndoorTransferStepIDs: Set<Int> = []

    private var themeColor: Color { Color.adaptive(hex: selectedThemeHex) }

    init(route: Route) {
        _viewModel = State(initialValue: LiveGoViewModel(route: route))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isActiveTransferStep,
                   let activeTransferGuidance,
                   let indoorPath = activeTransferGuidance.indoorPath {
                    embeddedIndoorGuidance(indoorPath, transferGuidance: activeTransferGuidance)
                } else if isActiveTransferStep {
                    transferStepSurface
                } else {
                    ZStack(alignment: .bottom) {
                        liveMap
                            .ignoresSafeArea(edges: .bottom)
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
            .navigationTitle(
                transferNavigationTitle
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Continuous fixes drive the puck and off-route detection; ended on disappear.
            container.locationService.beginContinuousUpdates()
            frameCurrentStep(animated: false)
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
        }
        .onChange(of: viewModel.currentIndex) { _, _ in
            frameCurrentStep(animated: true)
            refreshArrivalAlert()
            announceCurrentStep()
        }
        .onChange(of: arrivalAlertEnabled) { _, _ in refreshArrivalAlert() }
        .onChange(of: container.locationService.currentLocation) { _, location in
            handleLocationUpdate(location)
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

    // MARK: - Indoor transfer guidance

    private var transferGuidanceRequest: LiveTransferGuidanceRequest? {
        guard let step = viewModel.currentStep,
              step.kind == .transfer,
              !completedIndoorTransferStepIDs.contains(step.id) else { return nil }
        return LiveTransferGuidanceRequest(routeID: viewModel.route.id, stepID: step.id)
    }

    private var isActiveTransferStep: Bool {
        guard let step = viewModel.currentStep, step.kind == .transfer else { return false }
        return !completedIndoorTransferStepIDs.contains(step.id)
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
              !completedIndoorTransferStepIDs.contains(step.id),
              let transferGuidance,
              transferGuidance.stepID == step.id else { return nil }
        return transferGuidance
    }

    private func embeddedIndoorGuidance(
        _ guidance: LiveIndoorPathGuidance,
        transferGuidance: LiveTransferGuidance
    ) -> some View {
        IndoorStepGoView(
            stationTitle: guidance.stationTitle,
            mapImageURL: guidance.mapImageURL,
            indoorMap: guidance.indoorMap,
            routeNodeIDs: guidance.routeNodeIDs,
            routeEdgeIDs: guidance.routeEdgeIDs,
            destinationLineName: guidance.destinationLineName,
            transferContext: guidance.transferContext,
            boardingZoneGuidance: transferGuidance.boardingZoneGuidance,
            onComplete: {
                completeIndoorGuidance(for: transferGuidance.stepID)
            },
            onBack: viewModel.canGoBack ? {
                withAnimation { viewModel.goBack() }
            } : nil
        )
    }

    private var transferStepSurface: some View {
        VStack(spacing: 0) {
            transferStatusContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            instructionPanel
        }
        .background(Color.appBackground)
    }

    @ViewBuilder
    private var transferStatusContent: some View {
        if isLoadingTransferGuidance, activeTransferGuidance == nil {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(AppLocalization.text(
                    english: "Loading indoor transfer guidance…",
                    simplified: "正在加载站内换乘指引…",
                    traditional: "正在載入站內轉乘指引…"
                ))
                .font(.headline)
            }
            .padding(24)
            .accessibilityElement(children: .combine)
        } else if let guidance = activeTransferGuidance {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(guidance.stationTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text(AppLocalization.text(
                    english: "Indoor path not verified",
                    simplified: "暂无已核实的站内路径",
                    traditional: "暫無已核實的站內路徑"
                ))
                .font(.headline)
                Text(transferUnavailableDescription(for: guidance))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if let indoorMap = guidance.indoorMap {
                    DataConfidenceChip(confidence: indoorMap.confidence, compact: true)
                }
            }
            .padding(24)
            .accessibilityElement(children: .combine)
        } else {
            ContentUnavailableView {
                Label(
                    AppLocalization.text(
                        english: "Indoor guidance unavailable",
                        simplified: "站内指引不可用",
                        traditional: "站內指引不可用"
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
            .padding(24)
        }
    }

    private func transferUnavailableDescription(for guidance: LiveTransferGuidance) -> String {
        if let context = guidance.transferContext,
           let gap = guidance.indoorMap?.resolvedLineCoverageGaps.first(where: {
               $0.lineID == context.incoming.lineID || $0.lineID == context.outgoing.lineID
           }) {
            let lineName = gap.lineID == context.incoming.lineID
                ? context.incoming.lineName
                : context.outgoing.lineName
            return AppLocalization.text(
                english: "The source diagram does not show \(lineName), so no connecting path is claimed. Follow station signs.",
                simplified: "来源站内图未显示\(lineName)，因此不提供未经核实的连接路径，请以站内标识为准。",
                traditional: "來源站內圖未顯示\(lineName)，因此不提供未經核實的連接路徑，請以站內標識為準。"
            )
        }
        if guidance.indoorMap?.effectiveCoverageMode == .platformCheckpoints {
            return AppLocalization.text(
                english: "Platform checkpoints are mapped, but the connecting corridor is not verified. Follow station signs.",
                simplified: "已标注站台位置，但连接通道尚未核实，请以站内标识为准。",
                traditional: "已標註月台位置，但連接通道尚未核實，請以站內標識為準。"
            )
        }
        if guidance.indoorMap != nil {
            return AppLocalization.text(
                english: "No verified path matches this route and its accessibility settings. Follow station signs.",
                simplified: "暂无符合本次路线及无障碍设置的已核实路径，请以站内标识为准。",
                traditional: "暫無符合本次路線及無障礙設定的已核實路徑，請以站內標識為準。"
            )
        }
        return AppLocalization.text(
            english: "No verified indoor map is available for this transfer. Follow station signs.",
            simplified: "本次换乘暂无已核实的站内图，请以站内标识为准。",
            traditional: "本次轉乘暫無已核實的站內圖，請以站內標識為準。"
        )
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
        let precedingTransitSegment = viewModel.route.segments[..<segmentIndex].last(where: { $0.type.isTransit })
        let followingTransitSegment = viewModel.route.segments.index(after: segmentIndex) < viewModel.route.segments.endIndex
            ? viewModel.route.segments[viewModel.route.segments.index(after: segmentIndex)...]
                .first(where: { $0.type.isTransit })
            : nil
        let incomingLineName = context?.incoming.lineName
            ?? transferSegment.incomingLineName
            ?? precedingTransitSegment?.lineName
        let outgoingLineName = context?.outgoing.lineName
            ?? step.lineName
            ?? transferSegment.lineName
            ?? followingTransitSegment?.lineName
        let cityID = context?.cityID
            ?? viewModel.route.networkCityID
            ?? appState.selectedCity?.id
            ?? ""
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
        let preference = appState.accessibilityPreference
        let accessibilityFilter = AccessibilityFilter(
            requiresWheelchairAccess: preference.requiresWheelchairAccess,
            requiresElevator: preference.prefersElevator,
            avoidStairs: preference.avoidStairs
        )

        let indoorMap = await container.officialStationData.indoorMap(for: station)
        guard !Task.isCancelled, request == transferGuidanceRequest else { return }

        let boardingZoneGuidance: IndoorBoardingZoneGuidance?
        if let context {
            boardingZoneGuidance = await container.officialStationData.boardingZoneGuidance(
                for: station,
                context: context,
                accessibilityFilter: accessibilityFilter
            )
        } else {
            boardingZoneGuidance = nil
        }
        guard !Task.isCancelled, request == transferGuidanceRequest else { return }

        var transferPath: TransferPathHint?
        if let context {
            transferPath = await container.officialStationData.transferPath(
                for: station,
                context: context,
                accessibilityFilter: accessibilityFilter
            )
        }
        if transferPath == nil {
            transferPath = await container.officialStationData.transferPath(
                for: station,
                fromLineName: incomingLineName,
                toLineName: outgoingLineName,
                accessibilityFilter: accessibilityFilter
            )
        }
        guard !Task.isCancelled, request == transferGuidanceRequest else { return }

        var indoorPath: LiveIndoorPathGuidance?
        if let transferPath, transferPath.routeNodeIDs.count > 1, let indoorMap {
            indoorPath = LiveIndoorPathGuidance(
                stationTitle: stationName,
                mapImageURL: nil,
                indoorMap: indoorMap,
                routeNodeIDs: transferPath.routeNodeIDs,
                routeEdgeIDs: transferPath.routeEdgeIDs,
                destinationLineName: outgoingLineName,
                transferContext: context
            )
        }

        transferGuidance = LiveTransferGuidance(
            stepID: step.id,
            stationTitle: stationName,
            indoorMap: indoorMap,
            transferContext: context,
            indoorPath: indoorPath,
            boardingZoneGuidance: boardingZoneGuidance
        )
        isLoadingTransferGuidance = false

        // The graph is enough to start immediately. Resolve the much larger station diagram in
        // the background so a slow city-pack CDN cannot keep Live Go on the previous surface.
        guard let indoorPath else { return }
        let stationMap = await container.officialStationData.stationMap(for: station)
        guard !Task.isCancelled, request == transferGuidanceRequest,
              let stationMap, stationMap.isImage,
              let mapImageURL = stationMap.resolvedURL else { return }
        let pathWithImage = LiveIndoorPathGuidance(
            stationTitle: indoorPath.stationTitle,
            mapImageURL: mapImageURL,
            indoorMap: indoorPath.indoorMap,
            routeNodeIDs: indoorPath.routeNodeIDs,
            routeEdgeIDs: indoorPath.routeEdgeIDs,
            destinationLineName: indoorPath.destinationLineName,
            transferContext: indoorPath.transferContext
        )
        transferGuidance = LiveTransferGuidance(
            stepID: step.id,
            stationTitle: stationName,
            indoorMap: indoorMap,
            transferContext: context,
            indoorPath: pathWithImage,
            boardingZoneGuidance: boardingZoneGuidance
        )
    }

    private func completeIndoorGuidance(for stepID: Int) {
        guard viewModel.currentStep?.id == stepID,
              completedIndoorTransferStepIDs.insert(stepID).inserted,
              viewModel.canAdvance else { return }
        withAnimation { viewModel.advance() }
    }

    // MARK: - Map

    private struct RouteOverlay: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let isWalking: Bool
        let isCurrent: Bool
    }

    private struct StopMarker: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private var liveMap: some View {
        Map(position: $camera) {
            UserAnnotation()

            ForEach(routeOverlays) { overlay in
                MapPolyline(coordinates: overlay.coordinates)
                    .stroke(
                        overlay.color.opacity(overlay.isCurrent ? 1 : 0.55),
                        style: StrokeStyle(
                            lineWidth: overlay.isCurrent ? 7 : 4.5,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: overlay.isWalking ? [7, 7] : []
                        )
                    )
            }

            ForEach(stopMarkers) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    Circle()
                        .fill(.white)
                        .stroke(.black, lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                }
                .annotationTitles(.hidden)
            }

            if let destination = destinationCoordinate {
                Marker(
                    viewModel.plan.destination,
                    systemImage: "flag.checkered",
                    coordinate: destination
                )
                .tint(.green)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
    }

    /// One drawable per route segment, with the current step's segment emphasized.
    /// Transfers have no geometry and draw nothing; segments without a polyline fall back
    /// to their station-to-station straight line (same rule as TransitMapView).
    private var routeOverlays: [RouteOverlay] {
        let currentSegmentIndex = viewModel.currentStep?.segmentIndex
        return viewModel.route.segments.enumerated().compactMap { index, segment in
            var coordinates = segment.polylineCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            if coordinates.count < 2 {
                coordinates = segment.stationStops.compactMap(\.coordinate).map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
            }
            guard coordinates.count >= 2 else { return nil }
            let isWalking = segment.type == .walking
            return RouteOverlay(
                id: index,
                coordinates: coordinates,
                color: isWalking ? .gray : Color(hex: segment.lineColorHex ?? "#007AFF"),
                isWalking: isWalking,
                isCurrent: index == currentSegmentIndex
            )
        }
    }

    private var stopMarkers: [StopMarker] {
        var seen = Set<String>()
        var markers: [StopMarker] = []
        for segment in viewModel.route.segments where segment.type.isTransit {
            for stop in segment.stationStops {
                guard let coordinate = stop.coordinate,
                      seen.insert("\(stop.stationID)|\(coordinate.latitude)").inserted else { continue }
                markers.append(StopMarker(
                    id: "\(stop.stationID)|\(coordinate.latitude)|\(coordinate.longitude)",
                    name: stop.name,
                    coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                ))
            }
        }
        return markers
    }

    /// The trip's real end point: the last segment that carries geometry, walking back
    /// from the end of the route.
    private var destinationCoordinate: CLLocationCoordinate2D? {
        for segment in viewModel.route.segments.reversed() {
            if let last = segment.polylineCoordinates.last {
                return CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
            }
            if let stop = segment.stationStops.last?.coordinate {
                return CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
            }
        }
        return nil
    }

    /// Re-frame the camera on the current step's geometry. The rider stays free to pan and
    /// zoom afterwards (and can follow their own position via the map's location button) —
    /// only a step change or a reroute moves the camera.
    private func frameCurrentStep(animated: Bool) {
        guard let region = region(for: viewModel.currentStep) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }

    private func region(for step: TripStep?) -> MKCoordinateRegion? {
        guard let step else { return nil }
        var coordinates: [CLLocationCoordinate2D] = []
        switch step.kind {
        case .walkToStation, .walkToDestination:
            coordinates = step.walkingPathCLCoordinates
        case .transfer:
            if let coordinate = step.transferCLCoordinate { coordinates = [coordinate] }
        case .ride:
            if let index = step.segmentIndex, viewModel.route.segments.indices.contains(index) {
                let segment = viewModel.route.segments[index]
                coordinates = segment.polylineCoordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                if coordinates.count < 2 {
                    coordinates = segment.stationStops.compactMap(\.coordinate).map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                }
            }
        case .arrive:
            if let destination = destinationCoordinate { coordinates = [destination] }
        }
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1 else {
            return MKCoordinateRegion(
                center: first,
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            )
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (latitudes.min()! + latitudes.max()!) / 2,
            longitude: (longitudes.min()! + longitudes.max()!) / 2
        )
        // 1.45× padding so the step never touches the screen edges; floor keeps very short
        // steps from zooming in to building level.
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(0.006, (latitudes.max()! - latitudes.min()!) * 1.45),
                longitudeDelta: max(0.006, (longitudes.max()! - longitudes.min()!) * 1.45)
            )
        )
    }

    // MARK: - Off-route recovery

    /// Off-route detection runs ONLY on walking steps with a decent fix: underground (rides,
    /// transfers) GPS drifts or vanishes entirely, and auto-rerouting on tunnel noise would
    /// constantly replan a trip the rider is following correctly.
    private func handleLocationUpdate(_ location: CLLocation?) {
        guard let location,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 65,
              let step = viewModel.currentStep,
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
        // Two consecutive off-corridor fixes (distanceFilter is 10 m, so this is real
        // movement, not jitter) + a cooldown so a failed or just-finished replan doesn't
        // immediately fire again.
        guard offRouteStrikes >= 2, !isRerouting,
              Date().timeIntervalSince(lastRerouteAt) > 45 else { return }
        offRouteStrikes = 0
        Task { await reroute(from: location.coordinate) }
    }

    @MainActor
    private func reroute(from coordinate: CLLocationCoordinate2D) async {
        guard let destination = destinationCoordinate else { return }
        isRerouting = true
        lastRerouteAt = Date()
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
                city: viewModel.route.networkCityID ?? appState.selectedCity?.id ?? "",
                accessibilityFilter: AccessibilityFilter(
                    requiresWheelchairAccess: preference.requiresWheelchairAccess,
                    requiresElevator: preference.prefersElevator,
                    avoidStairs: preference.avoidStairs
                )
            )
            guard let newRoute = routes.first else { throw RoutePlanningError.noRouteFound }
            viewModel.reroute(with: newRoute)
            transferGuidance = nil
            completedIndoorTransferStepIDs.removeAll()
            // Keep the resume banner's stored trip in step with what's actually guiding.
            ActiveTripStore.save(newRoute)
            frameCurrentStep(animated: true)
            refreshArrivalAlert()
            announceCurrentStep()
            showRerouteNotice(AppLocalization.text(
                english: "Route updated from your location",
                simplified: "已根据您的位置更新路线",
                traditional: "已根據您的位置更新路線"
            ))
        } catch {
            showRerouteNotice(AppLocalization.text(
                english: "Couldn't reroute — following the original route",
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
    /// small local planar frame — exact enough at street scale).
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
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .bottom], 10)
    }

    private func stepSummary(_ step: TripStep) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(for: step.kind))
                    .font(.title)
                    .foregroundStyle(color(for: step))
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            if step.kind == .transfer,
               activeTransferGuidance?.indoorPath == nil,
               let boardingZoneGuidance = activeTransferGuidance?.boardingZoneGuidance {
                boardingZoneSummary(boardingZoneGuidance)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stepAccessibilityLabel(step))
    }

    private func stepAccessibilityLabel(_ step: TripStep) -> String {
        var parts = [step.accessibilityLabel]
        if step.kind == .transfer,
           let guidance = activeTransferGuidance?.boardingZoneGuidance {
            parts.append(AppLocalization.text(
                english: "Boarding zone: \(guidance.zone.localizedLabel)",
                simplified: "建议候车位置：\(guidance.zone.localizedLabel)",
                traditional: "建議候車位置：\(guidance.zone.localizedLabel)"
            ))
        }
        return parts.joined(separator: ", ")
    }

    private func boardingZoneSummary(_ guidance: IndoorBoardingZoneGuidance) -> some View {
        let title = AppLocalization.text(
            english: "Boarding zone: \(guidance.zone.localizedLabel)",
            simplified: "建议候车位置：\(guidance.zone.localizedLabel)",
            traditional: "建議候車位置：\(guidance.zone.localizedLabel)"
        )
        return VStack(spacing: 8) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Label(title, systemImage: "train.side.front.car")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(themeColor)
                    Spacer(minLength: 8)
                    DataConfidenceChip(confidence: guidance.confidence, compact: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(title, systemImage: "train.side.front.car")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(themeColor)
                    DataConfidenceChip(confidence: guidance.confidence, compact: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                nextButton
                backButton
            }
        } else {
            HStack(spacing: 14) {
                backButton
                nextButton
            }
        }
    }

    private var backButton: some View {
        Button {
            withAnimation { viewModel.goBack() }
        } label: {
            Label(
                AppLocalization.text(english: "Back", simplified: "上一步", traditional: "上一步"),
                systemImage: "chevron.left"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canGoBack)
        .opacity(viewModel.canGoBack ? 1 : 0.4)
    }

    private var nextButton: some View {
        Button {
            if viewModel.canAdvance {
                withAnimation { viewModel.advance() }
            } else {
                dismiss()
            }
        } label: {
            Label(
                viewModel.canAdvance
                    ? AppLocalization.text(english: "Next", simplified: "下一步", traditional: "下一步")
                    : AppLocalization.localized("Done"),
                systemImage: viewModel.canAdvance ? "chevron.right" : "checkmark"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(themeColor, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
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
        if preference.audioNavigation {
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
            Image(systemName: icon(for: step.kind))
            Text(step.title)
                .fontWeight(.semibold)
                .lineLimit(2)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity)
        .background(themeColor, in: RoundedRectangle(cornerRadius: 14))
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
        .background(themeColor, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func icon(for kind: LiveStepKind) -> String {
        switch kind {
        case .walkToStation, .walkToDestination: return "figure.walk"
        case .ride: return "tram.fill"
        case .transfer: return "arrow.triangle.2.circlepath"
        case .arrive: return "flag.checkered"
        }
    }

    private func color(for step: TripStep) -> Color {
        switch step.kind {
        case .walkToStation, .walkToDestination: return .gray
        case .ride: return Color(hex: step.lineColorHex ?? "#007AFF")
        case .transfer: return .orange
        case .arrive: return .green
        }
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
        .background(themeColor, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    /// (Re)arms the estimated "get off" alert for the current step. Cancels any prior alert first,
    /// then — only for a ride step with the toggle on — schedules a hands-free local notification
    /// and an in-app timer that buzzes + shows a banner if the app is still foreground at fire time.
    @MainActor
    private func refreshArrivalAlert() {
        cancelArrivalAlert()
        guard arrivalAlertEnabled,
              let step = viewModel.currentStep,
              step.kind == .ride else { return }

        let key = "\(step.id)"
        let leadSeconds = TimeInterval(arrivalAlertLeadMinutes * 60)
        let fireInterval = max(0, step.duration - leadSeconds)
        let fireDate = Date().addingTimeInterval(fireInterval)
        scheduledStationKey = key

        let stationName = step.toStationName ?? ""
        let exitHint = step.exitHint
        reminderRegistrationTask = Task { @MainActor in
            guard await container.tripReminderService.requestAuthorization() else { return }
            // requestAuthorization can take a while (first-run system prompt). If the rider
            // advanced past this step while it was pending, cancelArrivalAlert() already ran
            // with the OLD scheduledStationKey and found nothing registered yet to cancel —
            // registering now would leave a stale "get off" alert for an already-passed stop.
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

/// Thin haptic-feedback helper. The app had no haptics before; this is the single entry point.
enum Haptics {
    @MainActor
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
