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

/// The three scales the map is ever asked to sit at.
///
/// These were four hardcoded literals — 0.22 for a city load, 0.1 for locate-me, 0.02 for a search
/// result, 0.01 for a station — covering what a rider experiences as one action: "show me this".
/// The same intent therefore landed at a different scale depending on which code path served it,
/// and pressing locate answered "where am I" with an 11km-wide view of the whole city.
enum MapCameraSpan {
    /// Whole metro area. Only for a city with no fix to centre on.
    static let city: CLLocationDegrees = 0.22
    /// Walkable surroundings — the default answer to "where am I". Deliberately below the 0.12
    /// threshold at which `refreshVisibleStations` starts drawing non-interchange stations, so
    /// the rider lands among the stations they could actually walk to.
    static let focused: CLLocationDegrees = 0.014
    /// One station and its exits.
    static let station: CLLocationDegrees = 0.008
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
            updateCamera(to: city.coordinate, spanDelta: MapCameraSpan.city)
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
                latitudeDelta: MapCameraSpan.station,
                longitudeDelta: MapCameraSpan.station
            )
        }

        return await stationSearchService.enrichStation(station)
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D) {
        updateCamera(to: coordinate, spanDelta: MapCameraSpan.focused)
    }

    /// MapKit has told us where it draws the rider. Corrects a camera that was placed before we
    /// knew how far Core Location's frame sits from the map's.
    ///
    /// The launch centring races the first user-location report and usually wins, so it runs off an
    /// uncorrected fix and lands ~540 m southwest of the dot — the reported bug. This is the first
    /// moment the right answer exists, so it is taken.
    ///
    /// Deliberately stateless. The guard *is* the question being asked — "is the camera sitting on
    /// the uncorrected fix, and is that not where the rider is?" — so it can only fire on a camera
    /// this bug actually misplaced. Once corrected the camera is 540 m from the raw fix and the
    /// first condition can never hold again; if the rider has panned away it never held at all; if
    /// their phone needs no correction the second condition never holds. No follow-mode, no flag to
    /// get out of sync.
    func mapUserLocationChanged(_ coordinate: CLLocationCoordinate2D) {
        guard let raw = locationService.currentLocation?.coordinate,
              let region = visibleRegion,
              region.center.distance(to: raw) < 50,
              region.center.distance(to: coordinate) > 50 else { return }
        updateCamera(to: coordinate, spanDelta: region.maxDelta)
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
    /// Whether the camera actually reached the rider, and the city to adopt if they are in a
    /// different one.
    ///
    /// Two separate answers, because they used to be one: this returned `City?`, and `nil` meant
    /// both "no fix" *and* "already in the right city". Callers could not tell a failed locate from
    /// a successful one, so launch treated a success in the current city as done-with-no-camera and
    /// left the map on the city centroid.
    struct UserCameraOutcome {
        let didCenter: Bool
        let cityToAdopt: City?
        /// Why the camera did not move, when the reason is one a rider should hear about.
        /// Cancellation is not such a reason and leaves this nil — see `centerOnUser`.
        var failureMessage: String? = nil
    }

    func centerOnUser() async -> UserCameraOutcome {
        do {
            let fix = try await locationService.requestCurrentLocation()
            // A cancelled locate-me (city switch mid-fix) must not recenter the new
            // city's map onto the user's physical position.
            guard !Task.isCancelled else { return UserCameraOutcome(didCenter: false, cityToAdopt: nil) }
            // Not `fix.coordinate`. Core Location reports WGS-84 and the map is GCJ-02 — measured
            // at 540.2 m apart in Beijing, which put the camera half a station southwest of the
            // rider's own dot while both were "correct". See LocationService.mapSpaceCorrection.
            let location = locationService.mapSpaceLocation(from: fix)
            updateCamera(to: location.coordinate)
            let selected = activeCityID.flatMap { cityService.getCity(byID: $0) }
            let nearest = selected.flatMap { cityService.cityToAdopt(for: location, whileSelecting: $0) }
            // Claim the camera for whichever city is about to load — including the current one.
            // Only the cross-city case used to be claimed, so a same-city reload (a second
            // `.task` run, a network refresh) yanked the camera back to the centroid.
            pendingUserCameraCityID = nearest?.id ?? activeCityID
            return UserCameraOutcome(didCenter: true, cityToAdopt: nearest)
        } catch is CancellationError {
            // Superseded, not failed. The rider asked for something else; say nothing.
            return UserCameraOutcome(didCenter: false, cityToAdopt: nil)
        } catch {
            // A fix that never arrives takes the request's full 15 s timeout and then this path,
            // which used to be silent — the map simply stayed on the city centroid and the rider
            // was left to conclude the app ignores their location. Missing is shown as missing.
            return UserCameraOutcome(
                didCenter: false,
                cityToAdopt: nil,
                failureMessage: error.localizedDescription
            )
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
        let visibleStations = oneMarkerPerPlace(
            metroNetworks
                .flatMap { stationsByCity[$0.cityID] ?? [] }
                .filter { station in
                    region.contains(station.coordinate, paddingFactor: 0.2) &&
                        (showsNormalStations || station.isTransferStation)
                }
        )
        // Cheap identity comparison (short-circuits, no temporary arrays) before publishing.
        if !sameStations(visibleStations, stations) {
            stations = visibleStations
        }
    }

    /// Collapses the copies of one station that several packs each ship.
    ///
    /// Neighbouring cities' packs carry the intercity corridor they share, so a station on it is
    /// shipped two or three times — 174 such pairs across the bundled data. The map drew every
    /// copy, which is why Guangzhou's 科韵路 appeared as a stack of interchange markers on one spot.
    ///
    /// Same rule as the router's `canonicalStationIDs`: identical name **and** colocation, never
    /// distance alone — 体育西路 and 天河南 are 281 m apart and are different stations. The copy
    /// that knows the most lines survives, which is the one carrying the metro service rather than
    /// the intercity-only stub.
    private func oneMarkerPerPlace(_ stations: [Station]) -> [Station] {
        guard metroNetworks.count > 1 else { return stations }
        var kept: [Station] = []
        kept.reserveCapacity(stations.count)
        var indicesByName: [String: [Int]] = [:]
        for station in stations {
            let key = normalizedStationName(station.name)
            let match = indicesByName[key, default: []].first {
                kept[$0].coordinate.distance(to: station.coordinate) <= 250
            }
            if let match {
                if station.lines.count > kept[match].lines.count { kept[match] = station }
            } else {
                indicesByName[key, default: []].append(kept.count)
                kept.append(station)
            }
        }
        return kept
    }

    private func sameStations(_ lhs: [Station], _ rhs: [Station]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.stationID == $1.stationID }
    }

}
