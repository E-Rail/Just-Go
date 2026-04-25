import Foundation
import CoreLocation
import SwiftUI
import MapKit

@Observable
final class MapViewModel {
    var stations: [Station] = []
    var selectedStation: Station?
    var nearbyStations: [Station] = []
    var isLoading = false
    var errorMessage: String?
    var cameraPosition: MapCameraPosition = .automatic
    var showsUserLocation = true

    private let locationService: LocationService
    private let stationSearchService: StationSearchService
    private let cityService: CityService

    init(
        locationService: LocationService,
        stationSearchService: StationSearchService,
        cityService: CityService
    ) {
        self.locationService = locationService
        self.stationSearchService = stationSearchService
        self.cityService = cityService
    }

    var userLocation: CLLocationCoordinate2D? {
        locationService.currentLocation?.coordinate
    }

    func loadStations(for city: City) async {
        isLoading = true
        defer { isLoading = false }

        do {
            stations = try await stationSearchService.search(keyword: "", city: city.id)
            updateCamera(to: city.coordinate)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadNearbyStations() async {
        guard let location = userLocation else { return }

        do {
            nearbyStations = try await stationSearchService.searchNearby(location: location)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectStation(_ station: Station) {
        selectedStation = station
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: station.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D) {
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            ))
        }
    }

    func centerOnUser() {
        guard let location = userLocation else { return }
        updateCamera(to: location)
    }

    func filterStations(_ filter: StationFilter) {
        guard !stations.isEmpty else { return }
        let filtered = stationSearchService.filterStations(stations, by: filter)
        stations = filtered
    }
}
