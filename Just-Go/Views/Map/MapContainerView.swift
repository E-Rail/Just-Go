import SwiftUI
import MapKit
import CoreLocation

/// A place whose card is open: a tapped Apple POI, a search result or a dropped pin. Held beside
/// the path by `id`, which stays fixed while the card fills in (loading shell → Apple's card, or a
/// pin's coordinate → its street name), so the page updates in place rather than being replaced.
private struct TappedPlace {
    let id = UUID()
    var name: String
    let coordinate: CLLocationCoordinate2D
    var address: String?
    var resolvedItem: MKMapItem?
    /// A tapped POI, whose `MKMapItem` is on its way. Nothing is coming for a search result or a
    /// dropped pin, so they show what they have rather than a spinner that cannot finish.
    var awaitsAppleCard = false
    /// A pin the rider dropped on bare ground rather than an Apple POI they tapped.
    var isDroppedPin = false
    /// Where a phone's panel opens for it. A dropped pin opens low: a name and a coordinate need
    /// little room, and the rider is pointing at the map. A tapped POI opens full, because the drag
    /// to expand can be eaten by Apple's embedded card's scroll view.
    var opening: PanelStop = .medium
}

/// Everything the map's panel can show, as one path enum rather than a `navigationDestination` per
/// screen: several `isPresented` registrations on one node shadow each other, a path is what a
/// headless launch can seed, and the page on top of it is what the map beside the panel shows
/// (`MapFocus`).
enum MapRoute: Hashable {
    case search
    /// The search page again, opened from the results header to refill one end of the trip.
    /// Picking a result fills that field and returns; it does not open a place card.
    case editEndpoint(RouteInputField)
    /// The destination, when the rider came from a place card, travels in
    /// `AppState.pendingRouteInput`: `TransitPlace` is not `Hashable`.
    case results
    case detail(UUID)
    /// A change between two lines of one route, a stop it calls at, and how sure the app is of it:
    /// pages a route's detail opens, carried as ids and resolved against the planner's routes.
    case transfer(routeID: UUID, segmentID: UUID)
    case routeStop(routeID: UUID, stopID: String)
    case confidence(UUID)
    /// The station's **id**, not the object: a reference type in a navigation path can fail to
    /// resolve, and an unresolved value renders as a blank pushed screen. The object is held beside
    /// the path in `openedStations`.
    case station(id: String)
    /// A place card, by its `TappedPlace` id: `MKMapItem` is not `Hashable`.
    case place(UUID)
    /// A line, keyed the same way: `MetroLine` is not `Hashable`, and the ids fetch it from the
    /// cached network.
    case line(cityID: String, lineID: String)
    /// The trip under way. Its route is held beside the path in `guidanceRoute` until the session
    /// has one of its own.
    case guidance

    /// Something chosen on the map, which the next thing chosen there replaces rather than stacks
    /// on.
    var isMapSelection: Bool {
        switch self {
        case .station, .place: return true
        default: return false
        }
    }
}

/// Which container holds the panel's pages. A reference, because a container being torn down by a
/// fold still holds the bindings it was built with, and they must read who owns the path *now*.
private final class PanelOwner {
    var usesSidePanel = false
}

/// The map tab: one map, always behind, and one panel of pages beside it. On regular width the
/// panel is a card at the leading edge that grows from the search field; on compact width it is a
/// sheet over the map. The same pages, the same path and the same map either way, so a folding
/// phone moving between its displays keeps where the rider was.
struct MapContainerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: MapViewModel?
    @State private var path: [MapRoute] = []
    @State private var owner = PanelOwner()
    /// The path while the phone's panel slides away, which it keeps drawing until it has gone.
    @State private var lastPanelPath: [MapRoute] = []
    @State private var showPlaceTagDialog = false
    @State private var isLoadingStationDetail = false
    @State private var cameraSaveTask: Task<Void, Never>?
    @State private var placeMatchTask: Task<Void, Never>?
    @State private var stationOpenTask: Task<Void, Never>?
    @State private var centerOnUserTask: Task<Void, Never>?
    /// How tall the floating chrome over the map's top edge is, so the map centres the rider in the
    /// part they can see.
    @State private var topChromeHeight: CGFloat = 0
    /// The same for the rider's panel at the bottom, which changes height when it is minimized.
    @State private var bottomChromeHeight: CGFloat = 0
    /// A folding phone's crease across the map, which the panel keeps to one side of.
    @State private var mapFold = FoldedSurface()
    /// The shell's own size, in the frame the fold is measured in.
    @State private var shellSize: CGSize = .zero
    /// How tall the card's home (the search field and the rider's rows) is, which the card fits.
    @State private var homeHeight: CGFloat = 120
    @State private var planTask: Task<Void, Never>?
    @State private var didCenterOnUser = false
    #if DEBUG
    /// The map tab's return runs its task again, and a seed run there would reopen its page over
    /// whatever the rider has done since.
    @State private var didSeedDebugScreen = false
    #endif
    /// Non-nil for a few seconds after a locate attempt that could not produce a fix.
    @State private var locateFailure: String?
    @State private var stationOpenGeneration = 0
    // Holds an MKMapItem that resolved while station matching was still deciding whether to
    // open a place card: consumed (or discarded) when that decision lands.
    @State private var pendingResolvedItem: MKMapItem?
    /// The place card that a POI resolve in flight belongs to. Nil while a tap is still being
    /// matched, so a resolve never fills the card of an earlier tap.
    @State private var activePlaceTap: UUID?
    /// Stations that have been pushed, keyed by the id carried in the path.
    @State private var openedStations: [String: Station] = [:]
    @State private var openedPlaces: [UUID: TappedPlace] = [:]
    /// The alternative each route page shows, keyed by the route it opened with, so the map draws
    /// the one on screen and a page rebuilt by a fold keeps it.
    @State private var detailSelections: [UUID: UUID] = [:]
    /// The route the results page marks as last opened, which the map shows there.
    @State private var lastOpenedRouteID: UUID?
    /// Line pages' map content, handed up as each loads.
    @State private var lineMaps: [String: LineMap] = [:]
    /// Each focus's camera, once the rider or a page has moved it. See `MapFocus.cameraKey`.
    @State private var focusCameras: [String: MapVisibleRegion] = [:]
    /// Where the phone's panel was resting on each page, restored when the rider comes back to it.
    @State private var panelStops: [MapRoute: PanelStop] = [:]
    /// The trip `.guidance` opens with, until the session's own route replaces it.
    @State private var guidanceRoute: Route?
    /// How tall the guidance page measured itself, which the panel fits.
    @State private var guidanceHeight: CGFloat?
    /// A trip still running when the app was last killed, being asked about. See
    /// `offerToResumeTrip`.
    @State private var pendingResumableTrip: Route?
    @State private var isResumingTrip = false
    /// Where MapKit last put the rider, in the map's own frame, which is the stations' frame too.
    /// Moved only by a real change of place: every frame of the dot's drift would otherwise redraw
    /// the panel.
    @State private var riderCoordinate: CLLocationCoordinate2D?
    /// On a phone, the search pill and the panel it opens, which zooms out of it and back into it.
    @Namespace private var searchTransition
    private static let searchTransitionID = "search"

    /// From the size class, so a narrow split-screen window keeps the phone's sheet, and an iPhone
    /// Duo moves between the two as it opens and closes.
    private var usesSidePanel: Bool { horizontalSizeClass == .regular }

    var body: some View {
        // Before anything is built: a binding from the container this replaces reads it when it
        // writes, which can be after this pass.
        owner.usesSidePanel = usesSidePanel
        return shell
            // The map tab lives as long as the app: whatever a page left beside the path is
            // released when the page leaves it.
            .onChange(of: path) { _, newPath in
                pathChanged(to: newPath)
            }
            .task {
                if viewModel == nil {
                    viewModel = container.makeMapViewModel()
                }
                restoreCamera()
                #if DEBUG
                // Before the centring guard below, which returns once a fix has landed and would
                // skip the seed on a second run of this task. Once per map, not per appearance.
                if !didSeedDebugScreen {
                    didSeedDebugScreen = true
                    seedDebugScreen()
                }
                #endif
                // Open on the rider, retried until it lands. With location unavailable (denied,
                // restricted, or timed out) this does nothing and the restored camera stays.
                guard !didCenterOnUser else { return }
                centerOnUser()
            }
            .task { offerToResumeTrip() }
            .alert(
                AppLocalization.text(
                    english: "Resume your trip?",
                    simplified: "继续之前的行程？",
                    traditional: "繼續之前的行程？"
                ),
                isPresented: $isResumingTrip,
                presenting: pendingResumableTrip
            ) { trip in
                Button(AppLocalization.text(english: "Resume", simplified: "继续", traditional: "繼續")) {
                    pendingResumableTrip = nil
                    openGuidance(for: trip)
                }
                Button(
                    AppLocalization.text(english: "Discard", simplified: "放弃", traditional: "放棄"),
                    role: .destructive
                ) {
                    pendingResumableTrip = nil
                    container.tripSession.discardSavedTrip()
                }
            } message: { trip in
                Text(verbatim: "\(trip.origin) → \(trip.destination)")
            }
            // A place card's "Route here" only records the place and the plan starts here, so every
            // sender (map POI, search result, station page) starts a plan the same way without
            // knowing the panel's pages.
            .onChange(of: appState.pendingRouteInput) { _, pending in
                guard let pending else { return }
                beginPlan(to: pending)
            }
            .onChange(of: appState.pendingTripReplay, initial: true) { _, record in
                guard let record else { return }
                appState.pendingTripReplay = nil
                replay(record)
            }
            .onChange(of: appState.pendingTripOpen, initial: true) { _, pending in
                guard pending else { return }
                appState.pendingTripOpen = false
                openTrip()
            }
            // Accessibility Settings reach the planner here: seeded on appear and re-seeded on
            // change, so results planned under an old preference are dropped.
            .task(id: appState.accessibilityPreference) {
                if planner.syncAccessibilityPreference(appState.accessibilityPreference) {
                    path.removeAll()
                }
            }
    }

    private func pathChanged(to newPath: [MapRoute]) {
        if !newPath.isEmpty { lastPanelPath = newPath }
        var stations = Set<String>()
        var places = Set<UUID>()
        var lines = Set<String>()
        var details = Set<UUID>()
        for page in newPath {
            switch page {
            case .station(let id): stations.insert(id)
            case .place(let id): places.insert(id)
            case .line(let cityID, let lineID): lines.insert(LineMap.key(cityID: cityID, lineID: lineID))
            case .detail(let id): details.insert(id)
            default: break
            }
        }
        openedStations = openedStations.filter { stations.contains($0.key) }
        openedPlaces = openedPlaces.filter { places.contains($0.key) }
        lineMaps = lineMaps.filter { lines.contains($0.key) }
        detailSelections = detailSelections.filter { details.contains($0.key) }
        let pages = Set(newPath)
        panelStops = panelStops.filter { pages.contains($0.key) }
        if !pages.contains(.guidance) { guidanceHeight = nil }
        // Back to browsing: the next plan starts from its own fitted cameras.
        if newPath.isEmpty { focusCameras = [:] }
    }

    // MARK: - The shell

    private var shell: some View {
        ZStack {
            mapView
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topChrome
                .zIndex(2)
                // Measured, not constant: the pill and attribution row grow with Dynamic Type, and
                // a failed locate adds a third row.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    topChromeHeight = height
                }
        }
        // An inset, not an overlay, so MapKit keeps its attribution and controls clear of the panel.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !usesSidePanel, path.isEmpty {
                riderPanel(standsAlone: true)
                    .transition(.opacity)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        bottomChromeHeight = height
                    }
            }
        }
        // Measured on the whole map, outside both insets: a panel that grew or shrank would
        // otherwise move the frame the crease is measured in, or push the crease out of it.
        .onGeometryChange(for: FoldedSurface.self) { proxy in
            FoldedSurface(proxy)
        } action: { surface in
            mapFold = surface
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            shellSize = size
        }
        // The map and its chrome stay put under a keyboard; the card, outside this, makes room.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .topLeading) {
            if usesSidePanel {
                sidePanel
            }
        }
        .animation(.easeInOut(duration: 0.2), value: path.isEmpty)
        .toolbarBackground(.visible, for: .tabBar)
        // Put away while a page is open, as the phone's panel covers it. On a wide screen the tab
        // bar otherwise moves into the card's navigation bar, beside its back button, and takes the
        // map's top inset with it.
        .toolbar(usesSidePanel && !path.isEmpty ? .hidden : .automatic, for: .tabBar)
        .sheet(isPresented: compactPanelPresented) {
            compactPanel
        }
        .onDisappear {
            placeMatchTask?.cancel()
            stationOpenTask?.cancel()
            centerOnUserTask?.cancel()
            cameraSaveTask?.cancel()
            isLoadingStationDetail = false
            pendingResolvedItem = nil
        }
    }

    /// Over the map's top edge: on a phone at home the search field, then the map's own buttons. On
    /// a wide screen the search field is in the card, and the buttons sit beyond it.
    private var topChrome: some View {
        VStack(spacing: 10) {
            if !usesSidePanel, path.isEmpty {
                HStack(spacing: 10) {
                    searchPill
                        .floatingChrome(in: Capsule(), isInteractive: true)
                        .matchedTransitionSource(id: Self.searchTransitionID, in: searchTransition)
                    stationLoadingSpinner
                }
                .transition(.opacity)
            }
            mapControls
                .padding(.leading, usesSidePanel ? panelLayout.controlsLeading : 0)
            if let locateFailure {
                Text(locateFailure)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .floatingChrome(in: Capsule(), isInteractive: false)
                    // Centred in the map's part of the screen, under the button that asked.
                    .frame(maxWidth: .infinity)
                    .padding(.leading, usesSidePanel ? panelLayout.controlsLeading : 0)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: locateFailure)
        .padding(.horizontal, Metrics.l)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// The attribution for what the map draws and the locate button, at the map's trailing edge.
    private var mapControls: some View {
        HStack(spacing: 8) {
            Spacer()
            if viewModel?.metroNetworks.isEmpty == false || mapFocus.drawsMetroGeometry {
                MetroGeometryAttributionView()
                    .lineLimit(1)
                    .layoutPriority(0)
            }
            mapLocateButton
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var stationLoadingSpinner: some View {
        if isLoadingStationDetail {
            ProgressView()
                .controlSize(.small)
                .frame(width: 34, height: 34)
                .floatingChrome(in: Circle(), isInteractive: false)
        }
    }

    private var panelLayout: MapPanelLayout {
        MapPanelLayout(size: shellSize, surface: mapFold)
    }

    // MARK: - Wide: the card

    /// The card at the leading edge. Its home is the search field and the rider's rows, as tall as
    /// they are; anything opened grows it to its full height, and a trip under way fits its step.
    private var sidePanel: some View {
        let layout = panelLayout
        return NavigationStack(path: sidePath) {
            panelHome
                .toolbar(.hidden, for: .navigationBar)
                .containerBackground(.clear, for: .navigation)
                .navigationDestination(for: MapRoute.self) { panelPage($0, isFirst: false) }
        }
        // A phone's width, so its pages lay out as they do on one.
        .environment(\.horizontalSizeClass, .compact)
        .frame(width: layout.cardWidth, height: cardHeight(layout))
        .floatingChrome(clipsContent: true)
        .animation(.smooth(duration: 0.35), value: cardHeight(layout))
        .padding(.leading, layout.cardLeading)
        .padding(.top, layout.cardTop)
    }

    private func cardHeight(_ layout: MapPanelLayout) -> CGFloat {
        let tallest = layout.maxCardHeight
        switch path.last {
        case nil:
            return min(homeHeight, tallest)
        case .guidance? where !isAtTransferStep:
            return min(guidanceHeight ?? tallest, tallest)
        default:
            return tallest
        }
    }

    /// As tall as it is, up to the card's tallest, and scrolling past that: folded across, at large
    /// text, the rows would otherwise reach past the pane.
    private var panelHome: some View {
        CappedScroll(maxHeight: panelLayout.maxCardHeight) {
            HStack(spacing: 10) {
                searchPill
                    .background(.fill.tertiary, in: Capsule())
                stationLoadingSpinner
            }
            .padding(Metrics.m)
            // Between the field and the rows, unlike blocks: edge to edge.
            Divider()
            riderPanel(standsAlone: false)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            homeHeight = height
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Only the card's own stack writes here, and only while the card owns the path.
    private var sidePath: Binding<[MapRoute]> {
        let owner = owner
        return Binding(
            get: { path },
            set: { newPath in
                guard owner.usesSidePanel else { return }
                path = newPath
            }
        )
    }

    // MARK: - Compact: the sheet

    /// Up whenever a page is open, on the map tab, and not under the resume question: a sheet
    /// presented mid tab switch or over an alert fails.
    private var isCompactPanelUp: Bool {
        !owner.usesSidePanel && !path.isEmpty && appState.selectedTab == .map && !isResumingTrip
    }

    /// The panel closes from inside only (its close button, a page's own dismiss): it cannot be
    /// swiped away. A fold that takes the sheet down is not the rider closing it, so the path stays.
    private var compactPanelPresented: Binding<Bool> {
        Binding(
            get: { !usesSidePanel && !path.isEmpty && appState.selectedTab == .map && !isResumingTrip },
            set: { presented in
                guard !presented, isCompactPanelUp else { return }
                path.removeAll()
            }
        )
    }

    /// Opened by the search pill, the panel zooms out of it, and closes back into it; anything else
    /// rises as a sheet.
    @ViewBuilder
    private var compactPanel: some View {
        if (path.isEmpty ? lastPanelPath : path).first == .search {
            compactPanelStack
                .navigationTransition(.zoom(sourceID: Self.searchTransitionID, in: searchTransition))
        } else {
            compactPanelStack
        }
    }

    /// The first page is the sheet's root, with a close button and nothing to go back to; the rest
    /// is the stack.
    private var compactPanelStack: some View {
        let shown = path.isEmpty ? lastPanelPath : path
        let stops = panelStops(for: shown.last)
        return NavigationStack(path: compactTail) {
            Group {
                if let root = shown.first {
                    panelPage(root, isFirst: true)
                        .id(root)
                }
            }
            .navigationDestination(for: MapRoute.self) { panelPage($0, isFirst: false) }
        }
        .presentationDetents(stops.detents, selection: stopSelection(stops, on: shown.last))
        .presentationDragIndicator(.visible)
        // The map stays live above the panel's lower stops.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled()
    }

    private var compactTail: Binding<[MapRoute]> {
        let owner = owner
        return Binding(
            get: { Array((path.isEmpty ? lastPanelPath : path).dropFirst()) },
            set: { tail in
                guard !owner.usesSidePanel, let root = path.first else { return }
                path = [root] + tail
            }
        )
    }

    private var isAtTransferStep: Bool {
        container.tripSession.currentStep?.kind == .transfer
    }

    private func panelStops(for page: MapRoute?) -> PanelStops {
        guard let page else { return PanelStops(stops: [.large], opening: .large) }
        var placeOpening: PanelStop?
        if case .place(let id) = page { placeOpening = openedPlaces[id]?.opening }
        return PanelStops.forPage(
            page,
            placeOpening: placeOpening,
            guidanceHeight: guidanceHeight,
            isTransferStep: isAtTransferStep
        )
    }

    /// Where the panel rests on a page: where the rider left it, if that is still one of the page's
    /// stops, or where the page opens.
    private func restingStop(_ stops: PanelStops, on page: MapRoute?) -> PanelStop {
        guard let page, let remembered = panelStops[page], stops.stops.contains(remembered) else {
            return stops.opening
        }
        return remembered
    }

    private func stopSelection(_ stops: PanelStops, on page: MapRoute?) -> Binding<PresentationDetent> {
        Binding(
            get: { restingStop(stops, on: page).detent },
            set: { detent in
                guard let page, let stop = stops.stops.first(where: { $0.detent == detent }) else { return }
                panelStops[page] = stop
            }
        )
    }

    /// A page as the panel shows it. Its own background is cleared so the panel's shows through.
    ///
    /// In the card a page is pushed as a sidebar's are, the search page included: zoomed out of the
    /// card's own field while the card grows, the whole card vanished for a second (recorded on
    /// iOS 27).
    private func panelPage(_ page: MapRoute, isFirst: Bool) -> some View {
        destination(for: page)
            .environment(\.isInMapPanel, true)
            .containerBackground(.clear, for: .navigation)
            .toolbar {
                // Not on guidance, whose own way down says the trip keeps running, beside a Done
                // that ends it: a close button there would be a second hide.
                if isFirst, page != .guidance {
                    ToolbarItem(placement: .topBarTrailing) {
                        PanelCloseButton { path.removeAll() }
                            // The colour of the system's own close control, not the theme's.
                            .tint(.primary)
                    }
                }
            }
    }

    // MARK: - The map

    /// The page on top of the panel, as the map shows it.
    private var mapFocus: MapFocus {
        MapFocus.resolve(
            top: path.last,
            routes: planner.routes,
            shownAlternative: { detailSelections[$0] ?? $0 },
            lastOpenedRouteID: lastOpenedRouteID,
            lineMaps: lineMaps,
            guidedRoute: container.tripSession.route ?? guidanceRoute
        )
    }

    private var mapView: some View {
        let focus = mapFocus
        let browsing = focus.isBrowsing
        return TransitMapView(
            visibleRegion: camera(for: focus),
            stations: focus.stations ?? viewModel?.stations ?? [],
            // The browse map thins its stations by zoom; anything else is handed only the stops it
            // is about.
            alwaysShowsStations: !browsing,
            metroNetworks: viewModel?.metroNetworks ?? [],
            route: focus.route,
            showsUserLocation: viewModel?.isLocationAuthorized == true || focus.isGuidance,
            topChromeHeight: topChromeHeight,
            bottomChromeHeight: mapBottomChrome,
            leadingChromeWidth: usesSidePanel ? panelLayout.mapLeadingChrome : 0,
            // Faint enough that the trip or the line reads first, still there to place it in.
            networkAlpha: browsing ? 1 : 0.3,
            highlightLines: focus.highlightLines,
            onUserLocationChanged: { coordinate in
                container.locationService.observeMapSpaceUserLocation(coordinate)
                viewModel?.mapUserLocationChanged(coordinate)
                if riderCoordinate.map({ $0.distance(to: coordinate) > 25 }) ?? true {
                    riderCoordinate = coordinate
                }
            },
            onRegionChanged: { region in
                if let key = focus.cameraKey {
                    focusCameras[key] = region
                } else {
                    // Browsing only: what the map loads, and the camera a relaunch restores, follow
                    // the rider's own map, never a trip it was showing.
                    viewModel?.viewportChanged(to: region)
                    rememberCamera(region)
                }
            },
            onShownRegionChanged: browsing ? { viewModel?.shownRegion = $0 } : nil,
            onStationSelected: browsing ? openStation : { _ in },
            onPlaceTapped: browsing ? handlePlaceTapped : nil,
            onPlaceResolved: browsing ? handlePlaceResolved : nil,
            onMapLongPressed: browsing ? handleMapLongPressed : nil
        )
    }

    /// Browsing, the browse map's own camera, which a focus never touches, so leaving one flies back
    /// to where the rider was. Otherwise the focus's own, starting from its fitted region.
    private func camera(for focus: MapFocus) -> Binding<MapVisibleRegion?> {
        guard let key = focus.cameraKey else {
            return Binding(
                get: { viewModel?.visibleRegion },
                set: { viewModel?.visibleRegion = $0 }
            )
        }
        let fitted = focus.fittedRegion
        return Binding(
            get: { focusCameras[key] ?? fitted },
            set: { focusCameras[key] = $0 }
        )
    }

    /// The camera the guidance page frames and follows the rider with.
    private var guidanceCamera: Binding<MapVisibleRegion?> {
        Binding(
            get: { focusCameras[MapFocus.guidanceCameraKey] },
            set: { focusCameras[MapFocus.guidanceCameraKey] = $0 }
        )
    }

    /// What MapKit centres above. On a phone, the rider's panel at home and the sheet's resting
    /// height once a page is open, held to half the screen: above that the map is mostly covered,
    /// and margins taller than the map leave MapKit nothing to centre in. On a wide screen, nothing
    /// unless the phone is folded across, when everything from the crease down.
    private var mapBottomChrome: CGFloat {
        if usesSidePanel { return panelLayout.mapBottomChrome }
        guard let page = path.last else { return bottomChromeHeight }
        let covered = restingStop(panelStops(for: page), on: page).coveredHeight(in: shellSize.height)
        return min(covered, shellSize.height / 2)
    }

    /// Moves the browse camera onto something chosen, at no wider a zoom than the rider had.
    private func centre(on coordinate: CLLocationCoordinate2D) {
        let span = min(viewModel?.visibleRegion?.fittedDelta ?? MapCameraSpan.focused, MapCameraSpan.focused)
        viewModel?.updateCamera(to: coordinate, spanDelta: span)
    }

    // MARK: - Path changes

    /// Opens a page over the panel's top one, replacing it when both were chosen on the map: a
    /// second station or place tapped there is the rider changing their mind.
    private func show(_ page: MapRoute) {
        var next = path
        if let last = next.last, last.isMapSelection { next.removeLast() }
        next.append(page)
        path = next
    }

    private func showPlace(_ place: TappedPlace) {
        openedPlaces[place.id] = place
        activePlaceTap = place.id
        show(.place(place.id))
    }

    private func closePlace(_ id: UUID) {
        guard path.last == .place(id) else { return }
        path.removeLast()
    }

    private func openGuidance(for trip: Route) {
        guidanceRoute = trip
        path = [.guidance]
    }

    /// Back to the page before guidance, or to the map if guidance was the first page. Safe to run
    /// twice, which leaving does: once for the rider's End and once for the session ending.
    private func leaveGuidance() {
        guard let index = path.lastIndex(of: .guidance) else { return }
        path.removeSubrange(index...)
    }

    private func navigate(_ route: Route) {
        guidanceRoute = route
        path.append(.guidance)
    }

    /// Plans a trip from the rider's history again, from the Trips tab or search's recent trips.
    ///
    /// Each end is the place the trip started or ended on the ground. An end named "Current
    /// Location" starts from where the rider is now. A row saved before coordinates were kept has
    /// only names, and those are filled in as if typed: the planner resolves them the same way, and
    /// the results header shows what each became, where it can be changed.
    private func replay(_ record: TripRecord) {
        let ends: [(RouteInputField, String, CodableCoordinate?)] = [
            (.origin, record.originName, record.originCoordinate),
            (.destination, record.destinationName, record.destinationCoordinate)
        ]
        var fromHere: [RouteInputField] = []
        for (field, name, coordinate) in ends {
            if name == AppLocalization.localized("Current Location") {
                planner.updateName("", for: field)
                fromHere.append(field)
            } else if let coordinate {
                let location = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                planner.selectPlace(TransitPlace(name: name, coordinate: location), for: field)
            } else {
                planner.updateName(name, for: field)
            }
        }
        path = [.results]
        let planner = self.planner
        planTask?.cancel()
        planTask = Task {
            for field in fromHere { await planner.useCurrentLocation(for: field) }
            guard !Task.isCancelled else { return }
            _ = await planner.searchRoutes()
        }
    }

    /// A place the card has no Apple card for: a dropped pin, or a search result. Reverse geocoding
    /// may name a pin, and until it does, or if it never does, the coordinate itself is shown.
    /// Never a spinner: nothing is loading that could finish.
    private func placeSummaryCard(_ place: TappedPlace) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text(place.name)
                .font(.title3.weight(.semibold))
            if let address = place.address, !address.isEmpty {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: String(
                    format: "%.5f, %.5f",
                    place.coordinate.latitude,
                    place.coordinate.longitude
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.l)
    }

    /// Drops a pin wherever the rider pressed, so a place that is not an Apple POI can become an
    /// endpoint. Resets the same state `handlePlaceTapped` does: a resolve in flight must not
    /// replace this pin.
    private func handleMapLongPressed(_ coordinate: CLLocationCoordinate2D) {
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        pendingResolvedItem = nil
        let pin = TappedPlace(
            name: AppLocalization.text(
                english: "Dropped pin",
                simplified: "标记的位置",
                traditional: "標記的位置"
            ),
            coordinate: coordinate,
            isDroppedPin: true,
            opening: .low
        )
        showPlace(pin)
        placeMatchTask = Task {
            let named = try? await container.placeSearchProvider.reverseGeocode(
                location: coordinate,
                name: nil
            )
            guard !Task.isCancelled, let named else { return }
            // Only if the pin is still open: a second press while the first resolves must not get
            // the old name.
            guard openedPlaces[pin.id] != nil else { return }
            openedPlaces[pin.id]?.name = named.name
        }
    }

    /// A trip Live Go was running when iOS terminated the app, most likely underground. Asked
    /// rather than resumed: a saved trip can be hours stale.
    private func offerToResumeTrip() {
        // A tap on the trip outside the app launched this: that is the answer, and `openTrip()`
        // acts on it.
        guard !appState.pendingTripOpen else { return }
        guard pendingResumableTrip == nil, path.isEmpty else { return }
        // A trip already running in this launch has its own way back, the row in the rider's panel.
        guard !container.tripSession.isActive, let saved = container.tripSession.savedTrip() else { return }
        pendingResumableTrip = saved
        isResumingTrip = true
    }

    /// Brings up the navigator for the trip under way, or for the one a killed app left saved. The
    /// rider asked for it by tapping the trip outside the app, so a saved one is opened without
    /// the question `offerToResumeTrip()` puts.
    private func openTrip() {
        guard !path.contains(.guidance) else { return }
        let session = container.tripSession
        guard let trip = session.route ?? session.savedTrip() else { return }
        pendingResumableTrip = nil
        isResumingTrip = false
        openGuidance(for: trip)
    }

    /// Opens the map where the rider left it. Nothing is loaded from this: the viewport decides
    /// that.
    private func restoreCamera() {
        guard viewModel?.visibleRegion == nil else { return }
        guard let camera = appState.lastMapCamera else {
            // First launch, before any pan or fix: somewhere with a network, replaced by
            // `centerOnUser` once a fix arrives.
            viewModel?.updateCamera(to: Self.firstLaunchCenter, spanDelta: MapCameraSpan.city)
            return
        }
        viewModel?.updateCamera(
            to: CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
            spanDelta: camera.spanDelta
        )
    }

    /// Tiananmen, seen only on a first launch with location off: the largest bundled network, so
    /// the first screen has something drawn.
    private static let firstLaunchCenter = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)

    /// Debounced: a pan reports its region every frame, and each save is a JSON encode and a
    /// `UserDefaults` write on the main thread.
    private func rememberCamera(_ region: MapVisibleRegion) {
        cameraSaveTask?.cancel()
        cameraSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            appState.lastMapCamera = AppState.MapCamera(
                latitude: region.center.latitude,
                longitude: region.center.longitude,
                // Restored as a square, so the side MapKit fitted, not the one it widened.
                spanDelta: region.fittedDelta
            )
        }
    }

    /// A place's card: Apple's own once it has resolved, which draws its own header and close;
    /// until then, or where nothing is coming, what is known, under the panel's own bar.
    @ViewBuilder
    private func placePage(_ id: UUID) -> some View {
        if let place = openedPlaces[id] {
            // The tag identity stays anchored to the tapped name and coordinate, not the resolved
            // item's, which can shift slightly; a tag saved before resolution must still match.
            let taggedPlace = TransitPlace(
                name: place.name,
                coordinate: place.coordinate,
                address: place.resolvedItem?.placemark.title ?? place.address,
                source: .mapKit
            )
            ZStack {
                if let item = place.resolvedItem {
                    MapItemDetailSheet(mapItem: item) {
                        closePlace(id)
                    }
                    .ignoresSafeArea()
                } else if place.awaitsAppleCard {
                    PlaceLoadingView(name: place.name)
                } else {
                    placeSummaryCard(place)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    // The plan replaces this card: see `beginPlan`.
                    PlanRouteButtons(place: taggedPlace)
                    placeTagButton(for: taggedPlace)
                }
                .padding(.horizontal)
                // Before the background: the buttons clear a trailing tab bar while the material
                // spans the panel.
                .safeAreaPadding(.horizontal)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
            .toolbar(place.resolvedItem == nil ? .automatic : .hidden, for: .navigationBar)
            .quickTagEditor(
                isPresented: $showPlaceTagDialog,
                title: place.name,
                currentQuickTag: tripMemoryService.quickTag(place: taggedPlace),
                onSave: { kind in savePlaceTag(taggedPlace, kind: kind) },
                onDelete: {
                    if let existing = tripMemoryService.quickTag(place: taggedPlace) {
                        tripMemoryService.deleteQuickTag(id: existing.id)
                    }
                }
            )
        }
    }

    private func placeTagButton(for place: TransitPlace) -> some View {
        let currentQuickTag = tripMemoryService.quickTag(place: place)
        return Button {
            showPlaceTagDialog = true
        } label: {
            Image(systemName: currentQuickTag == nil ? "tag" : "tag.fill")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color.appSurface, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentQuickTag == nil
            ? AppLocalization.localized("Add Quick Tag")
            : AppLocalization.localized("Edit Quick Tag")
        )
    }

    private func savePlaceTag(_ place: TransitPlace, kind: StationQuickTagKind) {
        let location = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        guard let city = container.cityService.findNearestCity(to: location) else { return }
        tripMemoryService.setQuickTag(
            place: place,
            cityID: city.id,
            cityName: city.name,
            cityNameEn: city.nameEn,
            kind: kind
        )
    }

    /// A pill that looks like a search field and opens the search page. The whole pill is the
    /// button, so the surface that answers a touch is the part that opens search.
    private var searchPill: some View {
        Button {
            show(.search)
        } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(AppLocalization.text(
                    english: "Search places or stations",
                    simplified: "搜索地点或车站",
                    traditional: "搜尋地點或車站"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
            .padding(12)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The rider's own things: on a phone over the map, on a wide screen in the card under the
    /// search field. A trip does not end when its page closes, so the first row is the way back to
    /// one.
    private func riderPanel(standsAlone: Bool) -> some View {
        let session = container.tripSession
        return RiderPanel(
            trip: session.currentStep.map { step in
                RiderPanel.Trip(title: step.title, detail: session.stopsLeftText(for: step))
            },
            savedPlaces: tripMemoryService.stationQuickTags,
            nearest: riderCoordinate
                .flatMap { viewModel?.nearestStation(to: $0) }
                .map { RiderPanel.NearestStation(station: $0.station, distance: $0.distance) },
            onOpenTrip: {
                if let route = session.route { openGuidance(for: route) }
            },
            onSelectPlace: { tag in
                beginPlan(to: AppState.PendingRouteInput(place: tag.transitPlace, role: .destination))
            },
            onAddPlace: { appState.selectedTab = .trips },
            onOpenStation: openStation,
            standsAlone: standsAlone
        )
    }

    /// The one way this screen puts the camera on the rider, for the locate button and the first
    /// appearance alike, so they cannot land at different zooms.
    private func centerOnUser() {
        centerOnUserTask?.cancel()
        locateFailure = nil
        centerOnUserTask = Task {
            guard let outcome = await viewModel?.centerOnUser() else { return }
            if outcome.didCenter { didCenterOnUser = true }
            // Say why nothing moved: a fix that never arrives takes the full 15 s timeout, and
            // silence reads as a broken button.
            guard let failure = outcome.failureMessage else { return }
            locateFailure = failure
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            locateFailure = nil
        }
    }

    private var mapLocateButton: some View {
        Button {
            centerOnUser()
        } label: {
            Image(systemName: "location.fill")
                .font(.headline)
                .foregroundStyle(viewModel?.isLocationAuthorized == true ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .floatingChrome(in: Circle(), isInteractive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.localized("Center map on my location"))
    }

    private func openStation(_ station: Station) {
        // Opening a station wins over a place card: cancel a prior POI tap's station match, which
        // would otherwise open its card afterwards. Self-cancel is fine where `placeMatchTask`
        // itself calls this: nothing runs after the call, and `stationOpenTask` is a fresh task.
        placeMatchTask?.cancel()
        pendingResolvedItem = nil
        activePlaceTap = nil
        stationOpenTask?.cancel()
        stationOpenGeneration += 1
        let generation = stationOpenGeneration
        stationOpenTask = Task {
            isLoadingStationDetail = true
            defer {
                if stationOpenGeneration == generation {
                    isLoadingStationDetail = false
                }
            }

            let selected = await viewModel?.selectStation(station) ?? station
            guard !Task.isCancelled, stationOpenGeneration == generation else { return }
            openedStations[selected.id] = selected
            show(.station(id: selected.id))
            centre(on: selected.coordinate)
        }
    }

    /// A place chosen on the search page: a station opens its page; anything else recentres the
    /// map and opens its card above the search, so back returns to the results and "Route here" is
    /// one tap away however the place was found.
    private func selectSearchResult(_ place: TransitPlace) {
        // Tracked and cancelled, so rapid taps cannot stack station matches that complete out of
        // order.
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        // Every new interaction resets the POI-tap state, so a cancelled match's buffered resolve
        // cannot linger.
        pendingResolvedItem = nil
        activePlaceTap = nil
        placeMatchTask = Task {
            if let station = await viewModel?.matchingStation(for: place) {
                guard !Task.isCancelled else { return }
                openStation(station)
            } else {
                guard !Task.isCancelled else { return }
                centre(on: place.coordinate)
                showPlace(TappedPlace(
                    name: place.name,
                    coordinate: place.coordinate,
                    address: place.address
                ))
            }
        }
    }

    /// Phase 1 of a POI tap, synchronous with the feature's name and coordinate: the in-memory
    /// station match opens a station with no network wait; anything else opens the place card
    /// loading, filled by `handlePlaceResolved`.
    private func handlePlaceTapped(_ name: String?, _ coordinate: CLLocationCoordinate2D) {
        let displayName = name ?? AppLocalization.text(english: "Selected place", simplified: "所选地点", traditional: "所選地點")
        let place = TransitPlace(name: displayName, coordinate: coordinate, source: .mapKit)
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        pendingResolvedItem = nil
        // The card on screen belongs to an earlier tap: this tap's resolve must not fill it.
        activePlaceTap = nil
        placeMatchTask = Task {
            let station = await viewModel?.matchingStation(for: place)
            guard !Task.isCancelled else { return }
            if let station {
                pendingResolvedItem = nil
                openStation(station)
            } else {
                // Apple's resolve may finish while station matching runs (a cold pack load can
                // block it); open the card already filled.
                showPlace(TappedPlace(
                    name: displayName,
                    coordinate: coordinate,
                    resolvedItem: pendingResolvedItem,
                    awaitsAppleCard: true,
                    opening: .large
                ))
                pendingResolvedItem = nil
            }
        }
    }

    /// Phase 2 of a POI tap: the background `MKMapItemRequest` resolved. Both tasks are cancelled
    /// on every new tap, so this is always the latest tap. Fill its card in place, or buffer the
    /// item while station matching is still deciding.
    private func handlePlaceResolved(_ mapItem: MKMapItem) {
        if let id = activePlaceTap, openedPlaces[id]?.awaitsAppleCard == true {
            openedPlaces[id]?.resolvedItem = mapItem
        } else {
            pendingResolvedItem = mapItem
        }
    }

    // MARK: - Pages

    /// Never optional, so a push always resolves to a screen. See
    /// `DIContainer.sharedRoutePlannerViewModel()`.
    private var planner: RoutePlannerViewModel {
        container.sharedRoutePlannerViewModel()
    }

    /// "Route here", from anywhere in the app: straight to the results, whose From/To header shows
    /// a missing end and is where it is filled.
    private func beginPlan(to pending: AppState.PendingRouteInput) {
        // Consumed here, the only handler; left set it would re-fire.
        appState.pendingRouteInput = nil
        let planner = self.planner
        planner.selectPlace(pending.place, for: pending.role)

        // One assignment. A plan already open is replaced, so two results pages never share one
        // planner, and the station or place card the rider pressed the button on is replaced, not
        // stacked under.
        var next = path
        if let results = next.firstIndex(of: .results) { next.removeSubrange(results...) }
        if let last = next.last, last.isMapSelection { next.removeLast() }
        next.append(.results)
        path = next

        let target = pending.place.coordinate

        planTask?.cancel()
        planTask = Task {
            // The start defaults to where the rider is. A fix can take up to 15 s, which the
            // results page spends loading.
            if planner.name(for: .origin).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await planner.useCurrentLocation(for: .origin)
                // A rider in Beijing tapping a place in Guangzhou is not starting from where they
                // stand. Judged in metres, not by city (Foshan → Guangzhou is two cities and one
                // journey): 150 km is past the widest bundled network, corridors included.
                if let seeded = planner.place(for: .origin),
                   seeded.coordinate.distance(to: target) > 150_000 {
                    planner.updateName("", for: .origin)
                }
            }
            guard !Task.isCancelled else { return }
            guard !planner.name(for: .origin).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // No fix and nothing typed: say which end is missing rather than run a search that
                // can only fail.
                planner.errorMessage = AppLocalization.text(
                    english: "Choose a start above to see routes.",
                    simplified: "请在上方选择起点后查看路线。",
                    traditional: "請在上方選擇起點後查看路線。"
                )
                return
            }
            _ = await planner.searchRoutes()
        }
    }

    /// Fills one end from the search page, returns to the results and re-plans. Not through
    /// `pendingRouteInput`, which starts a plan and would open a second results page.
    private func fillEndpoint(_ field: RouteInputField, with place: TransitPlace) {
        planner.selectPlace(place, for: field)
        if case .editEndpoint = path.last { path.removeLast() }
        replan()
    }

    /// Re-runs the current plan, for the endpoint editor and the swap button alike.
    private func replan() {
        planTask?.cancel()
        planTask = Task { _ = await planner.searchRoutes() }
    }

    /// A route chosen from the results. Step-by-Step Guidance (cognitive accessibility) goes
    /// straight on to the navigator, in the same assignment, and leaving it lands on the detail.
    private func openRoute(_ route: Route) {
        lastOpenedRouteID = route.id
        if appState.accessibilityPreference.stepByStepGuidance {
            guidanceRoute = route
            path.append(contentsOf: [.detail(route.id), .guidance])
        } else {
            path.append(.detail(route.id))
        }
    }

    private func openRoutePage(_ destination: RouteDetailDestination, routeID: UUID) {
        switch destination {
        case .transfer(let segment):
            path.append(.transfer(routeID: routeID, segmentID: segment.id))
        case .station(let stop):
            path.append(.routeStop(routeID: routeID, stopID: stop.id))
        case .confidence(let id):
            path.append(.confidence(id))
        }
    }

    @ViewBuilder
    private func destination(for page: MapRoute) -> some View {
        switch page {
        case .search:
            SearchPageView(
                onSelectStation: { openStation($0) },
                onSelectPlace: { selectSearchResult($0) },
                onSelectLine: { path.append(.line(cityID: $0.cityID, lineID: $0.lineID)) },
                onSelectRecentTrip: { replay($0) }
            )
        case .editEndpoint(let field):
            SearchPageView(
                onSelectStation: { fillEndpoint(field, with: $0.asTransitPlace) },
                onSelectPlace: { fillEndpoint(field, with: $0) },
                title: field == .origin
                    ? AppLocalization.text(english: "Choose a start", simplified: "选择起点", traditional: "選擇起點")
                    : AppLocalization.text(english: "Choose a destination", simplified: "选择终点", traditional: "選擇終點")
            )
        case .results:
            RouteResultsView(
                viewModel: planner,
                onSelect: openRoute,
                onEditEndpoint: { path.append(.editEndpoint($0)) },
                onUseCurrentLocation: {
                    planTask?.cancel()
                    planTask = Task {
                        await planner.useCurrentLocation(for: .origin)
                        guard !Task.isCancelled else { return }
                        _ = await planner.searchRoutes()
                    }
                },
                onSwap: {
                    planner.swapOriginDestination()
                    replan()
                },
                onReplan: replan
            )
        case .detail(let routeID):
            if let route = planner.routes.first(where: { $0.id == routeID }) {
                let selection = Binding(
                    get: { detailSelections[routeID] ?? routeID },
                    set: { detailSelections[routeID] = $0 }
                )
                RouteDetailView(
                    route: route,
                    preference: planner.sortStrategy,
                    alternatives: planner.routes,
                    tripAnchor: planner.tripAnchor,
                    accessibilityFilter: planner.accessibilityFilter,
                    selectedRouteID: selection,
                    onOpen: { openRoutePage($0, routeID: selection.wrappedValue) },
                    onNavigate: navigate
                )
            } else {
                // The routes were cleared while this was open: say so.
                StaleRoutesNotice()
                    .background(Color.appBackground)
            }
        case .transfer(let routeID, let segmentID):
            routePage(routeID) { route in
                route.segments.first { $0.id == segmentID }.map(RouteDetailDestination.transfer)
            }
        case .routeStop(let routeID, let stopID):
            routePage(routeID) { route in
                route.segments.flatMap(\.stationStops).first { $0.id == stopID }.map(RouteDetailDestination.station)
            }
        case .confidence(let routeID):
            routePage(routeID) { _ in .confidence(routeID) }
        case .station(let stationID):
            if let station = openedStations[stationID] {
                // The map replaces this page with the results itself; see the `pendingRouteInput`
                // handler.
                StationDetailView(
                    station: station,
                    dismissesOnRouteSelection: false,
                    onSelectLine: { path.append(.line(cityID: $0.cityID, lineID: $0.lineID)) }
                )
            } else {
                // Unreachable by construction (the station is stored before the push), but a screen
                // that says something beats an empty one.
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(
                            english: "Station unavailable",
                            simplified: "车站不可用",
                            traditional: "車站不可用"
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(AppLocalization.text(
                        english: "Go back and choose the station again.",
                        simplified: "请返回重新选择车站。",
                        traditional: "請返回重新選擇車站。"
                    ))
                }
                .background(Color.appBackground)
            }
        case .place(let id):
            placePage(id)
        case .line(let cityID, let lineID):
            LineDetailView(cityID: cityID, lineID: lineID) { lineMaps[$0.key] = $0 }
        case .guidance:
            if let trip = container.tripSession.route ?? guidanceRoute {
                let shown = path.isEmpty ? lastPanelPath : path
                LiveGoView(
                    route: trip,
                    // Opened from a route's page, Back returns there, after asking; as the first
                    // page it hides.
                    embedded: shown.first != .guidance,
                    camera: guidanceCamera,
                    onFittedHeight: { guidanceHeight = $0 },
                    onExit: leaveGuidance
                )
            }
        }
    }

    /// One of a route's own pages, against the route as the planner holds it now.
    @ViewBuilder
    private func routePage(
        _ routeID: UUID,
        destination: (Route) -> RouteDetailDestination?
    ) -> some View {
        if let route = planner.routes.first(where: { $0.id == routeID }),
           let destination = destination(route) {
            RouteDetailDestinationPage(
                route: route,
                destination: destination,
                preference: planner.sortStrategy,
                alternatives: planner.routes,
                accessibilityFilter: planner.accessibilityFilter
            )
        } else {
            StaleRoutesNotice()
                .background(Color.appBackground)
        }
    }

    #if DEBUG
    /// Lands a headless launch on a page: this environment has no tap injection, so a seeded path
    /// is the only way to see anything above the map's home.
    private func seedDebugScreen() {
        // Puts the camera somewhere specific without a pan gesture.
        if let camera = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_CAMERA"] {
            let parts = camera.split(separator: ",").compactMap { Double($0) }
            if parts.count >= 3 {
                didCenterOnUser = true
                viewModel?.updateCamera(
                    to: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
                    spanDelta: parts[2]
                )
            }
        }
        // A named line, landed on its own page.
        if let line = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_LINE"] {
            let parts = line.split(separator: ",").map(String.init)
            if parts.count >= 2 {
                didCenterOnUser = true
                path = [.line(cityID: parts[0], lineID: parts[1])]
                return
            }
        }
        // The card a long press opens: the press cannot be injected, so the handler is driven
        // directly.
        if let pin = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_PIN"] {
            let parts = pin.split(separator: ",").compactMap { Double($0) }
            if parts.count >= 2 {
                didCenterOnUser = true
                viewModel?.updateCamera(
                    to: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
                    spanDelta: MapCameraSpan.focused
                )
                handleMapLongPressed(CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]))
                return
            }
        }
        // A named station's page, the one screen the planner does not produce, and the one where a
        // wrong accessibility claim has a physical cost. Named rather than derived, because the
        // station decides which data source answers.
        if let station = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_STATION"] {
            Task {
                guard await waitForNetwork() else { return }
                guard let match = viewModel?.stations.first(where: {
                    $0.localizedName == station || $0.name == station || $0.stationID == station
                }) else { return }
                // Through `openStation`, not a direct push: the page reads `openedStations`, which
                // only that path fills.
                openStation(match)
            }
        }

        // Pages opened and closed one after another, a few seconds apart, so a screen recording shows
        // the transitions between them: "search,home,results,detail,guiding,pop,pop,home". "station"
        // opens the route's first stop; "trips" and "map" switch tabs.
        if let sequence = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SEQUENCE"] {
            let steps = sequence.split(separator: ",").map(String.init)
            let pause = Double(ProcessInfo.processInfo.environment["JUST_GO_DEBUG_STEP_SECONDS"] ?? "") ?? 2
            Task { await playDebugSequence(steps, pause: pause) }
            return
        }

        guard let screen = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SCREEN"] else { return }
        switch screen {
        case "search":
            path = [.search]
        case "results", "detail", "guiding", "editEndpoint", "tripRunning", "transfer", "routeStop", "confidence":
            Task { await seedDebugRoute(landingOn: screen) }
        case "resume":
            // The answer to "Resume your trip?", which is a tap on an alert.
            if let saved = container.tripSession.savedTrip() {
                pendingResumableTrip = nil
                isResumingTrip = false
                openGuidance(for: saved)
            }
        default:
            break
        }
    }

    /// Waits for the viewport loader to deliver stations, bounded. The route seeds need a loaded
    /// pack, and the loader is debounced and asynchronous, so reading `stations` at `.task` time
    /// can find it empty.
    private func waitForNetwork(seconds: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let stations = viewModel?.stations, stations.count >= 2 { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func playDebugSequence(_ steps: [String], pause: Double) async {
        guard let route = await planDebugRoute() else { return }
        for step in steps {
            try? await Task.sleep(for: .seconds(pause))
            switch step {
            case "home": path = []
            case "search": show(.search)
            case "results": path = [.results]
            case "detail": openRoute(route)
            case "guiding": navigate(route)
            case "pop": if !path.isEmpty { path.removeLast() }
            case "station": if let station = route.mapStations.first { openStation(station) }
            case "trips": appState.selectedTab = .trips
            case "map": appState.selectedTab = .map
            default: break
            }
        }
    }

    private func seedDebugRoute(landingOn screen: String) async {
        guard let first = await planDebugRoute() else { return }
        switch screen {
        case "results":
            path = [.results]
        case "editEndpoint":
            path = [.results, .editEndpoint(.origin)]
        case "tripRunning":
            // A trip under way with its page closed: the map as the rider finds it on coming back.
            container.tripSession.start(first)
        case "guiding":
            guidanceRoute = first
            path = [.results, .detail(first.id), .guidance]
        case "transfer":
            // The route's first change of lines, the page a tap on its leg opens.
            guard let change = first.segments.first(where: { $0.type == .transfer }) else { return }
            path = [.results, .detail(first.id), .transfer(routeID: first.id, segmentID: change.id)]
        case "routeStop":
            guard let stop = first.segments.flatMap(\.stationStops).first else { return }
            path = [.results, .detail(first.id), .routeStop(routeID: first.id, stopID: stop.id)]
        case "confidence":
            path = [.results, .detail(first.id), .confidence(first.id)]
        default:
            path = [.results, .detail(first.id)]
            // The phone's panel stop is a drag, which cannot be injected here, so its range is
            // checked by seeding each one.
            switch ProcessInfo.processInfo.environment["JUST_GO_DEBUG_MAP_FRACTION"] {
            case "low": panelStops[.detail(first.id)] = .low
            case "medium": panelStops[.detail(first.id)] = .medium
            case "top", "large": panelStops[.detail(first.id)] = .large
            default: break
            }
        }
    }

    /// Plans a real trip between the two most separated loaded stations, or `JUST_GO_DEBUG_ENDPOINTS`.
    private func planDebugRoute() async -> Route? {
        guard await waitForNetwork() else { return nil }
        guard let stations = viewModel?.stations, stations.count >= 2 else { return nil }
        let plannerViewModel = planner
        // "departBy+90" / "arriveBy+90": minutes from now, the only way to see the "Leave by …"
        // banner without a tap.
        if let anchor = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_ANCHOR"] {
            let parts = anchor.split(separator: "+")
            let minutes = parts.count > 1 ? Double(parts[1]) ?? 60 : 60
            let date = Date().addingTimeInterval(minutes * 60)
            switch parts.first {
            case "departBy": plannerViewModel.tripAnchor = .departBy(date)
            case "arriveBy": plannerViewModel.tripAnchor = .arriveBy(date)
            default: break
            }
        }
        // A named pair, for when which lines the trip rides matters (a service-hours check needs
        // one line stopped and another running).
        if let endpoints = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_ENDPOINTS"] {
            let parts = endpoints.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 4 else { return nil }
            plannerViewModel.selectPlace(
                debugPlace(at: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])),
                for: .origin
            )
            plannerViewModel.selectPlace(
                debugPlace(at: CLLocationCoordinate2D(latitude: parts[2], longitude: parts[3])),
                for: .destination
            )
        } else {
            let sortedByLatitude = stations.sorted { $0.latitude < $1.latitude }
            guard let south = sortedByLatitude.first, let north = sortedByLatitude.last else { return nil }
            plannerViewModel.selectPlace(debugPlace(at: south.coordinate), for: .origin)
            plannerViewModel.selectPlace(debugPlace(at: north.coordinate), for: .destination)
        }
        guard await plannerViewModel.searchRoutes(), let first = plannerViewModel.routes.first else { return nil }
        lastOpenedRouteID = first.id
        return first
    }

    /// A bare coordinate as an endpoint: the planner walks to the nearest station, as for a dropped
    /// pin.
    private func debugPlace(at coordinate: CLLocationCoordinate2D) -> TransitPlace {
        TransitPlace(
            name: String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude),
            coordinate: coordinate,
            source: .localStationData
        )
    }
    #endif
}

/// The place card's loading state: the tapped POI's name and a spinner, until Apple's card has a
/// resolved item.
private struct PlaceLoadingView: View {
    let name: String
    var body: some View {
        VStack(spacing: 14) {
            Text(name)
                .font(.headline)
                .multilineTextAlignment(.center)
            ProgressView()
            Text(AppLocalization.text(
                english: "Loading details…",
                simplified: "正在加载详情…",
                traditional: "正在載入詳情…"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
