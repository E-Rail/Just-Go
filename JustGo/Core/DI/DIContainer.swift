import Foundation
import UIKit

private struct MemoryWarningReleaseTargets: Sendable {
    let officialStationData: OfficialCityPackService?
    let metroNetworkProvider: BundledMetroNetworkService?
    let transitRouteProvider: BundledMetroRouteProvider?

    func releaseMemory() async {
        await officialStationData?.releaseMemory()
        await metroNetworkProvider?.releaseMemory()
        await transitRouteProvider?.releaseMemory()
    }
}

@Observable
final class DIContainer {
    let locationService: LocationService
    let placeSearchProvider: PlaceSearchProviding
    let officialStationData: OfficialStationDataProviding
    let metroNetworkProvider: MetroNetworkProviding
    let routePlanningService: RoutePlanningService
    let stationSearchService: StationSearchService
    let cityService: CityService
    let tripMemoryService: TripMemoryService
    let accessibilityReportService: AccessibilityReportService
    let routeFeasibilityService: RouteFeasibilityService
    let routeConfidenceService: RouteConfidenceService
    let comfortForecastService: ComfortForecastService
    let tripReminderService: TripReminderService
    private let memoryWarningReleaseTargets: MemoryWarningReleaseTargets
    private var memoryWarningObserver: NSObjectProtocol?

    init(
        locationService: LocationService,
        placeSearchProvider: PlaceSearchProviding,
        officialStationData: OfficialStationDataProviding,
        metroNetworkProvider: MetroNetworkProviding,
        routePlanningService: RoutePlanningService,
        stationSearchService: StationSearchService,
        cityService: CityService,
        tripMemoryService: TripMemoryService,
        accessibilityReportService: AccessibilityReportService,
        routeFeasibilityService: RouteFeasibilityService,
        routeConfidenceService: RouteConfidenceService,
        comfortForecastService: ComfortForecastService,
        tripReminderService: TripReminderService,
        memoryManagedOfficialStationData: OfficialCityPackService? = nil,
        memoryManagedMetroNetworkProvider: BundledMetroNetworkService? = nil,
        memoryManagedTransitRouteProvider: BundledMetroRouteProvider? = nil
    ) {
        self.locationService = locationService
        self.placeSearchProvider = placeSearchProvider
        self.officialStationData = officialStationData
        self.metroNetworkProvider = metroNetworkProvider
        self.routePlanningService = routePlanningService
        self.stationSearchService = stationSearchService
        self.cityService = cityService
        self.tripMemoryService = tripMemoryService
        self.accessibilityReportService = accessibilityReportService
        self.routeFeasibilityService = routeFeasibilityService
        self.routeConfidenceService = routeConfidenceService
        self.comfortForecastService = comfortForecastService
        self.tripReminderService = tripReminderService
        self.memoryWarningReleaseTargets = MemoryWarningReleaseTargets(
            officialStationData: memoryManagedOfficialStationData,
            metroNetworkProvider: memoryManagedMetroNetworkProvider,
            transitRouteProvider: memoryManagedTransitRouteProvider
        )
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
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
        StationDetailViewModel(officialStationData: officialStationData)
    }

    @MainActor
    static func configure() -> DIContainer {
        let locationService = LocationService()
        let placeSearchProvider = MapKitPlaceSearchProvider()
        let metroNetworkProvider = BundledMetroNetworkService()
        let officialStationData = OfficialCityPackService(metroNetworks: metroNetworkProvider)
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
        let accessibilityReportService = AccessibilityReportService()
        let routeFeasibilityService = RouteFeasibilityService()
        let routeConfidenceService = RouteConfidenceService()
        let tripReminderService = TripReminderService()

        let container = DIContainer(
            locationService: locationService,
            placeSearchProvider: placeSearchProvider,
            officialStationData: officialStationData,
            metroNetworkProvider: metroNetworkProvider,
            routePlanningService: routePlanningService,
            stationSearchService: stationSearchService,
            cityService: cityService,
            tripMemoryService: tripMemoryService,
            accessibilityReportService: accessibilityReportService,
            routeFeasibilityService: routeFeasibilityService,
            routeConfidenceService: routeConfidenceService,
            comfortForecastService: comfortForecastService,
            tripReminderService: tripReminderService,
            memoryManagedOfficialStationData: officialStationData,
            memoryManagedMetroNetworkProvider: metroNetworkProvider,
            memoryManagedTransitRouteProvider: transitRouteProvider
        )
        container.installMemoryWarningReleaseHandler()
        return container
    }
}
