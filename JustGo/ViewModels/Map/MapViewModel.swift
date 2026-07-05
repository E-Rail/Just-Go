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
    var searchText = ""
    var searchResults: [TransitPlace] = []
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
    private var markerRefreshTask: Task<Void, Never>?

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

    deinit {
        viewportLoadTask?.cancel()
        cityLoadTask?.cancel()
        searchTask?.cancel()
        markerRefreshTask?.cancel()
    }

    var userLocation: CLLocationCoordinate2D? {
        locationService.currentLocation?.coordinate
    }

    func loadStations(for city: City) async {
        clearSearch()
        viewportLoadTask?.cancel()
        cityLoadTask?.cancel()
        markerRefreshTask?.cancel()
        updateCamera(to: city.coordinate, spanDelta: 0.22)
        metroNetworks = []
        stations = []
        cityLoadTask = Task { [weak self] in
            await self?.loadNetworks(cityIDs: [city.id])
        }
    }

    func searchEverywhere(in city: City?) async {
        guard let city else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        errorMessage = nil
        do {
            let results = try await stationSearchService.searchPlaces(
                keyword: query,
                city: city.id,
                region: visibleRegion?.mkCoordinateRegion
            )
            // MKLocalSearch ignores Swift task cancellation, so a superseded query can return
            // after a newer one — drop it instead of stomping the current results.
            guard !Task.isCancelled,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            errorMessage = nil
            searchResults = results
        } catch {
            guard !Task.isCancelled,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchResults = []
            errorMessage = AppLocalization.localized("Place search requires a network connection")
        }
    }

    func scheduleSearch(in city: City?) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.searchEverywhere(in: city)
        }
    }

    /// The programmed station a place/POI corresponds to, if any (so a searched or tapped
    /// place that *is* a station opens the station detail instead of the Apple place card).
    func matchingStation(for place: TransitPlace, city: City?) async -> Station? {
        guard let city else { return nil }
        return await stationSearchService.station(matching: place, city: city.id)
    }

    func clearSearch() {
        searchTask?.cancel()
        markerRefreshTask?.cancel()
        searchText = ""
        searchResults = []
        errorMessage = nil
    }

    func viewportChanged(to region: MapVisibleRegion) {
        visibleRegion = region
        cityLoadTask?.cancel()
        viewportLoadTask?.cancel()
        scheduleVisibleStationsRefresh()

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

        return await stationSearchService.enrichStation(station)
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
            // A cancelled locate-me (city switch mid-fix) must not recenter the new
            // city's map onto the user's physical position.
            guard !Task.isCancelled else { return }
            updateCamera(to: location.coordinate)
        } catch { }
    }

    private func loadNetworks(cityIDs: [String]) async {
        let requested = Set(cityIDs)
        let retained = metroNetworks.filter { requested.contains($0.cityID) }
        var loadedByCity = Dictionary(retained.map { ($0.cityID, $0) }, uniquingKeysWith: { first, _ in first })

        await withTaskGroup(of: (MetroNetwork?, [Station]).self) { group in
            for cityID in requested where loadedByCity[cityID] == nil {
                group.addTask { [metroNetworkProvider] in
                    async let network = metroNetworkProvider.network(for: cityID)
                    async let stations = metroNetworkProvider.stations(in: cityID)
                    return await (network, stations)
                }
            }
            for await (network, stations) in group {
                guard !Task.isCancelled else { continue }
                if let network {
                    loadedByCity[network.cityID] = network
                    stationsByCity[network.cityID] = stations
                }
            }
        }

        guard !Task.isCancelled else { return }
        stationsByCity = stationsByCity.filter { requested.contains($0.key) }
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

    /// Debounce the viewport-driven refresh so it runs once panning briefly settles instead of
    /// on every 30–60 Hz region-change frame (the O(N) flatMap/filter over all stations was the
    /// dominant map-interaction CPU cost).
    private func scheduleVisibleStationsRefresh() {
        markerRefreshTask?.cancel()
        markerRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.refreshVisibleStations()
        }
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
        // Cheap identity comparison (short-circuits, no temporary arrays) before publishing.
        if !sameStations(visibleStations, stations) {
            stations = visibleStations
        }
    }

    private func sameStations(_ lhs: [Station], _ rhs: [Station]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.stationID == $1.stationID }
    }

}
