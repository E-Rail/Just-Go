import SwiftUI

struct StationSearchView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var viewModel: StationSearchViewModel?
    @State private var selectedStation: Station?
    @State private var showStationDetail = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                filterBar
                resultsList
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showStationDetail) {
                if let station = selectedStation {
                    StationDetailView(station: station)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = StationSearchViewModel(
                    stationSearchService: container.stationSearchService,
                    accessibilityService: container.accessibilityService
                )
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search stations...", text: Binding(
                get: { viewModel?.searchText ?? "" },
                set: { viewModel?.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .onSubmit {
                Task {
                    await viewModel?.search(city: appState.selectedCity?.name ?? "")
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
                    icon: "arrow.triangle.branch",
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
                    StationRow(station: station) {
                        selectedStation = station
                        showStationDetail = true
                    }
                }
            } else if !(viewModel?.searchText.isEmpty ?? true) {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a different search term")
                }
            } else {
                recentSearchesSection
            }
        }
        .listStyle(.plain)
    }

    private var recentSearchesSection: some View {
        Section("Recent Searches") {
            ForEach(viewModel?.recentSearches ?? []) { search in
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(search.stationName)
                    Spacer()
                    Text(search.cityID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
