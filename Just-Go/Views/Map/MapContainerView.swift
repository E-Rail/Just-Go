import SwiftUI
import MapKit
import CoreLocation

/// A tapped Apple POI. `id` is stable for the lifetime of the tap so that flipping
/// `resolvedItem` from nil → the resolved `MKMapItem` updates the already-presented sheet
/// in place (loading shell → Apple card) instead of dismissing and re-presenting it.
private struct TappedPlace: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    var resolvedItem: MKMapItem?
    /// A pin the rider dropped on bare ground rather than an Apple POI they tapped. There is no
    /// `MKMapItem` coming for one of these, so the loading shell below would spin forever.
    var isDroppedPin = false
}

/// Everything the map can push, as one path enum rather than a `navigationDestination` per screen:
/// several `isPresented` registrations on one node shadow each other, and a path is what a headless
/// launch can seed.
enum MapRoute: Hashable {
    case search
    /// The search page again, opened from the results header to refill one end of the trip.
    /// Picking a result fills that field and returns; it does not open a place card.
    case editEndpoint(RouteInputField)
    /// The destination, when the rider came from a place card, travels in
    /// `AppState.pendingRouteInput`: `TransitPlace` is not `Hashable`.
    case results
    case detail(UUID)
    /// The station's **id**, not the object: a reference type in a navigation path can fail to
    /// resolve, and an unresolved value renders as a blank pushed screen. The object is held beside
    /// the path in `openedStations`.
    case station(id: String)
    /// A line, keyed the same way: `MetroLine` is not `Hashable`, and the ids fetch it from the
    /// cached network.
    case line(cityID: String, lineID: String)
}

struct MapContainerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var viewModel: MapViewModel?
    @State private var path: [MapRoute] = []
    @State private var tappedPlace: TappedPlace?
    @State private var showPlaceTagDialog = false
    @State private var isLoadingStationDetail = false
    @State private var cameraSaveTask: Task<Void, Never>?
    @State private var placeMatchTask: Task<Void, Never>?
    @State private var stationOpenTask: Task<Void, Never>?
    @State private var centerOnUserTask: Task<Void, Never>?
    /// How tall the floating chrome over the map's top edge is, so the map centres the rider in the
    /// part they can see.
    @State private var topChromeHeight: CGFloat = 0
    @State private var planTask: Task<Void, Never>?
    @State private var didCenterOnUser = false
    /// Non-nil for a few seconds after a locate attempt that could not produce a fix.
    @State private var locateFailure: String?
    @State private var stationOpenGeneration = 0
    @State private var placeCardDetent: PresentationDetent = .large
    // Holds an MKMapItem that resolved while station matching was still deciding whether to
    // present the place sheet: consumed (or discarded) when that decision lands.
    @State private var pendingResolvedItem: MKMapItem?
    /// Stations that have been pushed, keyed by the id carried in the path.
    @State private var openedStations: [String: Station] = [:]
    /// A trip still running when the app was last killed: `pendingResumableTrip` is being asked
    /// about, `resumableTrip` is the one the rider accepted. See `offerToResumeTrip`.
    @State private var pendingResumableTrip: Route?
    @State private var resumableTrip: Route?
    @State private var isResumingTrip = false

    var body: some View {
        NavigationStack(path: $path) {
            mapContent
                .navigationDestination(for: MapRoute.self) { destination(for: $0) }
        }
        // The map tab lives as long as the app: a popped station's enriched copy is released when
        // it leaves the path.
        .onChange(of: path) { _, newPath in
            let stillOpen = Set(newPath.compactMap { route -> String? in
                if case .station(let id) = route { return id }
                return nil
            })
            openedStations = openedStations.filter { stillOpen.contains($0.key) }
        }
        .task {
            if viewModel == nil {
                viewModel = container.makeMapViewModel()
            }
            restoreCamera()
            #if DEBUG
            // Before the centring guard below, which returns once a fix has landed and would skip
            // the seed on a second run of this task.
            seedDebugScreen()
            #endif
            // Open on the rider, retried until it lands. With location unavailable (denied,
            // restricted, or timed out) this does nothing and the restored camera stays.
            guard !didCenterOnUser else { return }
            centerOnUser()
        }
        .task { offerToResumeTrip() }
        // Full screen rather than a push: a rider back in the app underground wants the navigator,
        // not a map.
        .fullScreenCover(item: $resumableTrip) { trip in
            LiveGoView(route: trip) {
                resumableTrip = nil
                ActiveTripStore.clear()
            }
        }
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
                resumableTrip = trip
            }
            Button(
                AppLocalization.text(english: "Discard", simplified: "放弃", traditional: "放棄"),
                role: .destructive
            ) {
                pendingResumableTrip = nil
                ActiveTripStore.clear()
            }
        } message: { trip in
            Text(verbatim: "\(trip.origin) → \(trip.destination)")
        }
        // A place card's "Route here" only records the place and the push happens here, so every
        // sender (map POI, search result, station page) starts a plan the same way without knowing
        // the navigation stack.
        .onChange(of: appState.pendingRouteInput) { _, pending in
            guard let pending else { return }
            beginPlan(to: pending)
        }
        .onChange(of: appState.pendingTripReplay, initial: true) { _, record in
            guard let record else { return }
            appState.pendingTripReplay = nil
            replay(record)
        }
        // Accessibility Settings reach the planner here: seeded on appear and re-seeded on change,
        // so results planned under an old preference are dropped.
        .task(id: appState.accessibilityPreference) {
            if planner.syncAccessibilityPreference(appState.accessibilityPreference) {
                path.removeAll()
            }
        }
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

    /// A pin on bare ground. Reverse geocoding may name it, and until it does — or if it never
    /// does — the coordinate itself is shown. Never a spinner: nothing is loading that could finish.
    private func droppedPinCard(_ place: TappedPlace) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text(place.name)
                .font(.title3.weight(.semibold))
            Text(verbatim: String(
                format: "%.5f, %.5f",
                place.coordinate.latitude,
                place.coordinate.longitude
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.l)
    }

    /// Drops a pin wherever the rider pressed, so a place that is not an Apple POI can become an
    /// endpoint. Resets the same state `handlePlaceTapped` does: a resolve in flight must not
    /// replace this pin.
    private func handleMapLongPressed(_ coordinate: CLLocationCoordinate2D) {
        placeCardDetent = .fraction(0.3)
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        pendingResolvedItem = nil
        tappedPlace = TappedPlace(
            name: AppLocalization.text(
                english: "Dropped pin",
                simplified: "标记的位置",
                traditional: "標記的位置"
            ),
            coordinate: coordinate,
            isDroppedPin: true
        )
        placeMatchTask = Task {
            let named = try? await container.placeSearchProvider.reverseGeocode(
                location: coordinate,
                name: nil
            )
            guard !Task.isCancelled, let named else { return }
            // Only if this is still the pin on screen: a second press while the first resolves must
            // not get the old name.
            guard let current = tappedPlace, current.isDroppedPin,
                  current.coordinate.latitude == coordinate.latitude,
                  current.coordinate.longitude == coordinate.longitude else { return }
            tappedPlace = TappedPlace(
                name: named.name,
                coordinate: coordinate,
                isDroppedPin: true
            )
        }
    }

    /// A trip Live Go was running when iOS terminated the app, most likely underground. Asked
    /// rather than resumed: a saved trip can be hours stale.
    private func offerToResumeTrip() {
        guard pendingResumableTrip == nil, resumableTrip == nil, path.isEmpty else { return }
        guard let saved = ActiveTripStore.load() else { return }
        pendingResumableTrip = saved
        isResumingTrip = true
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
                spanDelta: region.maxDelta
            )
        }
    }

    private var mapContent: some View {
        ZStack {
            mapView
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 10) {
                topControls
                HStack(spacing: 8) {
                    Spacer()
                    if viewModel?.metroNetworks.isEmpty == false {
                        MetroGeometryAttributionView()
                            .lineLimit(1)
                            .layoutPriority(0)
                    }
                    mapLocateButton
                        .layoutPriority(1)
                }
                if let locateFailure {
                    Text(locateFailure)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: locateFailure)
            .padding(.horizontal)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .zIndex(2)
            // Measured, not constant: the pill and attribution row grow with Dynamic Type, and a
            // failed locate adds a third row.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                topChromeHeight = height
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle(AppLocalization.localized("Map"))
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.visible, for: .tabBar)
        // No `onDismiss`: `sheet(item:)` already nils the binding, and an explicit `tappedPlace =
        // nil` would fire for the old sheet's dismissal and clobber a new tap's sheet.
        .sheet(item: $tappedPlace) { place in
            // The tag identity stays anchored to the tapped name and coordinate, not the resolved
            // item's, which can shift slightly; a tag saved before resolution must still match.
            let taggedPlace = TransitPlace(
                name: place.name,
                coordinate: place.coordinate,
                address: place.resolvedItem?.placemark.title,
                source: .mapKit
            )
            Group {
                if let item = place.resolvedItem {
                    MapItemDetailSheet(mapItem: item) {
                        tappedPlace = nil
                    }
                    .ignoresSafeArea()
                } else if place.isDroppedPin {
                    droppedPinCard(place)
                } else {
                    PlaceLoadingView(name: place.name)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    PlanRouteButtons(
                        place: taggedPlace,
                        onSelected: { tappedPlace = nil }
                    )
                    placeTagButton(for: taggedPlace)
                }
                .padding(.horizontal)
                // Before the background: the buttons clear a trailing tab bar while the material
                // spans the sheet.
                .safeAreaPadding(.horizontal)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
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
            // A selection binding, reset in the tap handlers: without one the sheet opens at the
            // smallest detent, and the drag to expand can be eaten by Apple's embedded card's
            // scroll view. A dropped pin opens lower: a name and a coordinate need little room, and
            // the rider is pointing at the map.
            .presentationDetents(
                place.isDroppedPin ? [.fraction(0.3), .medium, .large] : [.medium, .large],
                selection: $placeCardDetent
            )
            .presentationDragIndicator(.visible)
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

    private var mapView: some View {
        TransitMapView(
            visibleRegion: Binding(
                get: { viewModel?.visibleRegion },
                set: { viewModel?.visibleRegion = $0 }
            ),
            stations: viewModel?.stations ?? [],
            // The browse map draws no trip, so ordinary browsing keeps its station thinning.
            alwaysShowsStations: false,
            metroNetworks: viewModel?.metroNetworks ?? [],
            route: nil,
            showsUserLocation: viewModel?.isLocationAuthorized == true,
            topChromeHeight: topChromeHeight,
            onUserLocationChanged: { coordinate in
                container.locationService.observeMapSpaceUserLocation(coordinate)
                viewModel?.mapUserLocationChanged(coordinate)
            },
            onRegionChanged: { region in
                viewModel?.viewportChanged(to: region)
                rememberCamera(region)
            },
            onStationSelected: openStation,
            onPlaceTapped: handlePlaceTapped,
            onPlaceResolved: handlePlaceResolved,
            onMapLongPressed: handleMapLongPressed
        )
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

    /// A pill that looks like a search field and opens the search page: searching gets the whole
    /// screen.
    private var topControls: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Button {
                    path.append(.search)
                } label: {
                    Text(AppLocalization.text(
                        english: "Search places or stations",
                        simplified: "搜索地点或车站",
                        traditional: "搜尋地點或車站"
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .elevated(.floating)
            .accessibilityElement(children: .contain)

            if isLoadingStationDetail {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .zIndex(20)
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
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.localized("Center map on my location"))
    }

    private func openStation(_ station: Station) {
        // Opening a station wins over a place card: dismiss any place sheet and cancel a prior POI
        // tap's station match, which would otherwise present its sheet afterwards. Self-cancel is
        // fine where `placeMatchTask` itself calls this: nothing runs after the call, and
        // `stationOpenTask` is a fresh task.
        placeMatchTask?.cancel()
        pendingResolvedItem = nil
        tappedPlace = nil
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
            path.append(.station(id: selected.id))
        }
    }

    /// A place chosen on the search page: a station opens its detail; anything else recentres the
    /// map and presents its card, so "Route here" is one tap away however the place was found.
    private func selectSearchResult(_ place: TransitPlace) {
        // Tracked and cancelled, so rapid taps cannot stack station matches that complete out of
        // order.
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        // Every new interaction resets the POI-tap state, so a cancelled match's buffered resolve
        // cannot linger.
        pendingResolvedItem = nil
        tappedPlace = nil
        placeCardDetent = .medium
        placeMatchTask = Task {
            if let station = await viewModel?.matchingStation(for: place) {
                guard !Task.isCancelled else { return }
                openStation(station)
            } else {
                guard !Task.isCancelled else { return }
                viewModel?.updateCamera(to: place.coordinate, spanDelta: MapCameraSpan.focused)
                tappedPlace = TappedPlace(
                    name: place.name,
                    coordinate: place.coordinate,
                    resolvedItem: nil
                )
            }
        }
    }

    /// Phase 1 of a POI tap, synchronous with the feature's name and coordinate: the in-memory
    /// station match opens a station with no network wait; anything else presents the place sheet
    /// loading, filled by `handlePlaceResolved`.
    private func handlePlaceTapped(_ name: String?, _ coordinate: CLLocationCoordinate2D) {
        let displayName = name ?? AppLocalization.text(english: "Selected place", simplified: "所选地点", traditional: "所選地點")
        let place = TransitPlace(name: displayName, coordinate: coordinate, source: .mapKit)
        placeCardDetent = .large
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        pendingResolvedItem = nil
        // Dismiss any prior tap's sheet first, so a non-nil `tappedPlace` in `handlePlaceResolved`
        // always means this tap's.
        tappedPlace = nil
        placeMatchTask = Task {
            let station = await viewModel?.matchingStation(for: place)
            guard !Task.isCancelled else { return }
            if let station {
                pendingResolvedItem = nil
                tappedPlace = nil
                openStation(station)
            } else {
                // Apple's resolve may finish while station matching runs (a cold pack load can
                // block it); present the sheet already filled.
                tappedPlace = TappedPlace(name: displayName, coordinate: coordinate, resolvedItem: pendingResolvedItem)
                pendingResolvedItem = nil
            }
        }
    }

    /// Phase 2 of a POI tap: the background `MKMapItemRequest` resolved. Both tasks are cancelled
    /// on every new tap, so this is always the latest tap. Fill the presented sheet in place, or
    /// buffer the item while station matching is still deciding.
    private func handlePlaceResolved(_ mapItem: MKMapItem) {
        if tappedPlace != nil {
            tappedPlace?.resolvedItem = mapItem
        } else {
            pendingResolvedItem = mapItem
        }
    }

    // MARK: - Pushed screens

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

        // One assignment: the station card the rider pressed the button on is replaced, not stacked
        // under.
        var next = path
        if case .station = next.last { next.removeLast() }
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

    /// Fills one end from the search page and re-plans. Not through `pendingRouteInput`, which
    /// starts a plan and would push a second results screen.
    private func fillEndpoint(_ field: RouteInputField, with place: TransitPlace) {
        planner.selectPlace(place, for: field)
        replan()
    }

    /// Re-runs the current plan, for the endpoint editor and the swap button alike.
    private func replan() {
        planTask?.cancel()
        planTask = Task { _ = await planner.searchRoutes() }
    }

    @ViewBuilder
    private func destination(for route: MapRoute) -> some View {
        switch route {
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
                dismissesOnSelection: true
            )
        case .results:
            RouteResultsView(
                viewModel: planner,
                onSelect: { route in
                    path.append(.detail(route.id))
                },
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
                RouteDetailView(
                    route: route,
                    preference: planner.sortStrategy,
                    alternatives: planner.routes,
                    tripAnchor: planner.tripAnchor,
                    accessibilityFilter: planner.accessibilityFilter
                )
            } else {
                // The routes were cleared while this was pushed: say so.
                StaleRoutesNotice()
                    .background(Color.appBackground)
            }
        case .station(let stationID):
            if let station = openedStations[stationID] {
                // The map replaces this screen with the results itself; see the `pendingRouteInput`
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
        case .line(let cityID, let lineID):
            LineDetailView(cityID: cityID, lineID: lineID)
        }
    }

    #if DEBUG
    /// Lands a headless launch on a pushed screen: this environment has no tap injection, so a
    /// seeded path is the only way to see anything above the map root.
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
                // Through `openStation`, not a direct push: the destination reads `openedStations`,
                // which only that path fills.
                openStation(match)
            }
        }

        guard let screen = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SCREEN"] else { return }
        switch screen {
        case "search":
            path = [.search]
        case "results", "detail", "guiding", "editEndpoint":
            Task { await seedDebugRoute(landingOn: screen) }
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

    private func seedDebugRoute(landingOn screen: String) async {
        guard await waitForNetwork() else { return }
        guard let stations = viewModel?.stations, stations.count >= 2 else { return }
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
            guard parts.count >= 4 else { return }
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
            guard let south = sortedByLatitude.first, let north = sortedByLatitude.last else { return }
            plannerViewModel.selectPlace(debugPlace(at: south.coordinate), for: .origin)
            plannerViewModel.selectPlace(debugPlace(at: north.coordinate), for: .destination)
        }
        guard await plannerViewModel.searchRoutes(), let first = plannerViewModel.routes.first else { return }
        switch screen {
        case "results":
            path = [.results]
        case "editEndpoint":
            path = [.results, .editEndpoint(.origin)]
        default:
            path = [.results, .detail(first.id)]
        }
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

/// The place sheet's loading state: the tapped POI's name and a spinner, until Apple's card has a
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
