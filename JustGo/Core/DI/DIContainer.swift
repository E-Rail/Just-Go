import Foundation

@Observable
final class DIContainer {
    let locationService: LocationService
    let placeSearchProvider: PlaceSearchProviding
    let transitRouteProvider: TransitRouteProviding
    let officialStationData: OfficialStationDataProviding
    let metroNetworkProvider: MetroNetworkProviding
    let routePlanningService: RoutePlanningService
    let stationSearchService: StationSearchService
    let cityService: CityService
    let tripMemoryService: TripMemoryService
    let accessibilityReportService: AccessibilityReportService
    let routeFeasibilityService: RouteFeasibilityService
    let routeConfidenceService: RouteConfidenceService

    init(
        locationService: LocationService,
        placeSearchProvider: PlaceSearchProviding,
        transitRouteProvider: TransitRouteProviding,
        officialStationData: OfficialStationDataProviding,
        metroNetworkProvider: MetroNetworkProviding,
        routePlanningService: RoutePlanningService,
        stationSearchService: StationSearchService,
        cityService: CityService,
        tripMemoryService: TripMemoryService,
        accessibilityReportService: AccessibilityReportService,
        routeFeasibilityService: RouteFeasibilityService,
        routeConfidenceService: RouteConfidenceService
    ) {
        self.locationService = locationService
        self.placeSearchProvider = placeSearchProvider
        self.transitRouteProvider = transitRouteProvider
        self.officialStationData = officialStationData
        self.metroNetworkProvider = metroNetworkProvider
        self.routePlanningService = routePlanningService
        self.stationSearchService = stationSearchService
        self.cityService = cityService
        self.tripMemoryService = tripMemoryService
        self.accessibilityReportService = accessibilityReportService
        self.routeFeasibilityService = routeFeasibilityService
        self.routeConfidenceService = routeConfidenceService
    }

    @MainActor
    static func configure() -> DIContainer {
        let locationService = LocationService()
        let placeSearchProvider = MapKitPlaceSearchProvider()
        let officialStationData = OfficialCityPackService()
        let metroNetworkProvider = BundledMetroNetworkService()
        let transitRouteProvider = BundledMetroRouteProvider(metroNetworks: metroNetworkProvider)
        let cityService = CityService()
        let stationSearchService = StationSearchService(
            placeSearchProvider: placeSearchProvider,
            officialStationData: officialStationData,
            metroNetworkProvider: metroNetworkProvider,
            cityService: cityService
        )
        let routePlanningService = RoutePlanningService(
            placeSearchProvider: placeSearchProvider,
            routeProvider: transitRouteProvider,
            officialStationData: officialStationData,
            cityService: cityService
        )
        let tripMemoryService = TripMemoryService()
        let accessibilityReportService = AccessibilityReportService()
        let routeFeasibilityService = RouteFeasibilityService()
        let routeConfidenceService = RouteConfidenceService()

        return DIContainer(
            locationService: locationService,
            placeSearchProvider: placeSearchProvider,
            transitRouteProvider: transitRouteProvider,
            officialStationData: officialStationData,
            metroNetworkProvider: metroNetworkProvider,
            routePlanningService: routePlanningService,
            stationSearchService: stationSearchService,
            cityService: cityService,
            tripMemoryService: tripMemoryService,
            accessibilityReportService: accessibilityReportService,
            routeFeasibilityService: routeFeasibilityService,
            routeConfidenceService: routeConfidenceService
        )
    }
}
