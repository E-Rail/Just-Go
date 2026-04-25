import SwiftData
import Foundation

@Observable
final class DIContainer {
    let modelContainer: ModelContainer
    let locationService: LocationService
    let aMapService: AMapServiceProtocol
    let routePlanningService: RoutePlanningService
    let stationSearchService: StationSearchService
    let accessibilityService: AccessibilityService
    let offlineDataManager: OfflineDataManager
    let cityService: CityService

    init(
        modelContainer: ModelContainer,
        locationService: LocationService,
        aMapService: AMapServiceProtocol,
        routePlanningService: RoutePlanningService,
        stationSearchService: StationSearchService,
        accessibilityService: AccessibilityService,
        offlineDataManager: OfflineDataManager,
        cityService: CityService
    ) {
        self.modelContainer = modelContainer
        self.locationService = locationService
        self.aMapService = aMapService
        self.routePlanningService = routePlanningService
        self.stationSearchService = stationSearchService
        self.accessibilityService = accessibilityService
        self.offlineDataManager = offlineDataManager
        self.cityService = cityService
    }

    static func configure() -> DIContainer {
        let schema = Schema([
            Station.self,
            StationAccessibility.self,
            SubwayLine.self,
            FavoriteRoute.self,
            SearchHistory.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        let container = try! ModelContainer(for: schema, configurations: config)

        let locationService = LocationService()
        let aMapService = AMapService()
        let offlineDataManager = OfflineDataManager()
        let accessibilityService = AccessibilityService()
        let stationSearchService = StationSearchService(aMapService: aMapService)
        let routePlanningService = RoutePlanningService(
            aMapService: aMapService,
            offlineEngine: OfflineRouteEngine(),
            offlineDataManager: offlineDataManager
        )
        let cityService = CityService()

        return DIContainer(
            modelContainer: container,
            locationService: locationService,
            aMapService: aMapService,
            routePlanningService: routePlanningService,
            stationSearchService: stationSearchService,
            accessibilityService: accessibilityService,
            offlineDataManager: offlineDataManager,
            cityService: cityService
        )
    }
}
