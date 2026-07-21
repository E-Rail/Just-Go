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
    // The city the map is currently loaded for — search publishes are guarded on it so
    // a slow city-A place search can't flash its results under city B's map.
    private var activeCityID: String?
    // Set when the locate flow has already centered the camera on the user inside the
    // city about to be selected — that city's loadStations must not yank the camera to
    // the city center. Cleared on every load so a manual pick invalidates it.
    private var pendingUserCameraCityID: String?
    private var viewportLoadTask: Task<Void, Never>?
    private var cityLoadTask: Task<Void, Never>?
    // Publish token. A load only writes its results if no newer load has started since,
    // which lets the city load and a viewport load coexist without either cancelling the
    // other — the newest request simply wins. See `viewportChanged`.
    private var networkLoadGeneration = 0
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
        activeCityID = city.id
        let keepUserCamera = pendingUserCameraCityID == city.id
        pendingUserCameraCityID = nil
        clearSearch()
        viewportLoadTask?.cancel()
        cityLoadTask?.cancel()
        markerRefreshTask?.cancel()
        if !keepUserCamera {
            // Skipped only when the locate flow triggered this switch — the camera is
            // already on the user inside this city, and recentering would undo the locate.
            updateCamera(to: city.coordinate, spanDelta: 0.22)
        }
        metroNetworks = []
        stations = []
        networkLoadGeneration += 1
        let generation = networkLoadGeneration
        cityLoadTask = Task { [weak self] in
            await self?.loadNetworks(cityIDs: [city.id], generation: generation)
        }
    }

    func searchEverywhere(in city: City?) async {
        guard let city else { return }
        let cityID = city.id
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        errorMessage = nil
        do {
            let results = try await stationSearchService.searchPlaces(
                keyword: query,
                city: cityID,
                region: visibleRegion?.mkCoordinateRegion
            )
            // MKLocalSearch ignores Swift task cancellation, so a superseded query can return
            // after a newer one — drop it instead of stomping the current results. The city
            // guard covers the window before a city switch's deferred clearSearch runs.
            guard !Task.isCancelled,
                  activeCityID == cityID,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            errorMessage = nil
            searchResults = results
        } catch {
            guard !Task.isCancelled,
                  activeCityID == cityID,
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
        // Deliberately does NOT cancel `cityLoadTask`. Setting the camera in `loadStations`
        // makes MKMapView answer with `regionDidChangeAnimated`, which lands here — cancelling
        // on that killed the very load that draws the lines, and every further frame of the
        // opening animation cancelled the debounced retry too, so nothing drew until the map
        // stopped moving. The generation token below supersedes stale results instead.
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
            // Claim the token only now, once this load is actually starting — during the
            // debounce window an in-flight city load is still the freshest thing there is
            // and must be allowed to publish.
            networkLoadGeneration += 1
            await loadNetworks(cityIDs: visibleCityIDs, generation: networkLoadGeneration)
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

    /// Centers the camera on the user and returns the city the app should switch to when
    /// the user is clearly outside the selected city's metro area — nil otherwise. The
    /// caller owns the actual `selectedCity` write; `loadStations` for the returned city
    /// then keeps the user-centered camera instead of recentering (pendingUserCameraCityID).
    func centerOnUser() async -> City? {
        do {
            let location = try await locationService.requestCurrentLocation()
            // A cancelled locate-me (city switch mid-fix) must not recenter the new
            // city's map onto the user's physical position.
            guard !Task.isCancelled else { return nil }
            updateCamera(to: location.coordinate)
            // Bounded, same rule as the planner's cross-city fills: within 80km of the
            // selected city's center the user is plausibly in its metro area — seam
            // positions in adjacent interconnected metros (Guangzhou/Foshan) must not
            // flip the selection. Beyond it, follow the user to the nearest city.
            guard let selected = activeCityID.flatMap({ cityService.getCity(byID: $0) }) else { return nil }
            let selectedCenter = CLLocation(latitude: selected.coordinate.latitude, longitude: selected.coordinate.longitude)
            guard location.distance(from: selectedCenter) > 80_000,
                  let nearest = cityService.findNearestCity(to: location),
                  nearest.id != selected.id else { return nil }
            pendingUserCameraCityID = nearest.id
            return nearest
        } catch {
            return nil
        }
    }

    /// Two stages on purpose. Line geometry is published the moment the networks decode, so the
    /// map draws its lines without waiting on `stations(in:)` — which builds a `Station` object
    /// per station (444 for Beijing) on the same actor and so runs strictly after the decode.
    /// Markers then fill in behind the lines.
    private func loadNetworks(cityIDs: [String], generation: Int) async {
        let requested = Set(cityIDs)
        let retained = metroNetworks.filter { requested.contains($0.cityID) }
        var loadedByCity = Dictionary(retained.map { ($0.cityID, $0) }, uniquingKeysWith: { first, _ in first })

        await withTaskGroup(of: MetroNetwork?.self) { group in
            for cityID in requested where loadedByCity[cityID] == nil {
                group.addTask { [metroNetworkProvider] in
                    await metroNetworkProvider.network(for: cityID)
                }
            }
            for await network in group {
                guard let network, !Task.isCancelled else { continue }
                loadedByCity[network.cityID] = network
            }
        }

        guard !Task.isCancelled, generation == networkLoadGeneration else { return }
        guard let region = visibleRegion, region.maxDelta <= 2 else {
            if !metroNetworks.isEmpty { metroNetworks = [] }
            if !stations.isEmpty { stations = [] }
            return
        }

        // Stage 1 — lines.
        metroNetworks = loadedByCity.values
            .filter { $0.bounds.intersects(region) }
            .sorted { $0.cityID < $1.cityID }
        #if DEBUG
        MainThreadHangMonitor.mark("map.lines gen=\(generation) cities=\(metroNetworks.count)")
        #endif

        // Stage 2 — station markers.
        var loadedStationsByCity: [String: [Station]] = [:]
        await withTaskGroup(of: (String, [Station]).self) { group in
            for cityID in loadedByCity.keys where stationsByCity[cityID] == nil {
                group.addTask { [metroNetworkProvider] in
                    (cityID, await metroNetworkProvider.stations(in: cityID))
                }
            }
            for await (cityID, cityStations) in group {
                guard !Task.isCancelled else { continue }
                loadedStationsByCity[cityID] = cityStations
            }
        }

        guard !Task.isCancelled, generation == networkLoadGeneration else { return }
        stationsByCity.merge(loadedStationsByCity) { _, new in new }
        stationsByCity = stationsByCity.filter { requested.contains($0.key) }
        refreshVisibleStations()
        #if DEBUG
        MainThreadHangMonitor.mark("map.markers gen=\(generation) stations=\(stations.count)")
        #endif
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
