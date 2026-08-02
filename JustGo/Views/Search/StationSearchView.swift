import SwiftUI
import UIKit
import MapKit

/// Reports the search bar's rendered bottom edge in `.global` space so the dropdown's
/// height cap tracks the bar's real height (Dynamic Type) and the keyboard, instead of
/// a hardcoded offset — same pattern as the map's SearchBarBottomYKey.
private struct StationSearchBarBottomYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The map's search page: one field over both the local station index and Apple's places.
///
/// Stations come first and instantly, because they are in memory and are what this app is for;
/// places arrive behind them from a debounced network search. Choosing either hands back to the
/// map, which is what owns navigation — a station pushes its detail, a place opens its card with
/// the same "Route here" button a tapped pin gets. That sameness is the point: the rider should
/// not be able to tell how they found the place.
struct SearchPageView: View {
    let onSelectStation: (Station) -> Void
    let onSelectPlace: (TransitPlace) -> Void
    /// True when this page exists to return one answer (endpoint editing) rather than to be
    /// browsed. Station rows then close the page like place rows already do.
    var dismissesOnSelection = false

    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: StationSearchViewModel?
    @State private var keyboardHeight: CGFloat = 0
    @State private var searchBarBottomY: CGFloat = 0
    // Tracked so a newer recent tap (or a direct station selection) supersedes an older
    // replay still loading its city — the loser must not overwrite the winner's push.
    @State private var recentReplayTask: Task<Void, Never>?
    @State private var placeResults: [TransitPlace] = []
    @State private var placeSearchTask: Task<Void, Never>?
    @State private var isSearchingPlaces = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
            VStack(spacing: 0) {
                searchBar
                if !quickTags.isEmpty && isIdle {
                    quickTagBar
                }
                resultsList
            }
            .onPreferenceChange(StationSearchBarBottomYKey.self) { searchBarBottomY = $0 }
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
            .navigationTitle(AppLocalization.localized("Search"))
            // The back button lives in the search bar itself, beside the field, so the field sits
            // where the thumb already is instead of under a title bar that only repeats what the
            // field's own placeholder says.
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.appBackground)
        .onDisappear {
            recentReplayTask?.cancel()
            placeSearchTask?.cancel()
        }
        .task(id: appState.selectedCity?.id) {
            if viewModel == nil {
                viewModel = container.makeStationSearchViewModel()
            }
            // The rider tapped a search field to get here, so start with it focused rather than
            // making them tap a second time on a screen that exists only to be typed into.
            isSearchFocused = true
            await viewModel?.loadInitialStations(city: appState.selectedCity?.id ?? "")
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
            let region = appState.selectedCity.map {
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
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.text(english: "Back", simplified: "返回", traditional: "返回"))

            searchField
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: StationSearchBarBottomYKey.self, value: proxy.frame(in: .global).maxY)
            }
        }
    }

    /// Every place the rider has already told the app matters, one tap from the top of the page.
    private var quickTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickTags) { quickTag in
                    Button {
                        isSearchFocused = false
                        let place = quickTag.transitPlace
                        // A quick tag knows its own city, and it is frequently not the selected
                        // one — that cityID is exactly what stops a Beijing "Home" being planned
                        // against Shanghai's network.
                        onSelectPlace(place)
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

    private var quickTags: [StationQuickTag] {
        tripMemoryService.stationQuickTags
    }

    /// Nothing typed — the state where the page offers what the rider has already told it
    /// matters, rather than a list of whatever happens to be nearby.
    private var isIdle: Bool {
        viewModel?.searchText.isEmpty ?? true
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
                    viewModel?.scheduleSearch(city: appState.selectedCity?.id ?? "")
                    schedulePlaceSearch(newValue)
                }
            ))
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .onSubmit {
                // Route through the single debounced searchTask slot rather than spawning an
                // untracked Task that races the in-flight debounced search on stationLoadID.
                viewModel?.scheduleSearch(city: appState.selectedCity?.id ?? "")
            }

            if !(viewModel?.searchText.isEmpty ?? true) {
                Button {
                    viewModel?.clearSearch()
                    placeSearchTask?.cancel()
                    placeResults = []
                    isSearchingPlaces = false
                    Task {
                        await viewModel?.loadInitialStations(city: appState.selectedCity?.id ?? "")
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                } else {
                    ContentUnavailableView {
                        Label(AppLocalization.localized("No Results"), systemImage: "magnifyingglass")
                    } description: {
                        Text(AppLocalization.localized("Try a different search term"))
                    }
                }
            } else if let message = viewModel?.errorMessage {
                ContentUnavailableView {
                    Label(AppLocalization.localized("Choose City"), systemImage: "building.2")
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

    private var filterLoadingRow: some View {
        HStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(AppLocalization.localized("Checking station details..."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 28)
    }

    private var activeFilterEmptyState: some View {
        ContentUnavailableView {
            Label(
                AppLocalization.localized("No stations match these filters"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            Text(AppLocalization.localized("Try clearing filters or loading official city data."))
        }
    }

    private var recentSearchesSection: some View {
        Section(AppLocalization.localized("Recent Searches")) {
            ForEach(viewModel?.recentSearches ?? []) { search in
                Button {
                    isSearchFocused = false
                    recentReplayTask?.cancel()
                    recentReplayTask = Task {
                        // A recent replays in ITS city — same-named stations exist across
                        // cities, so name-searching the currently selected one can open
                        // the wrong station entirely. Cancellation checks after each await
                        // keep a superseded replay from overwriting the newer tap's push.
                        // (No cancel-on-city-change anywhere: this task switches the city
                        // itself and must survive its own switch.)
                        var cityID = search.cityID
                        if cityID.isEmpty { cityID = appState.selectedCity?.id ?? "" }
                        if cityID != appState.selectedCity?.id,
                           let city = container.cityService.getCity(byID: cityID) {
                            appState.selectedCity = city
                            // Load the city ourselves so currentCityID is already correct
                            // when the deferred .task(id:) reload fires — otherwise that
                            // reload's real-city-change reset would wipe the fallback
                            // query set below.
                            await viewModel?.loadInitialStations(city: cityID)
                            guard !Task.isCancelled else { return }
                        }
                        let station = await viewModel?.station(withID: search.stationID, in: cityID)
                        guard !Task.isCancelled else { return }
                        if let station {
                            viewModel?.selectStation(station)
                            onSelectStation(station)
                            if dismissesOnSelection { dismiss() }
                        } else {
                            // Station no longer in the pack — fall back to a name search
                            // in its home city. scheduleSearch (not search) so the
                            // debounce orders it after the .task(id:) reload's token mint.
                            viewModel?.searchText = search.stationName
                            viewModel?.scheduleSearch(city: cityID)
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
