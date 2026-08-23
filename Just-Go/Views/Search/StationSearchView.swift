import SwiftUI
import MapKit

/// The map's search page: one field over both the local station index and Apple's places.
///
/// Stations come first and instantly, because they are in memory and are what this app is for;
/// places arrive behind them from a debounced network search. Choosing either hands back to the
/// map, which is what owns navigation. A station pushes its detail, a place opens its card with
/// the same "Route here" button a tapped pin gets. That sameness is the point: the rider should
/// not be able to tell how they found the place.
struct SearchPageView: View {
    let onSelectStation: (Station) -> Void
    let onSelectPlace: (TransitPlace) -> Void
    /// True when this page exists to return one answer (endpoint editing) rather than to be
    /// browsed. Station rows then close the page like place rows already do.
    var dismissesOnSelection = false

    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: StationSearchViewModel?
    // Tracked so a newer recent tap (or a direct station selection) supersedes an older
    // replay still loading its city: the loser must not overwrite the winner's push.
    @State private var recentReplayTask: Task<Void, Never>?
    @State private var placeResults: [TransitPlace] = []
    @State private var placeSearchTask: Task<Void, Never>?
    @State private var isSearchingPlaces = false
    @State private var currentPlaceTask: Task<Void, Never>?
    @State private var isResolvingCurrentPlace = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
            VStack(spacing: 0) {
                searchBar
                // Rendered whether or not any tags are saved: the current-location chip alone
                // earns the row, and without it there is no way in the whole app to say "here".
                if isIdle {
                    quickTagBar
                }
                resultsList
            }
            .navigationTitle(AppLocalization.localized("Search"))
            // The back button lives in the search bar itself, beside the field, so the field sits
            // where the thumb already is instead of under a title bar that only repeats what the
            // field's own placeholder says.
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.appBackground)
        .onDisappear {
            recentReplayTask?.cancel()
            placeSearchTask?.cancel()
            currentPlaceTask?.cancel()
        }
        .task {
            if viewModel == nil {
                viewModel = container.makeStationSearchViewModel()
            }
            // The rider tapped a search field to get here, so start with it focused rather than
            // making them tap a second time on a screen that exists only to be typed into.
            isSearchFocused = true
            await viewModel?.loadInitialStations()
        }
        // The map's GCJ-02 correction can land while this page is open, moving the rider ~540 m.
        // Re-order against it rather than leaving a list sorted from where they were not.
        .onChange(of: container.locationService.mapSpaceLocation?.coordinate.latitude) { _, _ in
            viewModel?.riderPositionChanged()
        }
    }

    /// Debounced hard, because this is a network search that runs on every keystroke and Apple
    /// rate-limits it. Stations are already on screen by the time this returns.
    private func schedulePlaceSearch(_ query: String) {
        placeSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            placeResults = []
            isSearchingPlaces = false
            return
        }
        isSearchingPlaces = true
        placeSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            // Biased to the rider, not to a city centroid. The same position the station list
            // is ranked by, so both halves of this page answer "near me" the same way.
            let region = container.locationService.mapSpaceLocation.map {
                MKCoordinateRegion(
                    center: $0.coordinate,
                    span: MKCoordinateSpan(
                        latitudeDelta: MapCameraSpan.city,
                        longitudeDelta: MapCameraSpan.city
                    )
                )
            }
            let found = try? await container.placeSearchProvider.searchPlaces(
                keyword: trimmed,
                region: region,
                limit: 12
            )
            guard !Task.isCancelled else { return }
            isSearchingPlaces = false
            placeResults = found ?? []
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                isSearchFocused = false
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .tappable()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.text(english: "Back", simplified: "返回", traditional: "返回"))

            searchField
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Every place the rider has already told the app matters, one tap from the top of the page.
    /// Starting with the one it can work out for itself.
    private var quickTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                currentLocationChip

                ForEach(quickTags) { quickTag in
                    Button {
                        isSearchFocused = false
                        // Its coordinate is the whole answer: a Beijing "Home" plans against
                        // Beijing's network because that is where it is, not because the app
                        // was set to Beijing at the time.
                        onSelectPlace(quickTag.transitPlace)
                        dismiss()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: quickTag.kind.icon)
                                .font(.caption)
                            Text(quickTag.kind.title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.appSurface, in: Capsule())
                        .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// "Here", as somewhere a trip can start from.
    ///
    /// This is the only control in the app that offers the device's own position. The route entry
    /// page that used to have the button was removed, which left the automatic fill in `beginPlan`
    /// as the sole caller, so whenever that fill did not land (GPS timeout, permission, or a start
    /// dropped as belonging to another city) the rider had a start field they could open but not
    /// answer.
    private var currentLocationChip: some View {
        Button {
            isSearchFocused = false
            resolveCurrentPlace()
        } label: {
            HStack(spacing: 5) {
                if isResolvingCurrentPlace {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "location.fill")
                        .font(.caption)
                }
                Text(AppLocalization.text(
                    english: "My Location",
                    simplified: "我的位置",
                    traditional: "我的位置"
                ))
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
            .foregroundStyle(isLocationAvailable ? Color.accentColor : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isLocationAvailable || isResolvingCurrentPlace)
        // Says which of the two it is rather than being inertly greyed out. "Off" and "not
        // allowed" are different problems with different fixes.
        .accessibilityHint(isLocationAvailable ? "" : currentLocationUnavailableReason)
    }

    private var isLocationAvailable: Bool {
        container.locationService.isAuthorized
    }

    private var currentLocationUnavailableReason: String {
        AppLocalization.text(
            english: "Location access is off for Just-Go",
            simplified: "Just-Go 没有定位权限",
            traditional: "Just-Go 沒有定位權限"
        )
    }

    private func resolveCurrentPlace() {
        currentPlaceTask?.cancel()
        isResolvingCurrentPlace = true
        currentPlaceTask = Task {
            defer { isResolvingCurrentPlace = false }
            let resolver = CurrentPlaceResolver(
                locationService: container.locationService,
                placeSearchProvider: container.placeSearchProvider
            )
            guard let place = try? await resolver.place(), !Task.isCancelled else { return }
            // Same hand-back as a quick tag or a place row: the map owns what happens next, so
            // this fills an endpoint when the page was opened to edit one and opens a place card
            // when it was opened to browse. One control, both modes.
            onSelectPlace(place)
            dismiss()
        }
    }

    private var quickTags: [StationQuickTag] {
        tripMemoryService.stationQuickTags
    }

    /// Nothing typed: the state where the page offers what the rider has already told it
    /// matters, rather than a list of whatever happens to be nearby.
    private var isIdle: Bool {
        viewModel?.searchText.isEmpty ?? true
    }

    /// Whether the page as a whole has an answer, from either half.
    ///
    /// The two halves answer at different speeds: stations are in memory and land on the
    /// keystroke, places come back from Apple ~350 ms later. So a place search still in flight
    /// counts as "possibly something": resolving it to "nothing" would flash the empty state
    /// on every keystroke in the gap before Apple replies.
    private var hasAnyResult: Bool {
        !(viewModel?.searchResults.isEmpty ?? true) || !placeResults.isEmpty || isSearchingPlaces
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(AppLocalization.text(
                english: "Search places or stations",
                simplified: "搜索地点或车站",
                traditional: "搜尋地點或車站"
            ), text: Binding(
                get: { viewModel?.searchText ?? "" },
                set: { newValue in
                    viewModel?.searchText = newValue
                    viewModel?.scheduleSearch()
                    schedulePlaceSearch(newValue)
                }
            ))
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .onSubmit {
                // Route through the single debounced searchTask slot rather than spawning an
                // untracked Task that races the in-flight debounced search on stationLoadID.
                viewModel?.scheduleSearch()
            }

            if !(viewModel?.searchText.isEmpty ?? true) {
                Button {
                    viewModel?.clearSearch()
                    placeSearchTask?.cancel()
                    placeResults = []
                    isSearchingPlaces = false
                    Task {
                        await viewModel?.loadInitialStations()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    /// Apple's places, under the stations. Choosing one hands straight back to the map rather than
    /// pushing anything here: the place's card belongs over the map it sits on.
    private var placesSection: some View {
        Section {
            ForEach(placeResults) { place in
                Button {
                    isSearchFocused = false
                    onSelectPlace(place)
                    dismiss()
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
                                    .rowMeta()
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack(spacing: 6) {
                Text(AppLocalization.text(english: "Places", simplified: "地点", traditional: "地點"))
                if isSearchingPlaces {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    private var resultsList: some View {
        List {
            // Above the stations rather than instead of them: what the rider looked up before is
            // the shortest route to what they are looking up now, and the nearby-station list is
            // still worth having under it. These used to be alternatives, so the recents were
            // only ever visible on a screen with nothing else on it.
            if isIdle, viewModel?.recentSearches.isEmpty == false {
                recentSearchesSection
                    .listRowBackground(Color.clear)
            }

            Group {
            if viewModel?.isSearching ?? false {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            } else if let results = viewModel?.searchResults, !results.isEmpty {
                Section {
                    ForEach(results) { station in
                            StationRow(
                                station: station,
                                distanceText: viewModel?.distanceText(for: station)
                            ) {
                                recentReplayTask?.cancel()
                                viewModel?.selectStation(station)
                                isSearchFocused = false
                                onSelectStation(station)
                                if dismissesOnSelection { dismiss() }
                            }
                    }
                } header: {
                    Text(AppLocalization.text(english: "Stations", simplified: "车站", traditional: "車站"))
                }
            } else if !(viewModel?.searchText.isEmpty ?? true) {
                if let message = viewModel?.errorMessage {
                    ContentUnavailableView {
                        Label(
                            AppLocalization.text(english: "Search Unavailable", simplified: "无法搜索", traditional: "無法搜尋"),
                            systemImage: "wifi.exclamationmark"
                        )
                    } description: {
                        Text(message)
                    }
                } else if !hasAnyResult {
                    // "No results" means the whole page found nothing. Not just the station half.
                    // It used to render whenever the station index missed, so a search like
                    // "北京 xinchi" showed a full-width empty state sitting directly on top of four
                    // perfectly good places from Apple. Saying "nothing here" above a list of
                    // somethings is the loudest possible way to be wrong.
                    ContentUnavailableView {
                        Label(AppLocalization.localized("No Results"), systemImage: "magnifyingglass")
                    } description: {
                        Text(AppLocalization.localized("Try a different search term"))
                    }
                }
            } else if let message = viewModel?.errorMessage {
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(
                            english: "Nothing nearby yet",
                            simplified: "暂无附近车站",
                            traditional: "暫無附近車站"
                        ),
                        systemImage: "location.slash"
                    )
                } description: {
                    Text(message)
                }
            }
            }
            .listRowBackground(Color.clear)

            // Outside the if/else above on purpose: places are an additional answer to the same
            // query, not an alternative to the station answer. When the station index has nothing
            // ("No Results") but Apple does, the rider still gets somewhere to go.
            if !placeResults.isEmpty {
                placesSection
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var recentSearchesSection: some View {
        Section(AppLocalization.localized("Recent Searches")) {
            ForEach(viewModel?.recentSearches ?? []) { search in
                Button {
                    isSearchFocused = false
                    recentReplayTask?.cancel()
                    recentReplayTask = Task {
                        // A recent replays in ITS city: same-named stations exist across
                        // cities, so re-resolving by name can open the wrong station
                        // entirely. The stored cityID is what makes that exact; nothing
                        // about the app's state has to change to honour it any more.
                        // Cancellation checks after each await keep a superseded replay
                        // from overwriting the newer tap's push.
                        let station = await viewModel?.station(withID: search.stationID, in: search.cityID)
                        guard !Task.isCancelled else { return }
                        if let station {
                            viewModel?.selectStation(station)
                            onSelectStation(station)
                            if dismissesOnSelection { dismiss() }
                        } else {
                            // Station no longer in the pack: fall back to a name search.
                            // scheduleSearch (not search) so it goes through the single
                            // debounced slot the field itself uses.
                            viewModel?.searchText = search.stationName
                            viewModel?.scheduleSearch()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text(search.stationName)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                viewModel?.deleteRecentSearches(at: offsets)
            }
        }
    }
}
