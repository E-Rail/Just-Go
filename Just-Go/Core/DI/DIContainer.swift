import Foundation
import UIKit

private struct MemoryWarningReleaseTargets: Sendable {
    let officialStationData: OfficialCityPackService?
    let stationInformationProvider: OfficialStationInformationRouter?
    let metroNetworkProvider: BundledMetroNetworkService?
    let transitRouteProvider: BundledMetroRouteProvider?
    /// Everything Baidu answered this session, plus the access legs measured from it and MapKit.
    /// Capped, and released on a memory warning: all of it can be asked again for the cost of a
    /// request.
    let tripObservations: BaiduTripObservationService?
    let ridingRoutes: BaiduRidingRouteProvider?
    let accessRoutes: MemoizingAccessRouteProvider?

    func releaseMemory() async {
        await officialStationData?.releaseMemory()
        await stationInformationProvider?.releaseMemory()
        await metroNetworkProvider?.releaseMemory()
        await transitRouteProvider?.releaseMemory()
        await tripObservations?.releaseMemory()
        await ridingRoutes?.releaseMemory()
        await accessRoutes?.releaseMemory()
    }
}

@Observable
final class DIContainer {
    let locationService: LocationService
    let placeSearchProvider: PlaceSearchProviding
    let officialStationData: OfficialStationDataProviding
    let officialStationInformationProvider: OfficialStationInformationProviding
    let stationInformationDirectory: StationInformationDirectory
    let metroNetworkProvider: MetroNetworkProviding
    let routePlanningService: RoutePlanningService
    /// Present only when a key is configured. Held so Transit Data can show what this launch has
    /// spent and what the provider last refused.
    let baiduMapsClient: BaiduMapsClient?
    let stationSearchService: StationSearchService
    let cityService: CityService
    let tripMemoryService: TripMemoryService
    /// Optional because the app builds, launches and routes with no Baidu key; without one the line
    /// page simply cannot check itself against the operator.
    let lineObservationProvider: LineObservationProviding?
    let routeFeasibilityService: RouteFeasibilityService
    let routeConfidenceService: RouteConfidenceService
    let tripReminderService: TripReminderService
    let stationInformationDiskCache: OfficialStationInformationDiskCache?
    /// Operator notices, fetched on the device and held in memory only. Only Beijing publishes a
    /// parseable list.
    let serviceNoticeProvider = BeijingServiceNoticeProvider()
    private let memoryWarningReleaseTargets: MemoryWarningReleaseTargets
    private var memoryWarningObserver: NSObjectProtocol?

    init(
        locationService: LocationService,
        placeSearchProvider: PlaceSearchProviding,
        officialStationData: OfficialStationDataProviding,
        officialStationInformationProvider: OfficialStationInformationProviding,
        stationInformationDirectory: StationInformationDirectory,
        metroNetworkProvider: MetroNetworkProviding,
        routePlanningService: RoutePlanningService,
        baiduMapsClient: BaiduMapsClient?,
        stationSearchService: StationSearchService,
        cityService: CityService,
        tripMemoryService: TripMemoryService,
        lineObservationProvider: LineObservationProviding? = nil,
        routeFeasibilityService: RouteFeasibilityService,
        routeConfidenceService: RouteConfidenceService,
        tripReminderService: TripReminderService,
        stationInformationDiskCache: OfficialStationInformationDiskCache? = nil,
        memoryManagedOfficialStationData: OfficialCityPackService? = nil,
        memoryManagedStationInformationProvider: OfficialStationInformationRouter? = nil,
        memoryManagedMetroNetworkProvider: BundledMetroNetworkService? = nil,
        memoryManagedTransitRouteProvider: BundledMetroRouteProvider? = nil,
        memoryManagedTripObservations: BaiduTripObservationService? = nil,
        memoryManagedRidingRoutes: BaiduRidingRouteProvider? = nil,
        memoryManagedAccessRoutes: MemoizingAccessRouteProvider? = nil
    ) {
        self.locationService = locationService
        self.placeSearchProvider = placeSearchProvider
        self.officialStationData = officialStationData
        self.officialStationInformationProvider = officialStationInformationProvider
        self.stationInformationDirectory = stationInformationDirectory
        self.metroNetworkProvider = metroNetworkProvider
        self.routePlanningService = routePlanningService
        self.baiduMapsClient = baiduMapsClient
        self.stationSearchService = stationSearchService
        self.cityService = cityService
        self.tripMemoryService = tripMemoryService
        self.lineObservationProvider = lineObservationProvider
        self.routeFeasibilityService = routeFeasibilityService
        self.routeConfidenceService = routeConfidenceService
        self.tripReminderService = tripReminderService
        self.stationInformationDiskCache = stationInformationDiskCache
        self.memoryWarningReleaseTargets = MemoryWarningReleaseTargets(
            officialStationData: memoryManagedOfficialStationData,
            stationInformationProvider: memoryManagedStationInformationProvider,
            metroNetworkProvider: memoryManagedMetroNetworkProvider,
            transitRouteProvider: memoryManagedTransitRouteProvider,
            tripObservations: memoryManagedTripObservations,
            ridingRoutes: memoryManagedRidingRoutes,
            accessRoutes: memoryManagedAccessRoutes
        )
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// Settings → Clear Cache. Deletes every downloaded or cached tier (city packs on disk and in
    /// memory, device-local station-information snapshots, URL caches) and leaves user data
    /// untouched: tags, trips, preferences.
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

    @MainActor private var cachedRoutePlannerViewModel: RoutePlannerViewModel?

    /// The one planner the map's plan → results → detail chain shares.
    ///
    /// Held here rather than in the map's `@State` so the navigation router can build any of those
    /// screens synchronously, before any `.task` has run. A push that resolves to an optional that
    /// is still nil renders as a blank page.
    @MainActor
    func sharedRoutePlannerViewModel() -> RoutePlannerViewModel {
        if let cachedRoutePlannerViewModel { return cachedRoutePlannerViewModel }
        let created = makeRoutePlannerViewModel()
        cachedRoutePlannerViewModel = created
        return created
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
            metroNetworkProvider: metroNetworkProvider
        )
    }

    @MainActor
    func makeStationDetailViewModel() -> StationDetailViewModel {
        StationDetailViewModel(
            officialStationData: officialStationData,
            officialStationInformationProvider: officialStationInformationProvider,
            stationInformationDirectory: stationInformationDirectory
        )
    }

    @MainActor
    static func configure() -> DIContainer {
        let locationService = LocationService()
        // Baidu answers Chinese place queries Apple misses. The key comes from the git-ignored
        // Secrets.xcconfig; without it the composite is pure MapKit.
        let baiduConfiguration = BaiduMapsConfiguration.fromBundle()
        let baiduClient = baiduConfiguration.isConfigured
            ? BaiduMapsClient(configuration: baiduConfiguration)
            : nil
        let placeSearchProvider = CompositePlaceSearchProvider(
            baidu: baiduClient.map { BaiduPlaceSearchProvider(client: $0) }
        )
        let tripObservationProvider = baiduClient.map { BaiduTripObservationService(client: $0) }
        let metroNetworkProvider = BundledMetroNetworkService()
        // Dedicated ephemeral sessions (no cookies, no shared cache), so a stuck city-pack or
        // realtime fetch does not queue behind unrelated shared-session traffic.
        let realtimeArrivalProvider = HongKongRealtimeArrivalProvider(session: Self.makeEphemeralSession())
        let stationInformationDiskCache = OfficialStationInformationDiskCache()
        // One provider per source, dispatched by a router. Which source a station uses comes from
        // the bundled Station Information API directory, as it would for any third-party consumer.
        let stationInformationRouter = OfficialStationInformationRouter(
            beijing: BeijingStationInformationProvider(diskCache: stationInformationDiskCache),
            shanghai: ShanghaiStationInformationProvider(diskCache: stationInformationDiskCache),
            guangzhou: GuangzhouStationInformationProvider(diskCache: stationInformationDiskCache),
            hangzhou: HangzhouStationInformationProvider(diskCache: stationInformationDiskCache)
        )
        let stationInformationDirectory = StationInformationDirectory()
        // The bundled catalog's decode and validation is heavy, so the service gets a loader and
        // runs it lazily on its actor rather than on the main thread at launch.
        let officialStationData = OfficialCityPackService(
            session: Self.makeEphemeralSession(),
            metroNetworks: metroNetworkProvider,
            realtimeArrivals: realtimeArrivalProvider,
            officialResourceCatalogLoader: { try .bundled() }
        )
        // One access-leg builder for both callers: the graph walks to the station, enrichment
        // re-walks to the door it picks. Walking and driving are MapKit; cycling is Baidu's router,
        // which MapKit has no equivalent of, and without a key a bike leg is the re-timed walking
        // shape. Memoized once around the shared instance, so every walk and re-plan draws on one
        // answer per leg.
        let ridingRouteProvider = baiduClient.map { BaiduRidingRouteProvider(client: $0) }
        let walkingRouteProvider = MemoizingAccessRouteProvider(
            provider: CompositeAccessRouteProvider(riding: ridingRouteProvider)
        )
        let transitRouteProvider = BundledMetroRouteProvider(
            metroNetworks: metroNetworkProvider,
            walkingRoutes: walkingRouteProvider
        )
        let cityService = CityService()
        let stationSearchService = StationSearchService(
            placeSearchProvider: placeSearchProvider,
            officialStationData: officialStationData,
            metroNetworkProvider: metroNetworkProvider
        )
        let routePlanningService = RoutePlanningService(
            placeSearchProvider: placeSearchProvider,
            routeProvider: transitRouteProvider,
            officialStationData: officialStationData,
            walkingRoutes: walkingRouteProvider,
            officialStationInformation: stationInformationRouter,
            stationInformationDirectory: stationInformationDirectory,
            tripObservations: tripObservationProvider
        )
        let tripMemoryService = TripMemoryService()
        let routeFeasibilityService = RouteFeasibilityService()
        let routeConfidenceService = RouteConfidenceService()
        let tripReminderService = TripReminderService()

        let container = DIContainer(
            locationService: locationService,
            placeSearchProvider: placeSearchProvider,
            officialStationData: officialStationData,
            officialStationInformationProvider: stationInformationRouter,
            stationInformationDirectory: stationInformationDirectory,
            metroNetworkProvider: metroNetworkProvider,
            routePlanningService: routePlanningService,
            baiduMapsClient: baiduClient,
            stationSearchService: stationSearchService,
            cityService: cityService,
            tripMemoryService: tripMemoryService,
            lineObservationProvider: tripObservationProvider,
            routeFeasibilityService: routeFeasibilityService,
            routeConfidenceService: routeConfidenceService,
            tripReminderService: tripReminderService,
            stationInformationDiskCache: stationInformationDiskCache,
            memoryManagedOfficialStationData: officialStationData,
            memoryManagedStationInformationProvider: stationInformationRouter,
            memoryManagedMetroNetworkProvider: metroNetworkProvider,
            memoryManagedTransitRouteProvider: transitRouteProvider,
            memoryManagedTripObservations: tripObservationProvider,
            memoryManagedRidingRoutes: ridingRouteProvider,
            memoryManagedAccessRoutes: walkingRouteProvider
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
