import Foundation
import UIKit

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
    private let memoryManagedOfficialStationData: OfficialCityPackService?
    private let memoryManagedMetroNetworkProvider: BundledMetroNetworkService?
    private let memoryManagedTransitRouteProvider: BundledMetroRouteProvider?
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
        self.memoryManagedOfficialStationData = memoryManagedOfficialStationData
        self.memoryManagedMetroNetworkProvider = memoryManagedMetroNetworkProvider
        self.memoryManagedTransitRouteProvider = memoryManagedTransitRouteProvider
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    @MainActor
    func installMemoryWarningReleaseHandler() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.memoryManagedOfficialStationData?.releaseMemory()
                await self.memoryManagedMetroNetworkProvider?.releaseMemory()
                await self.memoryManagedTransitRouteProvider?.releaseMemory()
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
            cityService: cityService,
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
