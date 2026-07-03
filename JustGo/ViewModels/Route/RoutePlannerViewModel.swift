import Foundation
import CoreLocation
import MapKit

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
    var sortStrategy: RoutePreference = UserDefaults.standard.codableValue(forKey: "sortStrategy", as: RoutePreference.self, default: .metroFirst) {
        didSet { UserDefaults.standard.setCodable(sortStrategy, forKey: "sortStrategy") }
    }
    var tripAnchor: TripTimeAnchor = .now

    private var suggestionTask: Task<Void, Never>?
    private var routeSearchGeneration = 0

    // Accessibility filters
    var requiresWheelchairAccess = false
    var requiresElevator = false
    var avoidStairs = false

    private let routePlanningService: RoutePlanningService
    private let placeSearchProvider: PlaceSearchProviding
    private let locationService: LocationService
    private let recentRoutesKey = "recentRoutes"
    private let quickPlacesKey = "quickPlaces"
    private var quickPlacesResetObserver: NSObjectProtocol?

    init(
        routePlanningService: RoutePlanningService,
        placeSearchProvider: PlaceSearchProviding,
        locationService: LocationService
    ) {
        self.routePlanningService = routePlanningService
        self.placeSearchProvider = placeSearchProvider
        self.locationService = locationService
        recentRoutes = UserDefaults.standard.codableValue(forKey: recentRoutesKey, as: [RecentRoute].self, default: [])
        quickPlaces = UserDefaults.standard.codableValue(forKey: quickPlacesKey, as: [QuickPlace].self, default: [])
        quickPlacesResetObserver = NotificationCenter.default.addObserver(forName: .quickPlacesDidReset, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            if let kind = notification.object as? QuickPlaceKind {
                self.quickPlaces.removeAll { $0.kind == kind }
                if self.pendingQuickPlaceKind == kind {
                    self.pendingQuickPlaceKind = nil
                }
            } else {
                self.quickPlaces = []
                self.pendingQuickPlaceKind = nil
            }
        }
    }

    deinit {
        suggestionTask?.cancel()
        if let observer = quickPlacesResetObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func removeQuickPlace(_ kind: QuickPlaceKind) {
        quickPlaces.removeAll { $0.kind == kind }
        UserDefaults.standard.setCodable(quickPlaces, forKey: quickPlacesKey)
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

    func useQuickPlace(_ quickPlace: QuickPlace, for field: RouteInputField) {
        pendingQuickPlaceKind = nil
        assignPlace(quickPlace.transitPlace, for: field)
    }

    func useCurrentLocation(for field: RouteInputField) async {
        pendingQuickPlaceKind = nil

        let coordinate: CLLocationCoordinate2D
        if let recent = locationService.currentLocation,
           recent.horizontalAccuracy >= 0,
           recent.horizontalAccuracy <= 100,
           abs(recent.timestamp.timeIntervalSinceNow) <= 120 {
            // A recent, sufficiently accurate fix (e.g. from pre-warming when the planner
            // appeared) is good enough for a route origin — use it immediately instead of
            // waiting on a fresh fix that can stall indoors / on weak GPS / in the simulator.
            // The ≤120s window is intentionally looser than requestCurrentLocation's 30s so a
            // just-prewarmed fix fills instantly; the accuracy gate is what keeps it safe.
            coordinate = recent.coordinate
        } else {
            do {
                coordinate = try await locationService.requestCurrentLocation().coordinate
            } catch {
                if let locationError = error as? LocationServiceError,
                   locationError == .permissionDenied {
                    errorMessage = userFacingErrorMessage(for: error)
                    return
                }
                // Last resort once the strict request fails: fall back to a last-known fix so
                // the field still fills, but reject an obviously coarse one (accuracy-relaxed
                // to a city-level bound) rather than seed routing with a km-off origin.
                guard let lastKnown = locationService.currentLocation,
                      lastKnown.horizontalAccuracy >= 0,
                      lastKnown.horizontalAccuracy <= 1000 else {
                    errorMessage = userFacingErrorMessage(for: error)
                    return
                }
                coordinate = lastKnown.coordinate
            }
        }

        let place: TransitPlace
        do {
            place = try await placeSearchProvider.reverseGeocode(
                location: coordinate,
                name: AppLocalization.localized("Current Location")
            ).withSource(.currentLocation)
        } catch {
            place = TransitPlace(
                name: AppLocalization.localized("Current Location"),
                coordinate: coordinate,
                source: .currentLocation
            )
        }
        assignPlace(place, for: field)
    }

    /// Begin populating the device location in the background when already authorized, so a
    /// later "Current Location" tap fills the field instantly instead of waiting on a fix.
    /// No-op (and no permission prompt) when location access hasn't been granted yet.
    func prewarmLocation() {
        locationService.prewarmLocation()
    }

    func cityChanged(to city: City?) {
        let cityActuallyChanged = city?.id != selectedCity?.id
        selectedCity = city
        if cityActuallyChanged {
            // Only reset the resolved places + typed names when the city truly changes. This
            // runs on every planner re-appearance (tab switch); wiping the places unconditionally
            // would silently drop a station the user already picked and force a redundant
            // geocode (which fails offline) on the next search.
            originPlace = nil
            destinationPlace = nil
            originName = ""
            destinationName = ""
        }
        suggestionTask?.cancel()
        suggestionTask = nil
        clearSuggestions()
    }

    func searchRoutes() async {
        guard let city = selectedCity else { return }

        // Generation guard: a second search (e.g. a stray tap during a quick-route location
        // fetch, while isLoading is still false) must not let a slower, superseded result
        // overwrite the newest one or flip the spinner off mid-search.
        routeSearchGeneration += 1
        let generation = routeSearchGeneration
        isLoading = true
        errorMessage = nil
        routes = []
        defer { if generation == routeSearchGeneration { isLoading = false } }

        do {
            let planned: [Route]
            switch (originPlace, destinationPlace) {
            case let (originPlace?, destinationPlace?):
                planned = try await routePlanningService.planRoute(
                    from: originPlace,
                    to: destinationPlace,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case let (originPlace?, nil):
                let destination = try await resolveTypedPlace(destinationName, city: city, field: .destination, generation: generation)
                planned = try await routePlanningService.planRoute(
                    from: originPlace,
                    to: destination,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case let (nil, destinationPlace?):
                let origin = try await resolveTypedPlace(originName, city: city, field: .origin, generation: generation)
                planned = try await routePlanningService.planRoute(
                    from: origin,
                    to: destinationPlace,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case (nil, nil):
                planned = try await routePlanningService.planRoute(
                    from: originName,
                    to: destinationName,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            }
            guard generation == routeSearchGeneration else { return }
            routes = planned
            sortRoutes()
            if let firstRoute = routes.first {
                saveRecentRoute(firstRoute)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == routeSearchGeneration else { return }
            errorMessage = userFacingErrorMessage(for: error)
        }
    }

    func sortRoutes() {
        routes = routePlanningService.sortRoutes(
            routes,
            by: sortStrategy,
            preferences: accessibilityPreferences,
            tripAnchor: tripAnchor
        )
    }

    /// "Leave by / arrive by" plan for a route. Derived from the route's plan-time
    /// `serviceStatus` so the list and the detail screen always show the same verdict.
    func departurePlan(for route: Route) -> DeparturePlan? {
        route.departurePlan(anchor: tripAnchor)
    }

    func tripTimeContext(for route: Route) -> TripTimeContext {
        TripTimeContext(anchor: tripAnchor, totalDuration: route.totalDuration)
    }

    var canQuickRouteHome: Bool { quickPlace(for: .home) != nil }
    var canQuickRouteWork: Bool { quickPlace(for: .company) != nil }

    func quickRoute(to kind: QuickPlaceKind) async {
        guard let destination = quickPlace(for: kind) else { return }
        await useCurrentLocation(for: .origin)
        guard originPlace != nil else { return }
        useQuickPlace(destination, for: .destination)
        await searchRoutes()
    }

    func swapOriginDestination() {
        suggestionTask?.cancel()
        suggestionTask = nil
        swap(&originName, &destinationName)
        swap(&originPlace, &destinationPlace)
    }

    func useRecentRoute(_ recentRoute: RecentRoute) {
        suggestionTask?.cancel()
        suggestionTask = nil
        originName = recentRoute.originStationName
        destinationName = recentRoute.destinationStationName
        originPlace = nil
        destinationPlace = nil
        clearSuggestions()
    }

    func useSavedTrip(_ savedTrip: SavedTrip) {
        suggestionTask?.cancel()
        suggestionTask = nil
        originName = savedTrip.origin.name
        destinationName = savedTrip.destination.name
        originPlace = savedTrip.origin.hasUsableRouteCoordinate ? savedTrip.origin.transitPlace : nil
        destinationPlace = savedTrip.destination.hasUsableRouteCoordinate ? savedTrip.destination.transitPlace : nil
        requiresWheelchairAccess = savedTrip.accessibilityFilter.requiresWheelchairAccess
        requiresElevator = savedTrip.accessibilityFilter.requiresElevator
        avoidStairs = savedTrip.accessibilityFilter.avoidStairs
        if let preferredPreference = savedTrip.preferredRoutePreference {
            sortStrategy = preferredPreference
        } else if let preferredStrategy = savedTrip.preferredStrategy {
            sortStrategy = RoutePreference(routeStrategy: preferredStrategy)
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
        let cityID = city.id

        // [weak self]: MKLocalSearch (behind placeSearchProvider) is known to ignore Swift
        // task cancellation elsewhere in this codebase, so a superseded keystroke's search
        // keeps running in the background — a strong self capture here would pin the whole
        // view model alive for as long as that stale network call takes to resolve.
        suggestionTask = Task { [weak self, placeSearchProvider] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let region = MKCoordinateRegion(
                    center: city.coordinate,
                    latitudinalMeters: 80_000,
                    longitudinalMeters: 80_000
                )
                let suggestions = try await placeSearchProvider.searchPlaces(keyword: keyword, region: region, limit: 8)
                guard let self,
                      !Task.isCancelled,
                      selectedCity?.id == cityID,
                      name(for: field) == keyword,
                      place(for: field) == nil else { return }
                setSuggestions(suggestions, for: field)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      selectedCity?.id == cityID,
                      name(for: field) == keyword,
                      place(for: field) == nil else { return }
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

    private func resolveTypedPlace(_ name: String, city: City, field: RouteInputField, generation: Int) async throws -> TransitPlace {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw RoutePlanningError.stationNotFound }
        let region = MKCoordinateRegion(
            center: city.coordinate,
            latitudinalMeters: 120_000,
            longitudinalMeters: 120_000
        )
        guard let place = try await placeSearchProvider.searchPlaces(keyword: query, region: region, limit: 8).first else {
            throw RoutePlanningError.stationNotFound
        }
        guard routeSearchGeneration == generation,
              selectedCity?.id == city.id,
              self.name(for: field).trimmingCharacters(in: .whitespacesAndNewlines) == query,
              self.place(for: field) == nil else {
            throw CancellationError()
        }
        return place
    }

    private func assignPlace(_ place: TransitPlace, for field: RouteInputField) {
        suggestionTask?.cancel()
        suggestionTask = nil
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

    private func place(for field: RouteInputField) -> TransitPlace? {
        field == .origin ? originPlace : destinationPlace
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
            lineName: route.segments.first(where: { $0.type.isTransit })?.lineName,
            duration: route.formattedDuration,
            plannedDuration: route.totalDuration
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
    let plannedDuration: TimeInterval?

    /// Localized at display time from the raw duration so it follows a language switch;
    /// falls back to the legacy stored string for records saved before plannedDuration existed.
    var displayDuration: String {
        if let plannedDuration { return AppLocalization.minutes(Int(plannedDuration / 60)) }
        return duration
    }
}
