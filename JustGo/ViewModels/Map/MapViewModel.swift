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
    /// Whole metro area. For a first launch with no fix to centre on, and as the bias region
    /// for a place search.
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
    // Publish token. A load only writes its results if no newer load has started since.
    private var networkLoadGeneration = 0
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
        markerRefreshTask?.cancel()
    }

    /// The programmed station a place/POI corresponds to, if any (so a searched or tapped
    /// place that *is* a station opens the station detail instead of the Apple place card).
    func matchingStation(for place: TransitPlace) async -> Station? {
        await stationSearchService.station(matching: place)
    }

    /// The only thing that decides what the map has loaded: what the map is looking at.
    ///
    /// There was a second, competing loader keyed on a selected city, and the two disagreed —
    /// a city load reset the camera to a centroid the rider had not asked for, and a viewport
    /// load could be cancelled by it mid-flight. The camera is now the single input.
    func viewportChanged(to region: MapVisibleRegion) {
        visibleRegion = region
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
            // debounce window a still-running earlier load is the freshest thing there is
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

    /// Whether the camera actually reached the rider, and why not when it did not.
    ///
    /// It used to also answer "which city should the app switch to", because putting the camera
    /// on the rider meant changing what the whole app was looking at. Panning the map to another
    /// city is now just panning the map, so locating is just moving the camera.
    struct UserCameraOutcome {
        let didCenter: Bool
        /// Why the camera did not move, when the reason is one a rider should hear about.
        /// Cancellation is not such a reason and leaves this nil — see `centerOnUser`.
        var failureMessage: String? = nil
    }

    func centerOnUser() async -> UserCameraOutcome {
        do {
            let fix = try await locationService.requestCurrentLocation()
            // A superseded locate-me must not drag the camera off wherever the rider went next.
            guard !Task.isCancelled else { return UserCameraOutcome(didCenter: false) }
            // Not `fix.coordinate`. Core Location reports WGS-84 and the map is GCJ-02 — measured
            // at 540.2 m apart in Beijing, which put the camera half a station southwest of the
            // rider's own dot while both were "correct". See LocationService.mapSpaceCorrection.
            updateCamera(to: locationService.mapSpaceLocation(from: fix).coordinate)
            return UserCameraOutcome(didCenter: true)
        } catch is CancellationError {
            // Superseded, not failed. The rider asked for something else; say nothing.
            return UserCameraOutcome(didCenter: false)
        } catch {
            // A fix that never arrives takes the request's full 15 s timeout and then this path,
            // which used to be silent — the map simply stayed where it was and the rider was left
            // to conclude the app ignores their location. Missing is shown as missing.
            return UserCameraOutcome(didCenter: false, failureMessage: error.localizedDescription)
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
        let inView = metroNetworks
            .flatMap { stationsByCity[$0.cityID] ?? [] }
            .filter { station in
                region.contains(station.coordinate, paddingFactor: 0.2) &&
                    (showsNormalStations || station.isTransferStation)
            }
        // Only one pack in view means no pack can be duplicating another's stations.
        let visibleStations = metroNetworks.count > 1 ? inView.oneEntryPerPlace() : inView
        // Cheap identity comparison (short-circuits, no temporary arrays) before publishing.
        if !sameStations(visibleStations, stations) {
            stations = visibleStations
        }
    }

    private func sameStations(_ lhs: [Station], _ rhs: [Station]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.stationID == $1.stationID }
    }

}
