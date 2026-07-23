import Foundation
import UIKit

private struct MemoryWarningReleaseTargets: Sendable {
    let officialStationData: OfficialCityPackService?
    let stationInformationProvider: BeijingStationInformationProvider?
    let metroNetworkProvider: BundledMetroNetworkService?
    let transitRouteProvider: BundledMetroRouteProvider?

    func releaseMemory() async {
        await officialStationData?.releaseMemory()
        await stationInformationProvider?.releaseMemory()
        await metroNetworkProvider?.releaseMemory()
        await transitRouteProvider?.releaseMemory()
    }
}

@Observable
final class DIContainer {
    let locationService: LocationService
    let placeSearchProvider: PlaceSearchProviding
    let officialStationData: OfficialStationDataProviding
    let officialStationInformationProvider: OfficialStationInformationProviding
    let metroNetworkProvider: MetroNetworkProviding
    let routePlanningService: RoutePlanningService
    let stationSearchService: StationSearchService
    let cityService: CityService
    let tripMemoryService: TripMemoryService
    let routeFeasibilityService: RouteFeasibilityService
    let routeConfidenceService: RouteConfidenceService
    let comfortForecastService: ComfortForecastService
    let tripReminderService: TripReminderService
    let stationInformationDiskCache: OfficialStationInformationDiskCache?
    private let memoryWarningReleaseTargets: MemoryWarningReleaseTargets
    private var memoryWarningObserver: NSObjectProtocol?

    init(
        locationService: LocationService,
        placeSearchProvider: PlaceSearchProviding,
        officialStationData: OfficialStationDataProviding,
        officialStationInformationProvider: OfficialStationInformationProviding,
        metroNetworkProvider: MetroNetworkProviding,
        routePlanningService: RoutePlanningService,
        stationSearchService: StationSearchService,
        cityService: CityService,
        tripMemoryService: TripMemoryService,
        routeFeasibilityService: RouteFeasibilityService,
        routeConfidenceService: RouteConfidenceService,
        comfortForecastService: ComfortForecastService,
        tripReminderService: TripReminderService,
        stationInformationDiskCache: OfficialStationInformationDiskCache? = nil,
        memoryManagedOfficialStationData: OfficialCityPackService? = nil,
        memoryManagedStationInformationProvider: BeijingStationInformationProvider? = nil,
        memoryManagedMetroNetworkProvider: BundledMetroNetworkService? = nil,
        memoryManagedTransitRouteProvider: BundledMetroRouteProvider? = nil
    ) {
        self.locationService = locationService
        self.placeSearchProvider = placeSearchProvider
        self.officialStationData = officialStationData
        self.officialStationInformationProvider = officialStationInformationProvider
        self.metroNetworkProvider = metroNetworkProvider
        self.routePlanningService = routePlanningService
        self.stationSearchService = stationSearchService
        self.cityService = cityService
        self.tripMemoryService = tripMemoryService
        self.routeFeasibilityService = routeFeasibilityService
        self.routeConfidenceService = routeConfidenceService
        self.comfortForecastService = comfortForecastService
        self.tripReminderService = tripReminderService
        self.stationInformationDiskCache = stationInformationDiskCache
        self.memoryWarningReleaseTargets = MemoryWarningReleaseTargets(
            officialStationData: memoryManagedOfficialStationData,
            stationInformationProvider: memoryManagedStationInformationProvider,
            metroNetworkProvider: memoryManagedMetroNetworkProvider,
            transitRouteProvider: memoryManagedTransitRouteProvider
        )
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// Settings → Clear Cache. Deletes every downloaded/cached tier — city packs on disk and
    /// in memory, the device-local station-information snapshots, and URL caches — while
    /// leaving user data (tags, trips, records, personal media, preferences) untouched.
    func clearAllCaches() async {
        await memoryWarningReleaseTargets.officialStationData?.clearAllCaches()
        await stationInformationDiskCache?.clearAll()
        await memoryWarningReleaseTargets.releaseMemory()
        URLCache.shared.removeAllCachedResponses()
    }

    @MainActor
    func installMemoryWarningReleaseHandler() {
        guard memoryWarningObserver == nil else { return }
        let releaseTargets = memoryWarningReleaseTargets
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await releaseTargets.releaseMemory()
            }
        }
    }

    @MainActor
    func makeRoutePlannerViewModel() -> RoutePlannerViewModel {
        RoutePlannerViewModel(
            routePlanningService: routePlanningService,
            placeSearchProvider: placeSearchProvider,
            locationService: locationService
        )
    }

    @MainActor
    func makeStationSearchViewModel() -> StationSearchViewModel {
        StationSearchViewModel(
            stationSearchService: stationSearchService,
            locationService: locationService
        )
    }

    @MainActor
    func makeMapViewModel() -> MapViewModel {
        MapViewModel(
            locationService: locationService,
            stationSearchService: stationSearchService,
            cityService: cityService,
            metroNetworkProvider: metroNetworkProvider
        )
    }

    @MainActor
    func makeStationDetailViewModel() -> StationDetailViewModel {
        StationDetailViewModel(
            officialStationData: officialStationData,
            officialStationInformationProvider: officialStationInformationProvider
        )
    }

    @MainActor
    static func configure() -> DIContainer {
        let locationService = LocationService()
        let placeSearchProvider = MapKitPlaceSearchProvider()
        let metroNetworkProvider = BundledMetroNetworkService()
        // Dedicated ephemeral sessions (no cookies, no shared cache) instead of `URLSession.shared`
        // — a stuck city-pack/realtime fetch shouldn't serialize behind unrelated shared-session
        // traffic, matching the pattern already used for the Beijing station-info provider.
        let realtimeArrivalProvider = HongKongRealtimeArrivalProvider(session: Self.makeEphemeralSession())
        let stationInformationDiskCache = OfficialStationInformationDiskCache()
        let officialStationInformationProvider = BeijingStationInformationProvider(
            diskCache: stationInformationDiskCache
        )
        // The bundled catalog decode + validation is heavy; hand the service a loader so it
        // runs lazily on the actor instead of blocking app launch on the main thread here.
        let officialStationData = OfficialCityPackService(
            session: Self.makeEphemeralSession(),
            metroNetworks: metroNetworkProvider,
            realtimeArrivals: realtimeArrivalProvider,
            officialResourceCatalogLoader: { try .bundled() }
        )
        let transitRouteProvider = BundledMetroRouteProvider(metroNetworks: metroNetworkProvider)
        let cityService = CityService()
        let stationSearchService = StationSearchService(
            placeSearchProvider: placeSearchProvider,
            officialStationData: officialStationData,
            metroNetworkProvider: metroNetworkProvider,
            cityService: cityService
        )
        let comfortForecastService = ComfortForecastService()
        let routePlanningService = RoutePlanningService(
            placeSearchProvider: placeSearchProvider,
            routeProvider: transitRouteProvider,
            officialStationData: officialStationData,
            comfortForecastService: comfortForecastService
        )
        let tripMemoryService = TripMemoryService()
        let routeFeasibilityService = RouteFeasibilityService()
        let routeConfidenceService = RouteConfidenceService()
        let tripReminderService = TripReminderService()

        let container = DIContainer(
            locationService: locationService,
            placeSearchProvider: placeSearchProvider,
            officialStationData: officialStationData,
            officialStationInformationProvider: officialStationInformationProvider,
            metroNetworkProvider: metroNetworkProvider,
            routePlanningService: routePlanningService,
            stationSearchService: stationSearchService,
            cityService: cityService,
            tripMemoryService: tripMemoryService,
            routeFeasibilityService: routeFeasibilityService,
            routeConfidenceService: routeConfidenceService,
            comfortForecastService: comfortForecastService,
            tripReminderService: tripReminderService,
            stationInformationDiskCache: stationInformationDiskCache,
            memoryManagedOfficialStationData: officialStationData,
            memoryManagedStationInformationProvider: officialStationInformationProvider,
            memoryManagedMetroNetworkProvider: metroNetworkProvider,
            memoryManagedTransitRouteProvider: transitRouteProvider
        )
        container.installMemoryWarningReleaseHandler()
        return container
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }
}
