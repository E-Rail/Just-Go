import Foundation
import CoreLocation
import SwiftUI

struct MapVisibleRegion {
    let center: CLLocationCoordinate2D
    let latitudeDelta: CLLocationDegrees
    let longitudeDelta: CLLocationDegrees
}

@Observable
final class MapViewModel {
    var stations: [Station] = []
    var subwayLines: [SubwayLineMapOverlay] = []
    var selectedStation: Station?
    var nearbyStations: [Station] = []
    var isShowingAllNearbyStations = false
    var searchText = ""
    var searchResults: [Station] = []
    var isLoading = false
    var errorMessage: String?
    var visibleRegion: MapVisibleRegion?
    var isLocationAuthorized: Bool {
        locationService.isAuthorized
    }

    private let locationService: LocationService
    private let stationSearchService: StationSearchService
    private let aMapService: AMapService

    init(
        locationService: LocationService,
        stationSearchService: StationSearchService,
        aMapService: AMapService
    ) {
        self.locationService = locationService
        self.stationSearchService = stationSearchService
        self.aMapService = aMapService
    }

    var userLocation: CLLocationCoordinate2D? {
        locationService.currentLocation?.coordinate
    }

    func loadStations(for city: City) async {
        isLoading = true
        defer { isLoading = false }

        do {
            stations = try await stationSearchService.search(keyword: "", city: city.id)
            subwayLines = try await aMapService.getSubwayLines(city: city.id)
            updateCamera(to: city.coordinate, spanDelta: 0.22)
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

    func requestLocationAccess() async {
        await locationService.requestPermission()
        await loadNearbyStations()
    }

    func toggleNearbyList() {
        isShowingAllNearbyStations.toggle()
    }

    func searchStations(in city: City?) async {
        guard let city else { return }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }

        do {
            searchResults = try await stationSearchService.suggestions(keyword: searchText, city: city.id, limit: 8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
    }

    @discardableResult
    func selectStation(_ station: Station) async -> Station {
        selectedStation = station
        withAnimation {
            visibleRegion = MapVisibleRegion(
                center: station.coordinate,
                latitudeDelta: 0.01,
                longitudeDelta: 0.01
            )
        }

        do {
            let detailedStation = try await stationSearchService.stationDetails(
                stationID: station.stationID,
                city: station.cityID
            )
            selectedStation = detailedStation
            return detailedStation
        } catch {
            errorMessage = error.localizedDescription
            return station
        }
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D) {
        updateCamera(to: coordinate, spanDelta: 0.1)
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D, spanDelta: CLLocationDegrees) {
        withAnimation {
            visibleRegion = MapVisibleRegion(
                center: coordinate,
                latitudeDelta: spanDelta,
                longitudeDelta: spanDelta
            )
        }
    }

    func centerOnUser() {
        guard let location = userLocation else { return }
        updateCamera(to: location)
    }
}
