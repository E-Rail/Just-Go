import Foundation
import UIKit

private struct MemoryWarningReleaseTargets: Sendable {
    let officialStationData: OfficialCityPackService?
    let stationInformationProvider: OfficialStationInformationRouter?
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
    let stationInformationDirectory: StationInformationDirectory
    let metroNetworkProvider: MetroNetworkProviding
    let routePlanningService: RoutePlanningService
    let stationSearchService: StationSearchService
    let cityService: CityService
    let tripMemoryService: TripMemoryService
    let routeFeasibilityService: RouteFeasibilityService
    let routeConfidenceService: RouteConfidenceService
    let tripReminderService: TripReminderService
    let stationInformationDiskCache: OfficialStationInformationDiskCache?
    /// Operator notices, fetched on the device and held in memory only. Not in `init` because it
    /// has no configuration and no test seam yet — one city publishes a parseable list.
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
        stationSearchService: StationSearchService,
        cityService: CityService,
        tripMemoryService: TripMemoryService,
        routeFeasibilityService: RouteFeasibilityService,
        routeConfidenceService: RouteConfidenceService,
        tripReminderService: TripReminderService,
        stationInformationDiskCache: OfficialStationInformationDiskCache? = nil,
        memoryManagedOfficialStationData: OfficialCityPackService? = nil,
        memoryManagedStationInformationProvider: OfficialStationInformationRouter? = nil,
        memoryManagedMetroNetworkProvider: BundledMetroNetworkService? = nil,
        memoryManagedTransitRouteProvider: BundledMetroRouteProvider? = nil
    ) {
        self.locationService = locationService
        self.placeSearchProvider = placeSearchProvider
        self.officialStationData = officialStationData
        self.officialStationInformationProvider = officialStationInformationProvider
        self.stationInformationDirectory = stationInformationDirectory
        self.metroNetworkProvider = metroNetworkProvider
        self.routePlanningService = routePlanningService
        self.stationSearchService = stationSearchService
        self.cityService = cityService
        self.tripMemoryService = tripMemoryService
        self.routeFeasibilityService = routeFeasibilityService
        self.routeConfidenceService = routeConfidenceService
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

    @MainActor private var cachedRoutePlannerViewModel: RoutePlannerViewModel?

    /// The one planner the map's whole plan → results → detail chain shares.
    ///
    /// Held here rather than in a `@State` on the map, because the map's navigation router has to
    /// be able to build any of those three screens *synchronously*, at any moment, with no
    /// dependency on whether some `.task` has run yet. When it was optional state, a push that
    /// arrived before that task produced `EmptyView` — a pushed screen with no title and no
    /// content, which is exactly what a blank page is.
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
            cityService: cityService,
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
        let placeSearchProvider = MapKitPlaceSearchProvider()
        let metroNetworkProvider = BundledMetroNetworkService()
        // Dedicated ephemeral sessions (no cookies, no shared cache) instead of `URLSession.shared`
        // — a stuck city-pack/realtime fetch shouldn't serialize behind unrelated shared-session
        // traffic, matching the pattern already used for the Beijing station-info provider.
        let realtimeArrivalProvider = HongKongRealtimeArrivalProvider(session: Self.makeEphemeralSession())
        let stationInformationDiskCache = OfficialStationInformationDiskCache()
        // One provider per source, dispatched by a router. The app decides which source a station
        // uses by reading the bundled Station Information API directory, exactly as a third-party
        // consumer would — no per-city branching at the call sites.
        let stationInformationRouter = OfficialStationInformationRouter(
            beijing: BeijingStationInformationProvider(diskCache: stationInformationDiskCache),
            shanghai: ShanghaiStationInformationProvider(diskCache: stationInformationDiskCache),
            guangzhou: GuangzhouStationInformationProvider(diskCache: stationInformationDiskCache),
            hangzhou: HangzhouStationInformationProvider(diskCache: stationInformationDiskCache)
        )
        let stationInformationDirectory = StationInformationDirectory()
        // The bundled catalog decode + validation is heavy; hand the service a loader so it
        // runs lazily on the actor instead of blocking app launch on the main thread here.
        let officialStationData = OfficialCityPackService(
            session: Self.makeEphemeralSession(),
            metroNetworks: metroNetworkProvider,
            realtimeArrivals: realtimeArrivalProvider,
            officialResourceCatalogLoader: { try .bundled() }
        )
        // One walking-leg builder for both callers: the graph walks to the station, enrichment
        // re-walks to the door it picks. Two instances would be harmless but two implementations
        // would not, so the shared one is passed explicitly rather than defaulted twice.
        let walkingRouteProvider = MapKitWalkingRouteProvider()
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
            walkingRoutes: walkingRouteProvider
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
            stationSearchService: stationSearchService,
            cityService: cityService,
            tripMemoryService: tripMemoryService,
            routeFeasibilityService: routeFeasibilityService,
            routeConfidenceService: routeConfidenceService,
            tripReminderService: tripReminderService,
            stationInformationDiskCache: stationInformationDiskCache,
            memoryManagedOfficialStationData: officialStationData,
            memoryManagedStationInformationProvider: stationInformationRouter,
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
