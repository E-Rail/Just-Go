import SwiftUI
import MapKit
import CoreLocation
import UIKit

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
    /// The destination, if the rider came from a place card, travels in
    /// `AppState.pendingRouteInput` — `TransitPlace` is not `Hashable` and a navigation value is
    /// the wrong place to carry it anyway.
    case routeEntry
    case results
    case detail(UUID)
    case station(Station)
}

struct MapContainerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var viewModel: MapViewModel?
    /// Owned here rather than by the entry screen: the planner's routes have to outlive the entry
    /// page so that results and detail, both pushed above it, read the same search.
    @State private var plannerViewModel: RoutePlannerViewModel?
    @State private var path: [MapRoute] = []
    @State private var tappedPlace: TappedPlace?
    @State private var showPlaceTagDialog = false
    @State private var showCityPicker = false
    @State private var isLoadingStationDetail = false
    @State private var placeMatchTask: Task<Void, Never>?
    @State private var stationOpenTask: Task<Void, Never>?
    @State private var centerOnUserTask: Task<Void, Never>?
    @State private var didCenterOnUser = false
    @State private var stationOpenGeneration = 0
    @State private var placeCardDetent: PresentationDetent = .large
    // Holds an MKMapItem that resolved while station matching was still deciding whether to
    // present the place sheet — consumed (or discarded) when that decision lands.
    @State private var pendingResolvedItem: MKMapItem?

    var body: some View {
        NavigationStack(path: $path) {
            mapContent
                .navigationDestination(for: MapRoute.self) { destination(for: $0) }
        }
        .task(id: appState.selectedCity?.id) {
            if viewModel == nil {
                viewModel = container.makeMapViewModel()
            }
            if plannerViewModel == nil {
                plannerViewModel = container.makeRoutePlannerViewModel()
            }
            plannerViewModel?.cityChanged(to: appState.selectedCity)

            guard let city = appState.selectedCity else { return }
            await viewModel?.loadStations(for: city)
            // Open on the rider, not on a city centroid. Only the first time the map appears:
            // re-running on every city change would fight a city the rider just picked by hand.
            // When location is unavailable — denied, restricted, or the fix times out — this is
            // a no-op and the city view `loadStations` already set is what stays on screen.
            guard !didCenterOnUser else { return }
            didCenterOnUser = true
            centerOnUser()
            #if DEBUG
            seedDebugScreen()
            #endif
        }
        // A place card's "Route here" only records the place; the push happens here, so every
        // sender — map POI, search result, station detail — reaches the entry page the same way
        // and none of them has to know what the navigation stack looks like.
        .onChange(of: appState.pendingRouteInput) { _, pending in
            guard pending != nil, !path.contains(.routeEntry) else { return }
            path.append(.routeEntry)
        }
        // A city switch invalidates any in-flight POI/station interaction from the old city.
        // During a POI tap's station match no sheet is presented yet, so the city picker stays
        // reachable — without this reset a slow match started in city A presents its place
        // sheet (or pushes its station detail) over city B's map, and a slow locate-me fix
        // (up to the 15s GPS timeout) yanks city B's camera back to the user's position.
        .onChange(of: appState.selectedCity?.id) { _, _ in
            placeMatchTask?.cancel()
            stationOpenTask?.cancel()
            centerOnUserTask?.cancel()
            // Kill the old city's place search here rather than waiting for the deferred
            // .task(id:) reload — its results must not flash under the new city.
            viewModel?.clearSearch()
            stationOpenGeneration += 1
            isLoadingStationDetail = false
            pendingResolvedItem = nil
            tappedPlace = nil
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
            }
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
        // explicit `tappedPlace = nil` closure would fire for the OLD sheet's dismissal —
        // clobbering a new tap's sheet presented while the old one was still animating out.
        .sheet(item: $tappedPlace) { place in
            // Keep the tag identity anchored to the tapped annotation's name/coordinate, not
            // the resolved MKMapItem's — resolution can shift both slightly, and a tag saved
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
            // screen) on every presentation and requires a manual drag to reach .large —
            // that drag can get eaten by the embedded MKMapItemDetailViewController's own
            // scroll content. Binding + resetting to .large in handlePlaceTapped makes the
            // card open already expanded instead of relying on that drag succeeding.
            .presentationDetents([.medium, .large], selection: $placeCardDetent)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCityPicker) {
            CityPickerView(selectedCity: Binding(
                get: { appState.selectedCity },
                set: { appState.selectedCity = $0 }
            ))
        }
        .onDisappear {
            placeMatchTask?.cancel()
            stationOpenTask?.cancel()
            centerOnUserTask?.cancel()
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
            onRegionChanged: { region in
                viewModel?.viewportChanged(to: region)
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
        guard let city = container.cityService.findNearestCity(to: location) ?? appState.selectedCity else {
            return
        }
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

                Button(action: { showCityPicker = true }) {
                    HStack(spacing: 4) {
                        Text(appState.selectedCity?.localizedName ?? AppLocalization.localized("City"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
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

    /// The one way this screen ever puts the camera on the rider — used by the locate button and
    /// by the map's first appearance, so the two cannot land at different zooms or disagree about
    /// the city. That inconsistency was the complaint: the same intent behaved differently
    /// depending on which path ran it.
    private func centerOnUser() {
        centerOnUserTask?.cancel()
        centerOnUserTask = Task {
            // Locating also aligns the app to the city the rider is physically in
            // (bounded — see centerOnUser): the camera alone moving left the city
            // pill, station search, and planner stuck on the old city.
            if let city = await viewModel?.centerOnUser() {
                appState.selectedCity = city
            }
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
        // Opening a station always wins over a place card — dismiss any place sheet AND cancel a
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
            path.append(.station(selected))
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
            if let station = await viewModel?.matchingStation(for: place, city: appState.selectedCity) {
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
    /// fast in-memory station match — a tapped POI that *is* a programmed station opens the
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
        // tap's sheet in handlePlaceResolved — enforced here rather than relying on sheets
        // blocking background map taps (true today, but a detent/background-interaction
        // change would silently route the new resolve into the old sheet).
        tappedPlace = nil
        placeMatchTask = Task {
            let station = await viewModel?.matchingStation(for: place, city: appState.selectedCity)
            guard !Task.isCancelled else { return }
            if let station {
                pendingResolvedItem = nil
                tappedPlace = nil
                openStation(station)
            } else {
                // Apple's resolve may have finished while station matching was still running
                // (it can block on a cold city-pack load) — present the sheet already filled
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

    @ViewBuilder
    private func destination(for route: MapRoute) -> some View {
        switch route {
        case .search:
            SearchPageView(
                onSelectStation: { openStation($0) },
                onSelectPlace: { selectSearchResult($0) }
            )
        case .routeEntry:
            if let plannerViewModel {
                RouteEntryView(viewModel: plannerViewModel) {
                    path.append(.results)
                }
            }
        case .results:
            if let plannerViewModel {
                RouteResultsView(viewModel: plannerViewModel) { route in
                    path.append(.detail(route.id))
                }
            }
        case .detail(let routeID):
            if let plannerViewModel,
               let route = plannerViewModel.routes.first(where: { $0.id == routeID }) {
                RouteDetailView(
                    route: route,
                    preference: plannerViewModel.sortStrategy,
                    alternatives: plannerViewModel.routes,
                    tripAnchor: plannerViewModel.tripAnchor,
                    accessibilityFilter: plannerViewModel.accessibilityFilter
                )
            }
        case .station(let station):
            StationDetailView(station: station)
        }
    }

    #if DEBUG
    /// Lands a headless launch on a pushed screen. There is no tap injection in this environment —
    /// this Xcode install ships no Simulator.app at all — so without a way to seed the path, every
    /// screen above the map root is unreachable and therefore unverifiable.
    private func seedDebugScreen() {
        guard let screen = ProcessInfo.processInfo.environment["JUSTGO_DEBUG_SCREEN"] else { return }
        switch screen {
        case "search":
            path = [.search]
        case "entry":
            path = [.routeEntry]
        case "results", "detail", "guiding":
            Task { await seedDebugRoute(landingOn: screen) }
        default:
            break
        }
    }

    /// Plans a real trip between the two most widely separated stations the map has loaded for
    /// this city, through the same `selectPlace` + `searchRoutes` path a rider drives — so what
    /// gets screenshotted is the real screen and not a fixture. Widest separation rather than a
    /// hardcoded pair so this works in any city, and so the route has transfers in it.
    private func seedDebugRoute(landingOn screen: String) async {
        guard let plannerViewModel, let stations = viewModel?.stations, stations.count >= 2 else { return }
        let sortedByLatitude = stations.sorted { $0.latitude < $1.latitude }
        guard let south = sortedByLatitude.first, let north = sortedByLatitude.last else { return }
        plannerViewModel.selectPlace(debugPlace(for: south), for: .origin)
        plannerViewModel.selectPlace(debugPlace(for: north), for: .destination)
        guard await plannerViewModel.searchRoutes(), let first = plannerViewModel.routes.first else { return }
        path = screen == "results"
            ? [.routeEntry, .results]
            : [.routeEntry, .results, .detail(first.id)]
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


/// Pick a place by pointing at it, for riders who know where they mean but not what it is called.
///
/// Centre-pin rather than tap-to-drop: the pin is fixed at the middle of the screen and the map
/// moves under it. That is what Apple Maps, Uber and Didi all do for this task, and it needs no
/// new gesture plumbing — `TransitMapView` already reports every camera move through
/// `onRegionChanged`, which is the only signal this needs.
struct MapPlacePickerView: View {
    let field: RouteInputField
    let initialCoordinate: CLLocationCoordinate2D
    let onSelect: (TransitPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(DIContainer.self) private var container
    @State private var visibleRegion: MapVisibleRegion?
    @State private var resolvedPlace: TransitPlace?
    @State private var isResolving = false
    @State private var resolveTask: Task<Void, Never>?

    init(
        field: RouteInputField,
        initialCoordinate: CLLocationCoordinate2D,
        onSelect: @escaping (TransitPlace) -> Void
    ) {
        self.field = field
        self.initialCoordinate = initialCoordinate
        self.onSelect = onSelect
        _visibleRegion = State(initialValue: MapVisibleRegion(
            center: initialCoordinate,
            latitudeDelta: MapCameraSpan.focused,
            longitudeDelta: MapCameraSpan.focused
        ))
    }

    private var centerCoordinate: CLLocationCoordinate2D {
        visibleRegion?.center ?? initialCoordinate
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TransitMapView(
                    visibleRegion: $visibleRegion,
                    stations: [],
                    metroNetworks: [],
                    route: nil,
                    showsUserLocation: container.locationService.isAuthorized,
                    onRegionChanged: { region in
                        visibleRegion = region
                        scheduleResolve(for: region.center)
                    },
                    onStationSelected: { _ in }
                )
                .ignoresSafeArea()

                centerPin
            }
            .safeAreaInset(edge: .bottom) { selectionBar }
            .navigationTitle(field == .origin
                ? AppLocalization.text(english: "Choose start", simplified: "选择起点", traditional: "選擇起點")
                : AppLocalization.text(english: "Choose destination", simplified: "选择终点", traditional: "選擇終點"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { dismiss() }
                }
            }
        }
        .task { scheduleResolve(for: initialCoordinate) }
        .onDisappear { resolveTask?.cancel() }
    }

    /// Drawn at the map's centre and lifted by half its own height so the point of the pin — not
    /// the middle of the glyph — sits on the coordinate being chosen.
    private var centerPin: some View {
        Image(systemName: "mappin")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .offset(y: -17)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(resolvedPlace?.name ?? coordinateLabel)
                    .font(.headline)
                    .lineLimit(1)
                if let address = resolvedPlace?.address, !address.isEmpty {
                    Text(address).rowMeta().lineLimit(1)
                } else if isResolving {
                    Text(AppLocalization.text(
                        english: "Looking up this place…",
                        simplified: "正在识别该地点…",
                        traditional: "正在辨識該地點…"
                    ))
                    .rowMeta()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.default, value: resolvedPlace)

            Button {
                onSelect(selectedPlace)
                dismiss()
            } label: {
                Text(field == .origin
                    ? AppLocalization.text(english: "Set as start", simplified: "设为起点", traditional: "設為起點")
                    : AppLocalization.text(english: "Set as destination", simplified: "设为终点", traditional: "設為終點"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.regularMaterial)
    }

    /// Shown until the geocode lands, and kept as the name when nothing resolves. A coordinate is
    /// a perfectly good destination, so confirm stays enabled throughout rather than making the
    /// rider wait on a lookup that may never return a name for a spot in a park.
    private var coordinateLabel: String {
        String(format: "%.5f, %.5f", centerCoordinate.latitude, centerCoordinate.longitude)
    }

    private var selectedPlace: TransitPlace {
        if let resolvedPlace, resolvedPlace.coordinate.isEssentiallyEqual(to: centerCoordinate) {
            return resolvedPlace
        }
        return TransitPlace(name: coordinateLabel, coordinate: centerCoordinate, source: .mapKit)
    }

    /// Debounced: the map reports a region on every frame of a pan, and CLGeocoder rate-limits
    /// hard enough that resolving each one would return nothing at all.
    private func scheduleResolve(for coordinate: CLLocationCoordinate2D) {
        resolveTask?.cancel()
        isResolving = true
        resolveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let place = try? await container.placeSearchProvider.reverseGeocode(
                location: coordinate,
                name: nil
            )
            guard !Task.isCancelled else { return }
            isResolving = false
            guard let place, coordinate.isEssentiallyEqual(to: centerCoordinate) else { return }
            resolvedPlace = place.withSource(.mapKit)
        }
    }
}

private extension CLLocationCoordinate2D {
    /// Same coordinate to roughly a metre — enough to tell "the map has not moved since this
    /// lookup started" from "the rider panned away and this result is stale".
    func isEssentiallyEqual(to other: CLLocationCoordinate2D) -> Bool {
        abs(latitude - other.latitude) < 0.00001 && abs(longitude - other.longitude) < 0.00001
    }
}

struct CityPickerView: View {
    @Binding var selectedCity: City?
    @Environment(\.dismiss) private var dismiss
    @Environment(DIContainer.self) private var container
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?

    private var cities: [City] {
        container.cityService.getAllCities()
    }

    private var filteredCities: [City] {
        let query = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return cities }
        return cities.filter { city in
            [
                city.id,
                city.name,
                city.nameEn,
                city.localizedName,
                city.alternateLocalizedName
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredCities) { city in
                Button(action: {
                    selectedCity = city
                    dismiss()
                }) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(city.localizedName)
                                    .font(.headline)
                                if let alternateName = city.alternateLocalizedName {
                                    Text(alternateName)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 8)

                            if selectedCity?.id == city.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }

                            Text(AppLocalization.stationCount(city.stationCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        CityCapabilityTags(
                            coverage: city.dataCapabilities.coverage,
                            hasOfficialOnlineStationInformation:
                                container.stationInformationDirectory.servesStationInformation(cityID: city.id)
                        )
                        .equatable()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(AppLocalization.localized("Select City"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: AppLocalization.localized("Search cities"))
            .onChange(of: searchText) { _, newValue in
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    debouncedQuery = newValue
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { dismiss() }
                }
            }
        }
    }
}
