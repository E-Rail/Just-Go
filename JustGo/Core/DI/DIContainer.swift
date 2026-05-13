import Foundation

@Observable
final class DIContainer {
    let locationService: LocationService
    let aMapService: AMapService
    let routePlanningService: RoutePlanningService
    let stationSearchService: StationSearchService
    let accessibilityService: AccessibilityService
    let cityService: CityService

    init(
        locationService: LocationService,
        aMapService: AMapService,
        routePlanningService: RoutePlanningService,
        stationSearchService: StationSearchService,
        accessibilityService: AccessibilityService,
        cityService: CityService
    ) {
        self.locationService = locationService
        self.aMapService = aMapService
        self.routePlanningService = routePlanningService
        self.stationSearchService = stationSearchService
        self.accessibilityService = accessibilityService
        self.cityService = cityService
    }

    static func configure() -> DIContainer {
        let locationService = LocationService()
        let aMapService = AMapService()
        let accessibilityService = AccessibilityService()
        let stationSearchService = StationSearchService(aMapService: aMapService)
        let routePlanningService = RoutePlanningService(aMapService: aMapService)
        let cityService = CityService(aMapService: aMapService)

        return DIContainer(
            locationService: locationService,
            aMapService: aMapService,
            routePlanningService: routePlanningService,
            stationSearchService: stationSearchService,
            accessibilityService: accessibilityService,
            cityService: cityService
        )
    }
}
