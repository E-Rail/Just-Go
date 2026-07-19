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

/// Reports the search pill's rendered bottom edge (post-padding/shadow) in `.global` space,
/// so the results dropdown's height cap tracks Dynamic Type growth instead of a hardcoded offset.
private struct SearchBarBottomYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MapContainerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var viewModel: MapViewModel?
    @State private var selectedStation: Station?
    @State private var tappedPlace: TappedPlace?
    @State private var showPlaceTagDialog = false
    @State private var showCityPicker = false
    @State private var showNetworkLineStatus = false
    @State private var isLoadingStationDetail = false
    @State private var placeMatchTask: Task<Void, Never>?
    @State private var stationOpenTask: Task<Void, Never>?
    @State private var centerOnUserTask: Task<Void, Never>?
    @State private var stationOpenGeneration = 0
    @State private var placeCardDetent: PresentationDetent = .large
    // Holds an MKMapItem that resolved while station matching was still deciding whether to
    // present the place sheet — consumed (or discarded) when that decision lands.
    @State private var pendingResolvedItem: MKMapItem?
    @State private var keyboardHeight: CGFloat = 0
    @State private var searchBarBottomY: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    private let searchDropdownSpacing: CGFloat = 8

    var body: some View {
        NavigationStack {
            mapContent
        }
        .task(id: appState.selectedCity?.id) {
            if viewModel == nil {
                viewModel = container.makeMapViewModel()
            }

            guard let city = appState.selectedCity else { return }
            await viewModel?.loadStations(for: city)
        }
        .onChange(of: viewModel?.searchText ?? "") { _, _ in
            viewModel?.scheduleSearch(in: appState.selectedCity)
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
                    if appState.selectedCity != nil {
                        Button {
                            showNetworkLineStatus = true
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "tram.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                Text(AppLocalization.localized("Lines"))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .padding(8)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .layoutPriority(1)
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
        .onPreferenceChange(SearchBarBottomYKey.self) { searchBarBottomY = $0 }
        // keyboardWillChangeFrame alone covers show, hide, and in-place resizes (QuickType
        // bar, predictive text) so one observer suffices; keyboardWillHide is a defensive
        // reset in case a dismissal path doesn't fire a frame-change notification.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
            withAnimation(.easeInOut(duration: duration)) {
                keyboardHeight = max(0, UIScreen.main.bounds.height - value.cgRectValue.origin.y)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
            withAnimation(.easeInOut(duration: duration)) {
                keyboardHeight = 0
            }
        }
        .navigationDestination(item: $selectedStation) { station in
            StationDetailView(station: station)
        }
        .onChange(of: selectedStation?.id) { _, newID in
            if newID == nil { isLoadingStationDetail = false }
        }
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
        .sheet(isPresented: $showNetworkLineStatus) {
            NetworkLineStatusView(cityID: appState.selectedCity?.id ?? "")
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
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
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

    private var topControls: some View {
        VStack(spacing: searchDropdownSpacing) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    TextField(AppLocalization.text(english: "Search places...", simplified: "搜索地点...", traditional: "搜尋地點..."), text: Binding(
                        get: { viewModel?.searchText ?? "" },
                        set: { viewModel?.searchText = $0 }
                    ))
                    .focused($isSearchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .textFieldStyle(.plain)
                    .frame(minHeight: 28)

                    if viewModel?.searchText.isEmpty == false {
                        Button {
                            viewModel?.clearSearch()
                            isSearchFocused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 8)

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
                .contentShape(Rectangle())
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SearchBarBottomYKey.self, value: proxy.frame(in: .global).maxY)
                    }
                }
                .onTapGesture {
                    isSearchFocused = true
                }
                .accessibilityElement(children: .contain)

                if isLoadingStationDetail {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            if isSearchFocused && viewModel?.searchResults.isEmpty == false {
                searchResultsDropdown
                    .zIndex(20)
            }
        }
        .zIndex(20)
    }

    // keyboardTopY and searchBarBottomY are both measured in `.global` screen space, matching
    // UIScreen.main.bounds, so this needs no window-relative coordinate conversion.
    private var searchDropdownMaxHeight: CGFloat {
        let keyboardTopY = UIScreen.main.bounds.height - keyboardHeight
        return max(0, keyboardTopY - searchBarBottomY - searchDropdownSpacing)
    }

    private var searchResultsDropdown: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(viewModel?.searchResults ?? []) { place in
                    Button {
                        selectSearchResult(place)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                if let address = place.address, !address.isEmpty {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if place.id != viewModel?.searchResults.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: searchDropdownMaxHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }

    private var mapLocateButton: some View {
        Button {
            centerOnUserTask?.cancel()
            centerOnUserTask = Task {
                // Locate also aligns the app to the city the user is physically in
                // (bounded — see centerOnUser): the camera alone moving left the city
                // pill, station search, and planner stuck on the old city.
                if let city = await viewModel?.centerOnUser() {
                    appState.selectedCity = city
                }
            }
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
            selectedStation = selected
        }
    }

    /// A search result that is a programmed station opens the station detail; any other
    /// place just recenters the map on it.
    private func selectSearchResult(_ place: TransitPlace) {
        isSearchFocused = false
        viewModel?.clearSearch()
        // Track + cancel so rapidly tapping results can't stack matchingStation calls whose
        // out-of-order completion would open the wrong station detail.
        placeMatchTask?.cancel()
        stationOpenTask?.cancel()
        isLoadingStationDetail = false
        // Same entry-point invariant as handlePlaceTapped/openStation: every new interaction
        // resets the POI-tap state, so a cancelled match's buffered resolve can't linger.
        pendingResolvedItem = nil
        tappedPlace = nil
        placeMatchTask = Task {
            if let station = await viewModel?.matchingStation(for: place, city: appState.selectedCity) {
                guard !Task.isCancelled else { return }
                openStation(station)
            } else {
                guard !Task.isCancelled else { return }
                viewModel?.updateCamera(to: place.coordinate, spanDelta: 0.02)
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


struct CityPickerView: View {
    @Binding var selectedCity: City?
    @Environment(\.dismiss) private var dismiss
    @Environment(DIContainer.self) private var container
    @State private var searchText = ""

    private var cities: [City] {
        container.cityService.getAllCities()
    }

    private var filteredCities: [City] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

                        CityCapabilityTags(coverage: city.dataCapabilities.coverage)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(AppLocalization.localized("Select City"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: AppLocalization.localized("Search cities"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { dismiss() }
                }
            }
        }
    }
}
