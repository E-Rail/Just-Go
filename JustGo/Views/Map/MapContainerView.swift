import SwiftUI

struct MapContainerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var viewModel: MapViewModel?
    @State private var selectedStation: Station?
    @State private var showCityPicker = false
    @State private var isLoadingStationDetail = false
    @State private var isNearbyStationsExpanded = true
    @FocusState private var isSearchFocused: Bool

    var body: some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let viewModel = viewModel {
                nearbyStationsCard(viewModel: viewModel)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }
        }
        .sheet(item: $selectedStation, onDismiss: {
            selectedStation = nil
            isLoadingStationDetail = false
        }) { station in
            NavigationStack {
                StationDetailView(station: station)
            }
        }
        .sheet(isPresented: $showCityPicker) {
            CityPickerView(selectedCity: Binding(
                get: { appState.selectedCity },
                set: { appState.selectedCity = $0 }
            ))
        }
        .task(id: appState.selectedCity?.id) {
            if viewModel == nil {
                viewModel = container.makeMapViewModel()
            }

            guard let city = appState.selectedCity else { return }
            await viewModel?.loadStations(for: city)
            if viewModel?.isLocationAuthorized == true {
                await viewModel?.loadNearbyStations()
            }
        }
        .onChange(of: viewModel?.searchText ?? "") { _, _ in
            viewModel?.scheduleStationSearch(in: appState.selectedCity)
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
            onStationSelected: openStation
        )
    }

    private var topControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    TextField(AppLocalization.localized("Search stations..."), text: Binding(
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

    private var searchResultsDropdown: some View {
        VStack(spacing: 0) {
            ForEach(viewModel?.searchResults ?? []) { station in
                Button {
                    isSearchFocused = false
                    viewModel?.clearSearch()
                    openStation(station)
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
                        if let line = station.uniqueLogicalLines.first {
                            Text(line.localizedName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if station.id != viewModel?.searchResults.last?.id {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }

    private var mapLocateButton: some View {
        Button {
            Task {
                if await viewModel?.requestLocationAccess() == true {
                    viewModel?.centerOnUser()
                }
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.headline)
                .foregroundStyle(viewModel?.isLocationAuthorized == true ? .blue : .primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.localized("Nearest Station"))
    }

    private func nearbyStationsCard(viewModel: MapViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    isNearbyStationsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(AppLocalization.localized("Nearby Stations"))
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isNearbyStationsExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isNearbyStationsExpanded ? AppLocalization.localized("Expanded") : AppLocalization.localized("Collapsed"))

            if isNearbyStationsExpanded {
                if !viewModel.nearbyStations.isEmpty {
                    HStack {
                        Spacer()
                        Button(viewModel.isShowingAllNearbyStations ? AppLocalization.localized("Show Less") : AppLocalization.localized("See All")) {
                            withAnimation {
                                viewModel.toggleNearbyList()
                            }
                        }
                        .font(.subheadline)
                    }
                }

                if viewModel.nearbyStations.isEmpty && !viewModel.isLocationAuthorized {
                    Button {
                        Task {
                            await viewModel.requestLocationAccess()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "location.slash")
                                .foregroundStyle(.secondary)
                            Text(AppLocalization.localized("Enable location to see nearby stations"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 8)
                } else if viewModel.nearbyStations.isEmpty {
                    Text(viewModel.errorMessage ?? AppLocalization.localized("No nearby stations found"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.nearbyStations.prefix(viewModel.isShowingAllNearbyStations ? 10 : 3)) { station in
                        StationRow(station: station) {
                            openStation(station)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func openStation(_ station: Station) {
        Task {
            guard !isLoadingStationDetail else { return }

            isLoadingStationDetail = true
            defer { isLoadingStationDetail = false }

            selectedStation = await viewModel?.selectStation(station) ?? station
        }
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
                                    .foregroundStyle(.blue)
                            }

                            Text(AppLocalization.stationCount(city.stationCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        CityCapabilityTags(city: city)
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
