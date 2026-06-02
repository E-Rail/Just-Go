import Foundation

@Observable
final class DIContainer {
    let locationService: LocationService
    let aMapService: AMapService
    let routePlanningService: RoutePlanningService
    let stationSearchService: StationSearchService
    let cityService: CityService
    let tripMemoryService: TripMemoryService
    let accessibilityReportService: AccessibilityReportService
    let routeFeasibilityService: RouteFeasibilityService

    init(
        locationService: LocationService,
        aMapService: AMapService,
        routePlanningService: RoutePlanningService,
        stationSearchService: StationSearchService,
        cityService: CityService,
        tripMemoryService: TripMemoryService,
        accessibilityReportService: AccessibilityReportService,
        routeFeasibilityService: RouteFeasibilityService
    ) {
        self.locationService = locationService
        self.aMapService = aMapService
        self.routePlanningService = routePlanningService
        self.stationSearchService = stationSearchService
        self.cityService = cityService
        self.tripMemoryService = tripMemoryService
        self.accessibilityReportService = accessibilityReportService
        self.routeFeasibilityService = routeFeasibilityService
    }

    @MainActor
    static func configure() -> DIContainer {
        let locationService = LocationService()
        let aMapService = AMapService()
        let stationSearchService = StationSearchService(aMapService: aMapService)
        let routePlanningService = RoutePlanningService(aMapService: aMapService)
        let cityService = CityService(aMapService: aMapService)
        let tripMemoryService = TripMemoryService()
        let accessibilityReportService = AccessibilityReportService()
        let routeFeasibilityService = RouteFeasibilityService()

        return DIContainer(
            locationService: locationService,
            aMapService: aMapService,
            routePlanningService: routePlanningService,
            stationSearchService: stationSearchService,
            cityService: cityService,
            tripMemoryService: tripMemoryService,
            accessibilityReportService: accessibilityReportService,
            routeFeasibilityService: routeFeasibilityService
        )
    }
}
