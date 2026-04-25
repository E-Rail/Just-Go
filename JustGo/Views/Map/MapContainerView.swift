import SwiftUI
import MapKit

struct MapContainerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var viewModel: MapViewModel?
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    @State private var selectedStation: Station?
    @State private var showStationDetail = false
    @State private var showCityPicker = false

    var body: some View {
        ZStack {
            mapView
                .ignoresSafeArea()

            VStack {
                searchBar
                    .padding(.horizontal)
                    .padding(.top, 8)

                Spacer()

                if let viewModel = viewModel {
                    nearbyStationsCard(viewModel: viewModel)
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                }
            }
        }
        .sheet(isPresented: $showStationDetail) {
            if let station = selectedStation {
                StationDetailView(station: station)
            }
        }
        .sheet(isPresented: $showCityPicker) {
            CityPickerView(selectedCity: $appState.selectedCity)
        }
        .task {
            if viewModel == nil {
                viewModel = MapViewModel(
                    locationService: container.locationService,
                    stationSearchService: container.stationSearchService,
                    cityService: container.cityService
                )
            }
            if let city = appState.selectedCity {
                await viewModel?.loadStations(for: city)
            }
        }
    }

    private var mapView: some View {
        Map(position: $mapCameraPosition) {
            UserAnnotation()

            if let viewModel = viewModel {
                ForEach(viewModel.stations) { station in
                    Annotation(station.name, coordinate: station.coordinate) {
                        StationAnnotationView(station: station)
                            .onTapGesture {
                                selectedStation = station
                                showStationDetail = true
                            }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
    }

    private var searchBar: some View {
        HStack {
            GlassCard {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    Text("Search stations...")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: { showCityPicker = true }) {
                        HStack(spacing: 4) {
                            Text(appState.selectedCity?.nameEn ?? "City")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            .onTapGesture {
                // Navigate to search
            }
        }
    }

    private func nearbyStationsCard(viewModel: MapViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Nearby Stations")
                    .font(.headline)
                Spacer()
                Button("See All") {
                    // Navigate to nearby list
                }
                .font(.subheadline)
            }

            if viewModel.nearbyStations.isEmpty {
                HStack {
                    Image(systemName: "location.slash")
                        .foregroundStyle(.secondary)
                    Text("Enable location to see nearby stations")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(viewModel.nearbyStations.prefix(3)) { station in
                    StationRow(station: station) {
                        selectedStation = station
                        showStationDetail = true
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CityPickerView: View {
    @Binding var selectedCity: City?
    @Environment(\.dismiss) private var dismiss
    @Environment(DIContainer.self) private var container

    private var cities: [City] {
        container.cityService.getAllCities()
    }

    var body: some View {
        NavigationStack {
            List(cities) { city in
                Button(action: {
                    selectedCity = city
                    dismiss()
                }) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(city.name)
                                .font(.headline)
                            Text(city.nameEn)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if selectedCity?.id == city.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }

                        Text("\(city.stationCount) stations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Select City")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
