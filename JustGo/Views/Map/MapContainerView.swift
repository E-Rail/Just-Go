import SwiftUI
import MapKit

private struct IdentifiableMapItem: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
}

struct MapContainerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var viewModel: MapViewModel?
    @State private var selectedStation: Station?
    @State private var selectedMapItem: IdentifiableMapItem?
    @State private var showCityPicker = false
    @State private var showNetworkLineStatus = false
    @State private var isLoadingStationDetail = false
    @State private var placeMatchTask: Task<Void, Never>?
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
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(item: $selectedStation, onDismiss: {
            selectedStation = nil
            isLoadingStationDetail = false
        }) { station in
            NavigationStack {
                StationDetailView(station: station)
            }
        }
        .sheet(item: $selectedMapItem) { item in
            MapItemDetailSheet(mapItem: item.mapItem) {
                selectedMapItem = nil
            }
            .ignoresSafeArea()
            .presentationDetents([.medium, .large])
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
            onPlaceSelected: handleTappedPlace
        )
    }

    private var topControls: some View {
        VStack(spacing: 8) {
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }

    private var mapLocateButton: some View {
        Button {
            Task {
                await viewModel?.centerOnUser()
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
        Task {
            guard !isLoadingStationDetail else { return }

            isLoadingStationDetail = true
            defer { isLoadingStationDetail = false }

            selectedStation = await viewModel?.selectStation(station) ?? station
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

    /// A tapped Apple POI that *is* a programmed station opens the station detail;
    /// otherwise it shows Apple's native place card.
    private func handleTappedPlace(_ mapItem: MKMapItem) {
        let place = TransitPlace(mapItem: mapItem)
        placeMatchTask?.cancel()
        placeMatchTask = Task {
            if let station = await viewModel?.matchingStation(for: place, city: appState.selectedCity) {
                guard !Task.isCancelled else { return }
                openStation(station)
            } else {
                guard !Task.isCancelled else { return }
                selectedMapItem = IdentifiableMapItem(mapItem: mapItem)
            }
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
                                    .foregroundStyle(Color.accentColor)
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
