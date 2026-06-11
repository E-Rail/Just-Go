import Foundation
import CoreLocation
import SwiftUI

struct MapVisibleRegion {
    let center: CLLocationCoordinate2D
    let latitudeDelta: CLLocationDegrees
    let longitudeDelta: CLLocationDegrees

    var maxDelta: CLLocationDegrees {
        max(latitudeDelta, longitudeDelta)
    }

    func contains(_ coordinate: CLLocationCoordinate2D, paddingFactor: Double = 0.35) -> Bool {
        let latitudePadding = latitudeDelta * paddingFactor
        let longitudePadding = longitudeDelta * paddingFactor
        let latitudeRange = (center.latitude - latitudeDelta / 2 - latitudePadding)...(center.latitude + latitudeDelta / 2 + latitudePadding)
        let longitudeRange = (center.longitude - longitudeDelta / 2 - longitudePadding)...(center.longitude + longitudeDelta / 2 + longitudePadding)
        return latitudeRange.contains(coordinate.latitude) && longitudeRange.contains(coordinate.longitude)
    }
}

@Observable
final class MapViewModel {
    var stations: [Station] = []
    var nearbyStations: [Station] = []
    var isShowingAllNearbyStations = false
    var searchText = ""
    var searchResults: [Station] = []
    var isLoading = false
    var errorMessage: String?
    var visibleRegion: MapVisibleRegion?
    var metroNetworks: [MetroNetwork] = []
    var isLocationAuthorized: Bool {
        locationService.isAuthorized
    }

    private let locationService: LocationService
    private let stationSearchService: StationSearchService
    private let cityService: CityService
    private let metroNetworkProvider: MetroNetworkProviding
    private var viewportLoadTask: Task<Void, Never>?
    private var cityLoadTask: Task<Void, Never>?

    init(
        locationService: LocationService,
        stationSearchService: StationSearchService,
        cityService: CityService,
        metroNetworkProvider: MetroNetworkProviding
    ) {
        self.locationService = locationService
        self.stationSearchService = stationSearchService
        self.cityService = cityService
        self.metroNetworkProvider = metroNetworkProvider
    }

    var userLocation: CLLocationCoordinate2D? {
        locationService.currentLocation?.coordinate
    }

    func loadStations(for city: City) async {
        viewportLoadTask?.cancel()
        cityLoadTask?.cancel()
        guard city.id != "automatic" else {
            stations = []
            metroNetworks = []
            return
        }
        updateCamera(to: city.coordinate, spanDelta: 0.22)
        metroNetworks = []
        stations = []
        cityLoadTask = Task { [weak self] in
            await self?.loadNetworks(cityIDs: [city.id])
        }
    }

    func loadNearbyStations() async {
        do {
            let location = try await locationService.requestCurrentLocation()
            nearbyStations = try await stationSearchService.searchNearby(location: location.coordinate, radius: 10_000)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestLocationAccess() async {
        do {
            _ = try await locationService.requestCurrentLocation()
            await loadNearbyStations()
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func viewportChanged(to region: MapVisibleRegion) {
        visibleRegion = region
        viewportLoadTask?.cancel()
        refreshVisibleStations()

        guard region.maxDelta <= 2 else {
            metroNetworks = []
            stations = []
            return
        }

        viewportLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            let centerCityIDs = cityService.getAllCities()
                .filter { $0.id != "automatic" && region.contains($0.coordinate, paddingFactor: 0.8) }
                .map(\.id)
            let intersectingLoadedCityIDs = metroNetworks
                .filter { $0.bounds.intersects(region) }
                .map(\.cityID)
            let visibleCityIDs = Array(Set(centerCityIDs + intersectingLoadedCityIDs))
            await loadNetworks(cityIDs: visibleCityIDs)
        }
    }

    @discardableResult
    func selectStation(_ station: Station) async -> Station {
        withAnimation {
            visibleRegion = MapVisibleRegion(
                center: station.coordinate,
                latitudeDelta: 0.01,
                longitudeDelta: 0.01
            )
        }

        do {
            let detailedStation = try await stationSearchService.stationDetails(
                stationID: station.name,
                city: station.cityID
            )
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

    private func loadNetworks(cityIDs: [String]) async {
        let requested = Set(cityIDs)
        let retained = metroNetworks.filter { requested.contains($0.cityID) }
        var loadedByCity = Dictionary(uniqueKeysWithValues: retained.map { ($0.cityID, $0) })

        await withTaskGroup(of: MetroNetwork?.self) { group in
            for cityID in requested where loadedByCity[cityID] == nil {
                group.addTask { [metroNetworkProvider] in
                    await metroNetworkProvider.network(for: cityID)
                }
            }
            for await network in group {
                if let network {
                    loadedByCity[network.cityID] = network
                }
            }
        }

        guard !Task.isCancelled else { return }
        metroNetworks = loadedByCity.values.sorted { $0.cityID < $1.cityID }
        refreshVisibleStations()
    }

    private func refreshVisibleStations() {
        guard let region = visibleRegion, region.maxDelta <= 0.8 else {
            stations = []
            return
        }

        let showsNormalStations = region.maxDelta <= 0.12
        stations = metroNetworks
            .flatMap(\.displayStations)
            .filter { station in
                region.contains(station.coordinate, paddingFactor: 0.2) &&
                    (showsNormalStations || station.isTransferStation)
            }
    }

}
