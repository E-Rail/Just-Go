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

    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: StationSearchViewModel?
    @State private var showFacilityPicker = false
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
                filterBar
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
            .navigationBarTitleDisplayMode(.inline)
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
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: StationSearchBarBottomYKey.self, value: proxy.frame(in: .global).maxY)
            }
        }
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

    private var isAnyFilterActive: Bool {
        viewModel?.filter.accessibleOnly == true ||
        viewModel?.filter.elevatorOnly == true ||
        viewModel?.filter.transferOnly == true ||
        viewModel?.filter.facilityType != nil
    }

    private var filterBar: some View {
        ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(
                            title: AppLocalization.localized("Accessible"),
                            icon: "figure.roll",
                            isSelected: viewModel?.filter.accessibleOnly ?? false
                        ) {
                            viewModel?.toggleAccessibleFilter()
                        }

                        FilterChip(
                            title: AppLocalization.localized("Elevator"),
                            icon: "arrow.up.arrow.down.circle",
                            isSelected: viewModel?.filter.elevatorOnly ?? false
                        ) {
                            viewModel?.toggleElevatorFilter()
                        }

                        FilterChip(
                            title: AppLocalization.localized("Transfer"),
                            icon: "arrow.triangle.2.circlepath",
                            isSelected: viewModel?.filter.transferOnly ?? false
                        ) {
                            viewModel?.toggleTransferFilter()
                        }

                        FilterChip(
                            title: viewModel?.filter.facilityType?.localizedName
                                ?? AppLocalization.text(english: "Facility", simplified: "设施", traditional: "設施"),
                            icon: viewModel?.filter.facilityType?.iconName ?? "building.2.crop.circle",
                            isSelected: viewModel?.filter.facilityType != nil
                        ) {
                            showFacilityPicker = true
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                if viewModel?.isEnrichingForFacility == true {
                    ProgressView()
                        .padding(.trailing, 12)
                } else if isAnyFilterActive {
                    Button(AppLocalization.localized("Clear")) {
                        viewModel?.clearFilters()
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 8)
                }
        }
        .confirmationDialog(
            AppLocalization.text(english: "Filter by Facility", simplified: "按设施筛选", traditional: "按設施篩選"),
            isPresented: $showFacilityPicker,
            titleVisibility: .visible
        ) {
            ForEach(StationFacilityType.allCases.filter { $0 != .general }, id: \.self) { type in
                Button(type.localizedName) {
                    viewModel?.setFacilityFilter(type)
                }
            }
            if viewModel?.filter.facilityType != nil {
                Button(AppLocalization.text(english: "Clear Filter", simplified: "清除筛选", traditional: "清除篩選"), role: .destructive) {
                    viewModel?.setFacilityFilter(nil)
                }
            }
        }
    }

    private var resultsList: some View {
        List {
            Group {
            if viewModel?.isSearching ?? false {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            } else if viewModel?.isEnrichingForFacility == true && (viewModel?.searchResults.isEmpty ?? true) {
                filterLoadingRow
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
                        }
                    }
                } header: {
                    Text(AppLocalization.text(english: "Stations", simplified: "车站", traditional: "車站"))
                }
            } else if isAnyFilterActive && viewModel?.errorMessage == nil {
                // A real search error (filtered keyword search failing offline) must win
                // over the filter empty-state — fall through to the branches below.
                activeFilterEmptyState
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
            } else if !isAnyFilterActive && viewModel?.recentSearches.isEmpty == false {
                recentSearchesSection
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

struct FilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
