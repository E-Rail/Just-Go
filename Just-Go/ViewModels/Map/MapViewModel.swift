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

extension MapVisibleRegion {
    /// The smallest region that frames every one of these coordinates, with room around them. The
    /// padding and minimum span are the route map's.
    init?(fitting coordinates: [CLLocationCoordinate2D], minimumSpan: CLLocationDegrees = 0.02) {
        guard !coordinates.isEmpty else { return nil }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(), let maxLongitude = longitudes.max() else {
            return nil
        }
        self.init(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            latitudeDelta: max((maxLatitude - minLatitude) * 1.35, minimumSpan),
            longitudeDelta: max((maxLongitude - minLongitude) * 1.35, minimumSpan)
        )
    }
}

/// The three scales the map is ever asked to sit at, so one intent ("show me this") lands at one
/// zoom whichever code path serves it.
enum MapCameraSpan {
    /// Whole metro area. For a first launch with no fix to centre on, and as the bias region
    /// for a place search.
    static let city: CLLocationDegrees = 0.22
    /// Walkable surroundings: the default answer to "where am I". Deliberately below the 0.12
    /// threshold at which `refreshVisibleStations` starts drawing non-interchange stations, so
    /// the rider lands among the stations they could actually walk to.
    static let focused: CLLocationDegrees = 0.014
    /// One station and its exits.
    static let station: CLLocationDegrees = 0.008
}

/// `@MainActor` because it publishes SwiftUI-observed state, including from the unstructured task
/// `scheduleVisibleStationsRefresh` spawns. The visible-station filter is cheap enough for the main
/// actor: 0.07 ms per refresh for 6,718 stations, behind a 50 ms debounce.
@MainActor
@Observable
final class MapViewModel {
    var stations: [Station] = []
    var visibleRegion: MapVisibleRegion?
    /// The span the last camera move asked for, which is not what `visibleRegion` then holds (see
    /// `mapUserLocationChanged`). Every writer of `visibleRegion` sets it, or a stale value becomes
    /// a jump to a zoom nobody asked for.
    private var requestedSpanDelta: CLLocationDegrees = MapCameraSpan.city
    var metroNetworks: [MetroNetwork] = []
    var isLocationAuthorized: Bool {
        locationService.isAuthorized
    }

    private let locationService: LocationService
    private let stationSearchService: StationSearchService
    private let metroNetworkProvider: MetroNetworkProviding
    private var stationsByCity: [String: [Station]] = [:]
    @ObservationIgnored nonisolated(unsafe) private var viewportLoadTask: Task<Void, Never>?
    // Publish token. A load only writes its results if no newer load has started since.
    private var networkLoadGeneration = 0
    @ObservationIgnored nonisolated(unsafe) private var markerRefreshTask: Task<Void, Never>?

    init(
        locationService: LocationService,
        stationSearchService: StationSearchService,
        metroNetworkProvider: MetroNetworkProviding
    ) {
        self.locationService = locationService
        self.stationSearchService = stationSearchService
        self.metroNetworkProvider = metroNetworkProvider
    }

    // `nonisolated` on the two task handles above is what lets this run: `deinit` is
    // nonisolated and cannot touch main-actor state, and `Task.cancel()` is safe from any thread.
    deinit {
        viewportLoadTask?.cancel()
        markerRefreshTask?.cancel()
    }

    /// The programmed station a place/POI corresponds to, if any (so a searched or tapped
    /// place that *is* a station opens the station detail instead of the Apple place card).
    func matchingStation(for place: TransitPlace) async -> Station? {
        await stationSearchService.station(matching: place)
    }

    /// What the map has loaded is decided by what the map is looking at, and nothing else.
    func viewportChanged(to region: MapVisibleRegion) {
        visibleRegion = region
        requestedSpanDelta = region.maxDelta
        viewportLoadTask?.cancel()
        scheduleVisibleStationsRefresh()

        guard region.maxDelta <= 2 else {
            if !metroNetworks.isEmpty { metroNetworks = [] }
            return
        }

        viewportLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            // Which packs the viewport touches, by their own bounding boxes. City centroids are
            // only in view when zoomed out to a whole metro area.
            let visibleCityIDs = await metroNetworkProvider.networkSummaries()
                .filter { $0.bounds.intersects(region) }
                .map(\.cityID)
            guard !Task.isCancelled else { return }
            // Claim the token only once this load starts: during the debounce, a still-running
            // earlier load is the freshest data there is and may publish.
            networkLoadGeneration += 1
            await loadNetworks(cityIDs: visibleCityIDs, generation: networkLoadGeneration)
        }
    }

    @discardableResult
    func selectStation(_ station: Station) async -> Station {
        requestedSpanDelta = MapCameraSpan.station
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

    /// MapKit has reported where it draws the rider: correct a camera placed on the uncorrected
    /// Core Location fix, ~540 m southwest of the dot. The launch centring usually runs before this
    /// report arrives.
    ///
    /// Stateless on purpose: the guard asks "is the camera on the uncorrected fix, and is that not
    /// where the rider is?", which can only be true of a camera placed that way. After one
    /// correction, a pan, or on a phone that needs none, it never holds.
    func mapUserLocationChanged(_ coordinate: CLLocationCoordinate2D) {
        guard let raw = locationService.currentLocation?.coordinate,
              let region = visibleRegion,
              region.center.distance(to: raw) < 50,
              region.center.distance(to: coordinate) > 50 else { return }
        // The span this camera was *asked* for. `visibleRegion` holds what MapKit settled on after
        // widening the square to the screen's aspect; re-applying that widens it again (0.014
        // asked, 0.0271 shown).
        updateCamera(to: coordinate, spanDelta: requestedSpanDelta)
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D, spanDelta: CLLocationDegrees) {
        requestedSpanDelta = spanDelta
        withAnimation {
            visibleRegion = MapVisibleRegion(
                center: coordinate,
                latitudeDelta: spanDelta,
                longitudeDelta: spanDelta
            )
        }
    }

    /// Whether the camera reached the rider, and why not when it did not.
    struct UserCameraOutcome {
        let didCenter: Bool
        /// Why the camera did not move, when the reason is one a rider should hear about.
        /// Cancellation is not such a reason and leaves this nil. See `centerOnUser`.
        var failureMessage: String? = nil
    }

    func centerOnUser() async -> UserCameraOutcome {
        do {
            let fix = try await locationService.requestCurrentLocation()
            // A superseded locate-me must not drag the camera off wherever the rider went next.
            guard !Task.isCancelled else { return UserCameraOutcome(didCenter: false) }
            // Map space, not `fix.coordinate`: Core Location reports WGS-84 and the map is GCJ-02,
            // about 540 m apart in Beijing. See `LocationService.mapSpaceCorrection`.
            updateCamera(to: locationService.mapSpaceLocation(from: fix).coordinate)
            return UserCameraOutcome(didCenter: true)
        } catch is CancellationError {
            // Superseded, not failed. The rider asked for something else; say nothing.
            return UserCameraOutcome(didCenter: false)
        } catch {
            // A fix that never arrives ends here after the 15 s timeout. Say so, rather than leave
            // the map silently where it was.
            return UserCameraOutcome(didCenter: false, failureMessage: error.localizedDescription)
        }
    }

    /// Two stages: line geometry publishes as soon as the networks decode, then station markers,
    /// which `stations(in:)` builds one `Station` per station on the same actor.
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

        // Stage 1: lines.
        metroNetworks = loadedByCity.values
            .filter { $0.bounds.intersects(region) }
            .sorted { $0.cityID < $1.cityID }

        // Stage 2: station markers.
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

    /// Debounced so the refresh runs once panning settles, not on every region-change frame.
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
