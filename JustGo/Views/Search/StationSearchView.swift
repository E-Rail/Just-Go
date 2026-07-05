import SwiftUI
import UIKit

/// Reports the search bar's rendered bottom edge in `.global` space so the dropdown's
/// height cap tracks the bar's real height (Dynamic Type) and the keyboard, instead of
/// a hardcoded offset — same pattern as the map's SearchBarBottomYKey.
private struct StationSearchBarBottomYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct StationSearchView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var viewModel: StationSearchViewModel?
    @State private var selectedStation: Station?
    @State private var showFacilityPicker = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var searchBarBottomY: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    // The dropdown hangs directly off the bar (its top aligned to the
                    // bar's bottom), so it tracks the bar's actual position instead of a
                    // fixed 58pt offset that Dynamic Type growth silently breaks.
                    .overlay(alignment: .bottom) {
                        if isSearchFocused && viewModel?.searchResults.isEmpty == false {
                            searchDropdown
                                .padding(.horizontal)
                                .alignmentGuide(.bottom) { $0[.top] - 8 }
                        }
                    }
                    .zIndex(40)
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
            .navigationBarTitleDisplayMode(.large)
            .background(Color.appBackground)
            .navigationDestination(item: $selectedStation) { station in
                StationDetailView(station: station)
            }
        }
        .task(id: appState.selectedCity?.id) {
            if viewModel == nil {
                viewModel = container.makeStationSearchViewModel()
            }
            await viewModel?.loadInitialStations(city: appState.selectedCity?.id ?? "")
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(AppLocalization.localized("Search stations..."), text: Binding(
                get: { viewModel?.searchText ?? "" },
                set: { newValue in
                    viewModel?.searchText = newValue
                    viewModel?.scheduleSearch(city: appState.selectedCity?.id ?? "")
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: StationSearchBarBottomYKey.self, value: proxy.frame(in: .global).maxY)
            }
        }
    }

    // Both measured in `.global` (matching UIScreen bounds), so no coordinate conversion;
    // the floor keeps at least one row reachable in pathological layouts.
    private var searchDropdownMaxHeight: CGFloat {
        let keyboardTopY = UIScreen.main.bounds.height - keyboardHeight
        return max(44, keyboardTopY - searchBarBottomY - 16)
    }

    private var searchDropdown: some View {
        ScrollView {
            searchDropdownRows
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: searchDropdownMaxHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }

    // All matches, scrollable — not a silent prefix(8) truncation.
    private var searchDropdownRows: some View {
        let results = viewModel?.searchResults ?? []
        return VStack(spacing: 0) {
            ForEach(results) { station in
                Button {
                    isSearchFocused = false
                    viewModel?.selectStation(station)
                    selectedStation = station
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.localizedName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            if let alternateName = station.alternateLocalizedName {
                                Text(alternateName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let distance = viewModel?.distanceText(for: station) {
                            Text(distance)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if station.id != results.last?.id {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
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
            if viewModel?.isSearching ?? false {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            } else if let results = viewModel?.searchResults, !results.isEmpty {
                ForEach(results) { station in
                    StationRow(
                        station: station,
                        distanceText: viewModel?.distanceText(for: station)
                    ) {
                        viewModel?.selectStation(station)
                        selectedStation = station
                    }
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
            } else if viewModel?.filter.facilityType != nil && viewModel?.isEnrichingForFacility == false {
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(english: "No Stations Found", simplified: "未找到站点", traditional: "未找到站點"),
                        systemImage: "building.2"
                    )
                } description: {
                    Text(AppLocalization.text(
                        english: "Facility data requires the city data pack to be loaded.",
                        simplified: "设施数据需要城市数据包。",
                        traditional: "設施資料需要城市資料包。"
                    ))
                }
            } else if let message = viewModel?.errorMessage {
                ContentUnavailableView {
                    Label(AppLocalization.localized("Choose City"), systemImage: "building.2")
                } description: {
                    Text(message)
                }
            } else if viewModel?.recentSearches.isEmpty == false {
                recentSearchesSection
            }
        }
        .listStyle(.plain)
    }

    private var recentSearchesSection: some View {
        Section(AppLocalization.localized("Recent Searches")) {
            ForEach(viewModel?.recentSearches ?? []) { search in
                Button {
                    isSearchFocused = false
                    Task {
                        // A recent replays in ITS city — same-named stations exist across
                        // cities, so name-searching the currently selected one can open
                        // the wrong station entirely.
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
                        }
                        if let station = await viewModel?.station(withID: search.stationID, in: cityID) {
                            viewModel?.selectStation(station)
                            selectedStation = station
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
