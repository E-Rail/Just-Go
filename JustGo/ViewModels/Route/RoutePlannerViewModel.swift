import Foundation
import CoreLocation

enum RouteInputField: Hashable {
    case origin
    case destination
}

@Observable
final class RoutePlannerViewModel {
    var originName: String = ""
    var destinationName: String = ""
    var originPlace: TransitPlace?
    var destinationPlace: TransitPlace?
    var originSuggestions: [TransitPlace] = []
    var destinationSuggestions: [TransitPlace] = []
    var selectedCity: City?
    var routes: [Route] = []
    var recentRoutes: [RecentRoute] = []
    var quickPlaces: [QuickPlace] = []
    var pendingQuickPlaceKind: QuickPlaceKind?
    var isLoading = false
    var errorMessage: String?
    var sortStrategy: RouteSortStrategy = .metroFirst

    private var suggestionTask: Task<Void, Never>?

    // Accessibility filters
    var requiresWheelchairAccess = false
    var requiresElevator = false
    var avoidStairs = false

    private let routePlanningService: RoutePlanningService
    private let aMapService: AMapService
    private let locationService: LocationService
    private let recentRoutesKey = "recentRoutes"
    private let quickPlacesKey = "quickPlaces"

    init(
        routePlanningService: RoutePlanningService,
        aMapService: AMapService,
        locationService: LocationService
    ) {
        self.routePlanningService = routePlanningService
        self.aMapService = aMapService
        self.locationService = locationService
        recentRoutes = UserDefaults.standard.codableValue(forKey: recentRoutesKey, as: [RecentRoute].self, default: [])
        quickPlaces = UserDefaults.standard.codableValue(forKey: quickPlacesKey, as: [QuickPlace].self, default: [])
    }

    var accessibilityFilter: AccessibilityFilter {
        AccessibilityFilter(
            requiresWheelchairAccess: requiresWheelchairAccess,
            requiresElevator: requiresElevator,
            avoidStairs: avoidStairs
        )
    }

    var canSearch: Bool {
        !originName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !destinationName.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedCity != nil
    }

    func name(for field: RouteInputField) -> String {
        field == .origin ? originName : destinationName
    }

    func suggestions(for field: RouteInputField?) -> [TransitPlace] {
        guard let field else { return [] }
        return field == .origin ? originSuggestions : destinationSuggestions
    }

    func updateName(_ name: String, for field: RouteInputField) {
        setName(name, for: field)
        setPlace(nil, for: field)
        updateSuggestions(for: field)
    }

    func selectPlace(_ place: TransitPlace, for field: RouteInputField) {
        assignPlace(savePendingQuickPlaceIfNeeded(place), for: field)
    }

    func quickPlace(for kind: QuickPlaceKind) -> QuickPlace? {
        quickPlaces.first { $0.kind == kind }
    }

    func beginSavingQuickPlace(_ kind: QuickPlaceKind) {
        pendingQuickPlaceKind = kind
    }

    func clearPendingQuickPlace() {
        pendingQuickPlaceKind = nil
    }

    func useQuickPlace(_ quickPlace: QuickPlace, for field: RouteInputField) {
        pendingQuickPlaceKind = nil
        assignPlace(quickPlace.transitPlace, for: field)
    }

    func useCurrentLocation(for field: RouteInputField) async {
        pendingQuickPlaceKind = nil

        do {
            let location = try await locationService.requestCurrentLocation()
            let coordinate = location.coordinate
            let place = try await aMapService.reverseGeocode(
                location: coordinate,
                name: AppLocalization.localized("Current Location")
            ).withSource(.currentLocation)

            assignPlace(place, for: field)
        } catch {
            errorMessage = userFacingErrorMessage(for: error)
        }
    }

    func cityChanged(to city: City?) {
        selectedCity = city
        originPlace = nil
        destinationPlace = nil
        clearSuggestions()
    }

    func searchRoutes() async {
        guard let city = selectedCity else { return }

        isLoading = true
        errorMessage = nil
        routes = []
        defer { isLoading = false }

        do {
            if let originPlace, let destinationPlace {
                routes = try await routePlanningService.planRoute(
                    from: originPlace,
                    to: destinationPlace,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter
                )
            } else {
                routes = try await routePlanningService.planRoute(
                    from: originName,
                    to: destinationName,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter
                )
            }
            sortRoutes()
            if let firstRoute = routes.first {
                saveRecentRoute(firstRoute)
            }
        } catch {
            errorMessage = userFacingErrorMessage(for: error)
        }
    }

    func sortRoutes() {
        routes = routePlanningService.sortRoutes(
            routes,
            by: sortStrategy,
            preferences: accessibilityPreferences
        )
    }

    func swapOriginDestination() {
        swap(&originName, &destinationName)
        swap(&originPlace, &destinationPlace)
    }

    func useRecentRoute(_ recentRoute: RecentRoute) {
        originName = recentRoute.originStationName
        destinationName = recentRoute.destinationStationName
        originPlace = nil
        destinationPlace = nil
        clearSuggestions()
    }

    func useSavedTrip(_ savedTrip: SavedTrip) {
        originName = savedTrip.origin.name
        destinationName = savedTrip.destination.name
        originPlace = savedTrip.origin.hasUsableRouteCoordinate ? savedTrip.origin.transitPlace : nil
        destinationPlace = savedTrip.destination.hasUsableRouteCoordinate ? savedTrip.destination.transitPlace : nil
        requiresWheelchairAccess = savedTrip.accessibilityFilter.requiresWheelchairAccess
        requiresElevator = savedTrip.accessibilityFilter.requiresElevator
        avoidStairs = savedTrip.accessibilityFilter.avoidStairs
        if let preferredStrategy = savedTrip.preferredStrategy {
            sortStrategy = RouteSortStrategy(routeStrategy: preferredStrategy)
        }
        clearSuggestions()
    }

    func originSnapshot() -> TransitPlaceSnapshot? {
        if let originPlace {
            return TransitPlaceSnapshot(place: originPlace)
        }
        let trimmed = originName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : TransitPlaceSnapshot(name: trimmed)
    }

    func destinationSnapshot() -> TransitPlaceSnapshot? {
        if let destinationPlace {
            return TransitPlaceSnapshot(place: destinationPlace)
        }
        let trimmed = destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : TransitPlaceSnapshot(name: trimmed)
    }

    func deleteRecentRoutes(at offsets: IndexSet) {
        recentRoutes.remove(atOffsets: offsets)
        UserDefaults.standard.setCodable(recentRoutes, forKey: recentRoutesKey)
    }

    private var accessibilityPreferences: AccessibilityPreference {
        var preferences = AccessibilityPreference.default
        preferences.requiresWheelchairAccess = requiresWheelchairAccess
        preferences.prefersElevator = requiresElevator
        preferences.avoidStairs = avoidStairs
        return preferences
    }

    private func updateSuggestions(for field: RouteInputField) {
        suggestionTask?.cancel()

        guard let city = selectedCity else {
            clearSuggestions(for: field)
            return
        }

        let keyword = name(for: field)
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSuggestions(for: field)
            return
        }

        suggestionTask = Task { [aMapService] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let suggestions = try await aMapService.inputTips(keyword: keyword, city: city.id, limit: 8)
                guard !Task.isCancelled else { return }
                setSuggestions(suggestions, for: field)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = userFacingErrorMessage(for: error)
            }
        }
    }

    private func clearSuggestions(for field: RouteInputField) {
        setSuggestions([], for: field)
    }

    private func clearSuggestions() {
        originSuggestions = []
        destinationSuggestions = []
    }

    private func assignPlace(_ place: TransitPlace, for field: RouteInputField) {
        setPlace(place, for: field)
        setName(place.name, for: field)
        clearSuggestions(for: field)
    }

    private func setName(_ name: String, for field: RouteInputField) {
        if field == .origin {
            originName = name
        } else {
            destinationName = name
        }
    }

    private func setPlace(_ place: TransitPlace?, for field: RouteInputField) {
        if field == .origin {
            originPlace = place
        } else {
            destinationPlace = place
        }
    }

    private func setSuggestions(_ suggestions: [TransitPlace], for field: RouteInputField) {
        if field == .origin {
            originSuggestions = suggestions
        } else {
            destinationSuggestions = suggestions
        }
    }

    private func saveRecentRoute(_ route: Route) {
        let recentRoute = RecentRoute(
            originStationID: route.originStationID,
            originStationName: route.origin,
            destinationStationID: route.destinationStationID,
            destinationStationName: route.destination,
            lineName: route.segments.first(where: { $0.type == .subway })?.lineName,
            duration: route.formattedDuration
        )

        var routes = recentRoutes.filter {
            !($0.originStationID == recentRoute.originStationID && $0.destinationStationID == recentRoute.destinationStationID)
        }
        routes.insert(recentRoute, at: 0)
        recentRoutes = Array(routes.prefix(10))
        UserDefaults.standard.setCodable(recentRoutes, forKey: recentRoutesKey)
    }

    private func savePendingQuickPlaceIfNeeded(_ place: TransitPlace) -> TransitPlace {
        guard let kind = pendingQuickPlaceKind else { return place }
        let quickPlace = QuickPlace(kind: kind, place: place)
        quickPlaces.removeAll { $0.kind == kind }
        quickPlaces.append(quickPlace)
        quickPlaces.sort { $0.kind.rawValue < $1.kind.rawValue }
        UserDefaults.standard.setCodable(quickPlaces, forKey: quickPlacesKey)
        pendingQuickPlaceKind = nil
        return quickPlace.transitPlace
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        if let routeError = error as? RoutePlanningError {
            return routeError.localizedDescription
        }

        if error is DecodingError {
            return AppLocalization.localized("Route data format changed. Please try again later.")
        }

        return (error as? LocalizedError)?.errorDescription ??
            AppLocalization.localized("Network connection failed. Try again later.")
    }
}

struct RecentRoute: Identifiable, Codable {
    var id: String {
        "\(originStationID)-\(destinationStationID)"
    }

    let originStationID: String
    let originStationName: String
    let destinationStationID: String
    let destinationStationName: String
    let lineName: String?
    let duration: String
}
