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
}

/// Everything the map can push. One path enum rather than a `navigationDestination` per screen:
/// five separate `isPresented` registrations on one node is the pattern that shadowed a sheet and
/// cost this app its Settings screen, and a path is also the only thing a headless launch can seed
/// to reach a screen it cannot tap its way to.
enum MapRoute: Hashable {
    case search
    /// The search page again, opened from the results header to refill one end of the trip.
    /// Picking a result fills that field and returns; it does not open a place card.
    case editEndpoint(RouteInputField)
    /// The destination, if the rider came from a place card, travels in
    /// `AppState.pendingRouteInput`: `TransitPlace` is not `Hashable` and a navigation value is
    /// the wrong place to carry it anyway.
    case results
    case detail(UUID)
    /// The station's **id**, not the object. A navigation path value should be a small value type:
    /// `Station` is a `final class`, and a reference type in the path is the kind of thing that
    /// resolves fine on one iOS version and silently fails to resolve on another, and a value the
    /// stack cannot resolve renders as a pushed screen with no title and no content, which is what
    /// a blank page is. The object itself is held beside the path in `openedStations`.
    case station(id: String)
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

    var body: some View {
        NavigationStack(path: $path) {
            mapContent
                .navigationDestination(for: MapRoute.self) { destination(for: $0) }
        }
        .task {
            if viewModel == nil {
                viewModel = container.makeMapViewModel()
            }
            restoreCamera()
            #if DEBUG
            // Ahead of the centring guard below, which returns early once a fix has landed. The
            // seeding used to sit after it and so silently did nothing on any second run of this
            // task, which reads as "the harness is flaky" rather than "the harness never ran".
            seedDebugScreen()
            #endif
            // Open on the rider. Retried until it actually lands, not merely until it has been
            // attempted; when location is unavailable. Denied, restricted, or the fix times out
            //. This is a no-op and the restored camera is what stays on screen.
            guard !didCenterOnUser else { return }
            centerOnUser()
        }
        // A place card's "Route here" only records the place; the push happens here, so every
        // sender: map POI, search result, station detail. Reaches the entry page the same way
        // and none of them has to know what the navigation stack looks like.
        .onChange(of: appState.pendingRouteInput) { _, pending in
            guard let pending else { return }
            beginPlan(to: pending)
        }
        // The planner's `basePreference` had no writer, so everything set in Accessibility
        // Settings: step-free requirement, lift preference, avoid-stairs, and the walking-distance
        // limit the long-walk warning is measured against. Stopped at the settings screen and
        // never reached a plan. Seeded here on appear, and re-seeded on change so a preference
        // switched mid-session drops results planned under the old one.
        .task(id: appState.accessibilityPreference) {
            if planner.syncAccessibilityPreference(appState.accessibilityPreference) {
                path.removeAll()
            }
        }
    }

    /// Opens the map where the rider left it. Nothing is loaded from this. The viewport decides
    /// that, so a stale camera costs a pan, not a wrong network.
    private func restoreCamera() {
        guard viewModel?.visibleRegion == nil else { return }
        guard let camera = appState.lastMapCamera else {
            // First launch, before any pan and before any fix. Somewhere with a network rather
            // than the whole globe; `centerOnUser` replaces it the moment a fix arrives.
            viewModel?.updateCamera(to: Self.firstLaunchCenter, spanDelta: MapCameraSpan.city)
            return
        }
        viewModel?.updateCamera(
            to: CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
            spanDelta: camera.spanDelta
        )
    }

    /// Tiananmen, only ever seen on a first launch with location off. The largest bundled
    /// network, so the opening screen has something drawn on it.
    private static let firstLaunchCenter = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)

    /// Debounced: a pan reports its region every frame, and each save is a JSON encode plus a
    /// `UserDefaults` write on the main thread. Only where the pan *stopped* is worth keeping.
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
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle(AppLocalization.localized("Map"))
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.visible, for: .tabBar)
        // No keyboard-height tracking here any more: the map's search field moved to its own
        // page, so this screen has no text input to make room for.
        // No onDismiss here: sheet(item:) already nils the binding on dismissal, and an
        // explicit `tappedPlace = nil` closure would fire for the OLD sheet's dismissal.
        // Clobbering a new tap's sheet presented while the old one was still animating out.
        .sheet(item: $tappedPlace) { place in
            // Keep the tag identity anchored to the tapped annotation's name/coordinate, not
            // the resolved MKMapItem's: resolution can shift both slightly, and a tag saved
            // before resolution must keep matching the same place afterward.
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
            // No selection binding here defaults to the SMALLEST detent (.medium, half
            // screen) on every presentation and requires a manual drag to reach .large,
            // that drag can get eaten by the embedded MKMapItemDetailViewController's own
            // scroll content. Binding + resetting to .large in handlePlaceTapped makes the
            // card open already expanded instead of relying on that drag succeeding.
            .presentationDetents([.medium, .large], selection: $placeCardDetent)
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
            metroNetworks: viewModel?.metroNetworks ?? [],
            route: nil,
            showsUserLocation: viewModel?.isLocationAuthorized == true,
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
            onPlaceResolved: handlePlaceResolved
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

    /// A pill that *looks* like a search field but is a button to the search page. Typing used to
    /// happen here, over the map, with the results hanging below in a dropdown whose height had to
    /// be measured against the keyboard on every frame. Searching deserves the whole screen, and
    /// the map underneath deserves not to be half-covered while you do it.
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

    /// The one way this screen ever puts the camera on the rider. Used by the locate button and
    /// by the map's first appearance, so the two cannot land at different zooms. That
    /// inconsistency was the complaint: the same intent behaved differently depending on which
    /// path ran it.
    private func centerOnUser() {
        centerOnUserTask?.cancel()
        locateFailure = nil
        centerOnUserTask = Task {
            guard let outcome = await viewModel?.centerOnUser() else { return }
            if outcome.didCenter { didCenterOnUser = true }
            // Say why nothing moved. A fix that never arrives burns the location request's full
            // 15 s timeout and then did nothing at all. No camera move, no message, which reads
            // as the button being broken rather than the fix being missing.
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
        // Opening a station always wins over a place card. Dismiss any place sheet AND cancel a
        // prior POI tap's still-running station match, which would otherwise present a place
        // sheet over/after this station navigation when it eventually completes. (Self-cancel is
        // fine on the paths where placeMatchTask itself calls openStation: nothing runs after
        // that call, and stationOpenTask below is a fresh Task that doesn't inherit cancellation.)
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

    /// A place chosen on the search page. One that *is* a programmed station opens the station
    /// detail; anything else recentres the map on it and presents its card, so "Route here" is one
    /// tap away whether the rider found the place by pointing at it or by typing its name.
    private func selectSearchResult(_ place: TransitPlace) {
        // Track + cancel so rapidly tapping results can't stack matchingStation calls whose
        // out-of-order completion would open the wrong station detail.
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        // Same entry-point invariant as handlePlaceTapped/openStation: every new interaction
        // resets the POI-tap state, so a cancelled match's buffered resolve can't linger.
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

    /// Phase 1 of a POI tap: fires synchronously with the feature's name + coordinate. Runs the
    /// fast in-memory station match: a tapped POI that *is* a programmed station opens the
    /// station detail with no network wait; anything else immediately presents the place sheet in
    /// a loading state, which `handlePlaceResolved` fills once Apple's resolve completes.
    private func handlePlaceTapped(_ name: String?, _ coordinate: CLLocationCoordinate2D) {
        let displayName = name ?? AppLocalization.text(english: "Selected place", simplified: "所选地点", traditional: "所選地點")
        let place = TransitPlace(name: displayName, coordinate: coordinate, source: .mapKit)
        placeCardDetent = .large
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        pendingResolvedItem = nil
        // Dismiss any prior tap's sheet up front so "tappedPlace != nil" always means THIS
        // tap's sheet in handlePlaceResolved. Enforced here rather than relying on sheets
        // blocking background map taps (true today, but a detent/background-interaction
        // change would silently route the new resolve into the old sheet).
        tappedPlace = nil
        placeMatchTask = Task {
            let station = await viewModel?.matchingStation(for: place)
            guard !Task.isCancelled else { return }
            if let station {
                pendingResolvedItem = nil
                tappedPlace = nil
                openStation(station)
            } else {
                // Apple's resolve may have finished while station matching was still running
                // (it can block on a cold city-pack load). Present the sheet already filled
                // instead of dropping the item and spinning forever.
                tappedPlace = TappedPlace(name: displayName, coordinate: coordinate, resolvedItem: pendingResolvedItem)
                pendingResolvedItem = nil
            }
        }
    }

    /// Phase 2 of a POI tap: the background MKMapItemRequest resolved. Both `poiTask` (in the map
    /// coordinator) and `placeMatchTask` are cancelled on every new tap, so this only ever fires
    /// for the latest tap. When the sheet is already presented, fill it in place; when station
    /// matching is still deciding (slower than the resolve on a cold city-pack load), buffer the
    /// item for `handlePlaceTapped` to attach at presentation time.
    private func handlePlaceResolved(_ mapItem: MKMapItem) {
        if tappedPlace != nil {
            tappedPlace?.resolvedItem = mapItem
        } else {
            pendingResolvedItem = mapItem
        }
    }

    // MARK: - Pushed screens

    /// Never optional, so a push can never resolve to nothing. See
    /// `DIContainer.sharedRoutePlannerViewModel()`.
    private var planner: RoutePlannerViewModel {
        container.sharedRoutePlannerViewModel()
    }

    /// "Route here": the one action every place card offers, from anywhere in the app.
    ///
    /// Goes straight to the results, which carry their own From/To header. There is no form in
    /// between: it asked the rider to confirm a destination they had just tapped and a start the
    /// app already knew, so it existed only to be dismissed. When an end is genuinely missing the
    /// results say so in that header, which is also where it gets filled in.
    private func beginPlan(to pending: AppState.PendingRouteInput) {
        // Consumed here rather than by the pushed screen: this is the only handler, and leaving it
        // set would re-fire the moment anything else observed it.
        appState.pendingRouteInput = nil
        let planner = self.planner
        planner.selectPlace(pending.place, for: pending.role)

        // One assignment: see the note on MapRoute.station about a pop and a push in one frame.
        // The station card the rider pressed the button on is replaced, not stacked under.
        var next = path
        if case .station = next.last { next.removeLast() }
        next.append(.results)
        path = next

        let target = pending.place.coordinate

        planTask?.cancel()
        planTask = Task {
            // "The start defaults to where you are." This used to be a form's job; the rider no
            // longer sees that form, so the seeding happens here instead. A fix can take up to
            // 15 s, which the results page spends saying it is loading. A better wait than an
            // empty field on a page whose only purpose is to be dismissed.
            if planner.name(for: .origin).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await planner.useCurrentLocation(for: .origin)
                // A rider in Beijing tapping a place in Guangzhou is not starting from where they
                // are standing, and silently seeding it produces nonsense. Judged in metres rather
                // than by city, because "different city" was never the question: Foshan→Guangzhou
                // is two cities and one perfectly plannable journey. 150 km is past the span of
                // the widest bundled network, intercity corridors included.
                if let seeded = planner.place(for: .origin),
                   seeded.coordinate.distance(to: target) > 150_000 {
                    planner.updateName("", for: .origin)
                }
            }
            guard !Task.isCancelled else { return }
            guard !planner.name(for: .origin).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // No fix and nothing typed. Say which end is missing rather than running a search
                // that can only fail: the header above is where the rider fixes it.
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

    /// Fills one end of the trip from the search page and re-plans. Deliberately not routed
    /// through `pendingRouteInput`: that channel *starts* a plan, and starting one from here would
    /// push a second results screen on top of the one the rider is editing.
    private func fillEndpoint(_ field: RouteInputField, with place: TransitPlace) {
        planner.selectPlace(place, for: field)
        replan()
    }

    /// Re-runs the current plan. Shared by the endpoint editor and the header's swap button so the
    /// two cannot disagree about what a changed endpoint means.
    private func replan() {
        planTask?.cancel()
        planTask = Task { _ = await planner.searchRoutes() }
    }

    private var staleRouteNotice: some View {
        ContentUnavailableView {
            Label(AppLocalization.localized("No Routes Found"), systemImage: "map")
        } description: {
            Text(AppLocalization.text(
                english: "This search is no longer current. Go back and search again.",
                simplified: "此次搜索已失效，请返回重新搜索。",
                traditional: "此次搜尋已失效，請返回重新搜尋。"
            ))
        }
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func destination(for route: MapRoute) -> some View {
        switch route {
        case .search:
            SearchPageView(
                onSelectStation: { openStation($0) },
                onSelectPlace: { selectSearchResult($0) }
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
                onSelect: { route in path.append(.detail(route.id)) },
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
                }
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
                // The routes were cleared while this was pushed. Say so. A screen that
                // explains itself beats a screen that is simply empty.
                staleRouteNotice
            }
        case .station(let stationID):
            if let station = openedStations[stationID] {
                // The map replaces this screen with the entry page itself. See the
                // pendingRouteInput handler above.
                StationDetailView(station: station, dismissesOnRouteSelection: false)
            } else {
                // Cannot happen by construction: the station is stored before the push, but a
                // screen that says something is strictly better than one that says nothing.
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
        }
    }

    #if DEBUG
    /// Lands a headless launch on a pushed screen. There is no tap injection in this environment.
    /// This Xcode install ships no Simulator.app at all, so without a way to seed the path, every
    /// screen above the map root is unreachable and therefore unverifiable.
    private func seedDebugScreen() {
        // Puts the camera somewhere specific without a pan gesture. The sibling of
        // JUST_GO_DEBUG_SCREEN, and the only way to screenshot a named station in this
        // environment, which has no gesture injection at all.
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
        // A named trip, planned through the real planner and landed on its detail page. The
        // station-derived seeding below cannot reach a specific route, and this environment has no
        // way to type two endpoints into a form.
        if let trip = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_ROUTE"] {
            let parts = trip.split(separator: ",").compactMap { Double($0) }
            if parts.count >= 4 {
                didCenterOnUser = true
                Task { await seedDebugTrip(parts) }
                return
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

    /// Plans a real trip between the two most widely separated stations the map has loaded for
    /// this city, through the same `selectPlace` + `searchRoutes` path a rider drives, so what
    /// gets screenshotted is the real screen and not a fixture. Widest separation rather than a
    /// hardcoded pair so this works in any city, and so the route has transfers in it.
    private func seedDebugRoute(landingOn screen: String) async {
        guard let stations = viewModel?.stations, stations.count >= 2 else { return }
        let plannerViewModel = planner
        let sortedByLatitude = stations.sorted { $0.latitude < $1.latitude }
        guard let south = sortedByLatitude.first, let north = sortedByLatitude.last else { return }
        plannerViewModel.selectPlace(debugPlace(for: south), for: .origin)
        plannerViewModel.selectPlace(debugPlace(for: north), for: .destination)
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

    private func seedDebugTrip(_ parts: [Double]) async {
        let plannerViewModel = planner
        plannerViewModel.selectPlace(
            TransitPlace(name: "A", coordinate: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]), source: .localStationData),
            for: .origin
        )
        plannerViewModel.selectPlace(
            TransitPlace(name: "B", coordinate: CLLocationCoordinate2D(latitude: parts[2], longitude: parts[3]), source: .localStationData),
            for: .destination
        )
        guard await plannerViewModel.searchRoutes(), let first = plannerViewModel.routes.first else { return }
        path = [.results, .detail(first.id)]
    }

    private func debugPlace(for station: Station) -> TransitPlace {
        TransitPlace(
            name: station.localizedName,
            coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude),
            source: .localStationData
        )
    }
    #endif
}

/// The place sheet's loading state: shows the tapped POI's name + a spinner immediately, before
/// Apple's native card (which needs a fully-resolved MKMapItem) is ready.
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
