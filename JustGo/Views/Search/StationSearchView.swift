import SwiftUI

struct StationSearchView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var viewModel: StationSearchViewModel?
    @State private var selectedStation: Station?
    @State private var showFacilityPicker = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    searchBar
                    filterBar
                    resultsList
                }

                if isSearchFocused && viewModel?.searchResults.isEmpty == false {
                    searchDropdown
                        .padding(.horizontal)
                        .padding(.top, 58)
                        .zIndex(40)
                }
            }
            .navigationTitle(AppLocalization.localized("Search"))
            .navigationBarTitleDisplayMode(.large)
            .background(Color.appBackground)
            .sheet(item: $selectedStation) { station in
                NavigationStack {
                    StationDetailView(station: station)
                }
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
    }

    private var searchDropdown: some View {
        let topResults = Array(viewModel?.searchResults.prefix(8) ?? [])
        return VStack(spacing: 0) {
            ForEach(topResults) { station in
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

                if station.id != topResults.last?.id {
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
                    viewModel?.searchText = search.stationName
                    Task { await viewModel?.search(city: appState.selectedCity?.id ?? "") }
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
