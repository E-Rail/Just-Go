import SwiftUI

struct StationSearchView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var viewModel: StationSearchViewModel?
    @State private var selectedStation: Station?
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
            .sheet(item: $selectedStation) { station in
                NavigationStack {
                    StationDetailView(station: station)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = StationSearchViewModel(
                    stationSearchService: container.stationSearchService,
                    locationService: container.locationService
                )
            }
            await viewModel?.loadInitialStations(city: appState.selectedCity?.id ?? "")
        }
        .onChange(of: appState.selectedCity?.id) { _, cityID in
            Task {
                await viewModel?.loadInitialStations(city: cityID ?? "")
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search stations...", text: Binding(
                get: { viewModel?.searchText ?? "" },
                set: { newValue in
                    viewModel?.searchText = newValue
                    viewModel?.scheduleSearch(city: appState.selectedCity?.id ?? "")
                }
            ))
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .onSubmit {
                Task {
                    await viewModel?.search(city: appState.selectedCity?.id ?? "")
                }
            }

            if !(viewModel?.searchText.isEmpty ?? true) {
                Button(action: { viewModel?.clearSearch() }) {
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
        VStack(spacing: 0) {
            ForEach(viewModel?.searchResults.prefix(8) ?? []) { station in
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

                if station.id != viewModel?.searchResults.prefix(8).last?.id {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "Accessible",
                    icon: "figure.roll",
                    isSelected: viewModel?.filter.accessibleOnly ?? false
                ) {
                    viewModel?.toggleAccessibleFilter()
                }

                FilterChip(
                    title: "Elevator",
                    icon: "arrow.up.arrow.down.circle",
                    isSelected: viewModel?.filter.elevatorOnly ?? false
                ) {
                    viewModel?.toggleElevatorFilter()
                }

                FilterChip(
                    title: "Transfer",
                    icon: "arrow.triangle.2.circlepath",
                    isSelected: viewModel?.filter.transferOnly ?? false
                ) {
                    viewModel?.toggleTransferFilter()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
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
                ContentUnavailableView {
                    Label(AppLocalization.localized("No Results"), systemImage: "magnifyingglass")
                } description: {
                    Text(AppLocalization.localized("Try a different search term"))
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
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(search.stationName)
                    Spacer()
                }
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
                Text(AppLocalization.localized(title))
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
