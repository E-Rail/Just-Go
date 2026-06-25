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

    func contains(_ coordinate: CLLocationCoordinate2D, paddingFactor: Double) -> Bool {
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
    private var stationsByCity: [String: [Station]] = [:]
    private var viewportLoadTask: Task<Void, Never>?
    private var cityLoadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

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
            nearbyStations = try await stationSearchService.searchNearby(location: location.coordinate)
            errorMessage = nil
        } catch {
            nearbyStations = []
            errorMessage = locationErrorMessage(for: error)
        }
    }

    @discardableResult
    func requestLocationAccess() async -> Bool {
        do {
            _ = try await locationService.requestCurrentLocation()
            await loadNearbyStations()
            return true
        } catch {
            nearbyStations = []
            errorMessage = locationErrorMessage(for: error)
            return false
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
            errorMessage = AppLocalization.localized("Place search requires a network connection")
        }
    }

    func scheduleStationSearch(in city: City?) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.searchStations(in: city)
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
    }

    func viewportChanged(to region: MapVisibleRegion) {
        visibleRegion = region
        viewportLoadTask?.cancel()
        refreshVisibleStations()

        guard region.maxDelta <= 2 else {
            if !metroNetworks.isEmpty { metroNetworks = [] }
            return
        }

        viewportLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            let centerCityIDs = cityService.getAllCities()
                .filter { region.contains($0.coordinate, paddingFactor: 0.8) }
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
            errorMessage = AppLocalization.localized("Station details are temporarily unavailable")
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

    func centerOnUser() async {
        do {
            let location = try await locationService.requestCurrentLocation()
            updateCamera(to: location.coordinate)
        } catch { }
    }

    private func loadNetworks(cityIDs: [String]) async {
        let requested = Set(cityIDs)
        let retained = metroNetworks.filter { requested.contains($0.cityID) }
        var loadedByCity = Dictionary(uniqueKeysWithValues: retained.map { ($0.cityID, $0) })

        await withTaskGroup(of: (MetroNetwork?, [Station]).self) { group in
            for cityID in requested where loadedByCity[cityID] == nil {
                group.addTask { [metroNetworkProvider] in
                    async let network = metroNetworkProvider.network(for: cityID)
                    async let stations = metroNetworkProvider.stations(in: cityID)
                    return await (network, stations)
                }
            }
            for await (network, stations) in group {
                if let network {
                    loadedByCity[network.cityID] = network
                    stationsByCity[network.cityID] = stations
                }
            }
        }

        guard !Task.isCancelled else { return }
        guard let region = visibleRegion, region.maxDelta <= 2 else {
            if !metroNetworks.isEmpty { metroNetworks = [] }
            if !stations.isEmpty { stations = [] }
            return
        }
        metroNetworks = loadedByCity.values
            .filter { $0.bounds.intersects(region) }
            .sorted { $0.cityID < $1.cityID }
        refreshVisibleStations()
    }

    private func locationErrorMessage(for error: Error) -> String {
        (error as? LocationServiceError)?.errorDescription ??
            AppLocalization.localized("Current location unavailable")
    }

    private func refreshVisibleStations() {
        guard let region = visibleRegion, region.maxDelta <= 0.8 else {
            if !stations.isEmpty { stations = [] }
            return
        }

        let showsNormalStations = region.maxDelta <= 0.12
        let visibleStations = metroNetworks
            .flatMap { stationsByCity[$0.cityID] ?? [] }
            .filter { station in
                region.contains(station.coordinate, paddingFactor: 0.2) &&
                    (showsNormalStations || station.isTransferStation)
            }
        if visibleStations.map(\.stationID) != stations.map(\.stationID) {
            stations = visibleStations
        }
    }

}
