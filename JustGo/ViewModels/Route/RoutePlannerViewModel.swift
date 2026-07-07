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
    var tripAnchor: TripTimeAnchor = .now {
        didSet { invalidateInFlightSearch() }
    }

    private var suggestionTask: Task<Void, Never>?
    private var routeSearchGeneration = 0
    /// City of the network that produced the current `routes`; nil once any input changes.
    /// The metro provider picks its network by coordinates, so this can differ from
    /// `selectedCity` on seam trips — "Save this trip" persists under this city.
    private(set) var lastPlannedCityID: String?

    /// Persisted app-wide accessibility defaults (the 无障碍 sheet), refreshed by the view
    /// on each appearance. Feeds max-walk warnings and ranking; the chips below override
    /// the mobility flags per-trip. Plain set on purpose — refreshing it must not
    /// invalidate an in-flight search.
    var basePreference: AccessibilityPreference = .default

    // Accessibility filters. A toggle mid-search supersedes the search: its routes were
    // planned with the old filter and must not publish under the new one.
    var requiresWheelchairAccess = false {
        didSet { invalidateInFlightSearch() }
    }
    var requiresElevator = false {
        didSet { invalidateInFlightSearch() }
    }
    var avoidStairs = false {
        didSet { invalidateInFlightSearch() }
    }

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
        invalidateInFlightSearch()
        setName(name, for: field)
        setPlace(nil, for: field)
        updateSuggestions(for: field)
    }

    /// Any input mutation supersedes an in-flight route search: bump the generation so a
    /// slow search's publish/error guards fail, and clear the spinner here — the superseded
    /// search's defer (correctly) refuses to touch it once the token has moved on. Also
    /// voids the planned-city association and any error, both of which described the
    /// previous inputs (a "No Routes Found" alert must not outlive the query it was for).
    private func invalidateInFlightSearch() {
        routeSearchGeneration += 1
        isLoading = false
        lastPlannedCityID = nil
        errorMessage = nil
    }

    /// A successful plan matching the current inputs exists — lastPlannedCityID survives
    /// only while no input has mutated since the publish, so "Save this trip" can trust it.
    var hasCurrentPlan: Bool {
        lastPlannedCityID != nil && !routes.isEmpty
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

    /// `alignCity` lets the caller switch the app to the city the device is actually in
    /// (the view owns that decision) once a coordinate is accepted, before the fill.
    /// Returns whether THIS invocation applied a fill — false on failure, denial, or a
    /// stale-context drop — so flows like quickRoute don't proceed on a leftover origin.
    @discardableResult
    func useCurrentLocation(for field: RouteInputField, alignCity: ((CLLocationCoordinate2D) -> Void)? = nil) async -> Bool {
        // Snapshot the call context: the GPS fix below can take up to 15s, and a fill (or
        // error) landing after the user switched city, edited the field, picked a suggestion,
        // or entered quick-place setup must be dropped, not applied over the newer input.
        var expectedCityID = selectedCity?.id
        var expectedName = name(for: field)
        var expectedPlace = self.place(for: field)
        // Captured, not cleared: "set Home → tap Current Location" must save Home. The save
        // happens through savePendingQuickPlaceIfNeeded once the fix lands.
        let pendingKind = pendingQuickPlaceKind
        // self.place(for:) — the local `place` declared below shadows the method in here.
        func contextUnchanged() -> Bool {
            selectedCity?.id == expectedCityID &&
                name(for: field) == expectedName &&
                self.place(for: field) == expectedPlace &&
                pendingQuickPlaceKind == pendingKind
        }

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
                guard contextUnchanged() else { return false }
                if let locationError = error as? LocationServiceError,
                   locationError == .permissionDenied {
                    errorMessage = userFacingErrorMessage(for: error)
                    return false
                }
                // Last resort once the strict request fails: fall back to a last-known fix so
                // the field still fills, but reject an obviously coarse one (accuracy-relaxed
                // to a city-level bound) rather than seed routing with a km-off origin.
                guard let lastKnown = locationService.currentLocation,
                      lastKnown.horizontalAccuracy >= 0,
                      lastKnown.horizontalAccuracy <= 1000 else {
                    errorMessage = userFacingErrorMessage(for: error)
                    return false
                }
                coordinate = lastKnown.coordinate
            }
        }

        // Align the planner's city to where the device actually is BEFORE filling: the
        // switch wipes the fields (so it must precede the assignment), and the pending
        // quick-place save below must stamp the aligned city, not the one selected before
        // the fix arrived. Re-snapshot afterwards so our own switch (and its field wipe)
        // isn't mistaken for user interference by the guards below.
        if let alignCity {
            guard contextUnchanged() else { return false }
            alignCity(coordinate)
            expectedCityID = selectedCity?.id
            expectedName = name(for: field)
            expectedPlace = self.place(for: field)
        }

        let place: TransitPlace
        do {
            // While saving a quick place, let the geocoder name the spot (street/POI) —
            // a Home tag permanently labeled "Current Location" reads as broken later.
            place = try await placeSearchProvider.reverseGeocode(
                location: coordinate,
                name: pendingKind == nil ? AppLocalization.localized("Current Location") : nil
            ).withSource(.currentLocation)
        } catch {
            place = TransitPlace(
                name: AppLocalization.localized("Current Location"),
                coordinate: coordinate,
                source: .currentLocation
            )
        }
        guard contextUnchanged() else { return false }
        assignPlace(savePendingQuickPlaceIfNeeded(place), for: field)
        return true
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
            // Invalidate any in-flight route search too: its generation guard alone can't
            // see a city change, so a slow city-A plan would publish routes (and save a
            // recent route) under city B.
            invalidateInFlightSearch()
            routes = []
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
        // The association describes the previous plan; void it until this one publishes.
        lastPlannedCityID = nil
        defer { if generation == routeSearchGeneration { isLoading = false } }

        do {
            let planned: [Route]
            // Typed endpoints resolved during planning; written back on success so
            // "Save this trip" snapshots coordinates instead of name-only endpoints.
            var resolvedOrigin: TransitPlace?
            var resolvedDestination: TransitPlace?
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
                resolvedDestination = destination
                planned = try await routePlanningService.planRoute(
                    from: originPlace,
                    to: destination,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case let (nil, destinationPlace?):
                let origin = try await resolveTypedPlace(originName, city: city, field: .origin, generation: generation)
                resolvedOrigin = origin
                planned = try await routePlanningService.planRoute(
                    from: origin,
                    to: destinationPlace,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case (nil, nil):
                // Resolve both names here (concurrently, as the service's name-based path
                // did — same region/limit/first-hit semantics) instead of delegating to it:
                // the service never surfaced its resolutions, so saving after a both-typed
                // search — the recents-replay path — persisted name-only (0,0) endpoints.
                let originQuery = originName.trimmingCharacters(in: .whitespacesAndNewlines)
                let destinationQuery = destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !originQuery.isEmpty, !destinationQuery.isEmpty else {
                    throw RoutePlanningError.stationNotFound
                }
                let region = MKCoordinateRegion(
                    center: city.coordinate,
                    latitudinalMeters: 120_000,
                    longitudinalMeters: 120_000
                )
                // Local so the child tasks capture the provider, not non-Sendable self.
                let provider = placeSearchProvider
                async let originCandidates = provider.searchPlaces(keyword: originQuery, region: region, limit: 8)
                async let destinationCandidates = provider.searchPlaces(keyword: destinationQuery, region: region, limit: 8)
                guard let origin = try await originCandidates.first,
                      let destination = try await destinationCandidates.first else {
                    throw RoutePlanningError.stationNotFound
                }
                guard routeSearchGeneration == generation else { throw CancellationError() }
                resolvedOrigin = origin
                resolvedDestination = destination
                planned = try await routePlanningService.planRoute(
                    from: origin,
                    to: destination,
                    city: city.id,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            }
            guard generation == routeSearchGeneration else { return }
            // The generation still matching proves no input changed since this search
            // started (every mutation bumps it), so the write-back below can't clobber
            // newer user input. setPlace, not assignPlace: assignPlace invalidates, which
            // would supersede this very search and strand the spinner.
            if let resolvedOrigin { setPlace(resolvedOrigin, for: .origin) }
            if let resolvedDestination { setPlace(resolvedDestination, for: .destination) }
            lastPlannedCityID = planned.first?.networkCityID ?? city.id
            routes = planned.map(withMaxWalkWarning)
            sortRoutes()
            if let firstRoute = routes.first {
                // The metro provider picks its network by coordinates, not the selected
                // city — a seam route (Foshan network under a selected Guangzhou) must be
                // saved under the network that actually planned it, or replaying the
                // recent resolves its station names in the wrong city.
                saveRecentRoute(firstRoute, cityID: firstRoute.networkCityID ?? city.id)
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

    var canQuickRouteWork: Bool { quickPlace(for: .company) != nil }

    func quickRoute(to kind: QuickPlaceKind) async {
        // A route shortcut, not a place pick — leave quick-place setup mode so the
        // current-location origin fill below doesn't get consumed as the pending save.
        pendingQuickPlaceKind = nil
        guard let destination = quickPlace(for: kind) else { return }
        // Proceed only when THIS fill applied — a failed/denied/stale-dropped location
        // must not silently route to work from an old origin left in the field.
        guard await useCurrentLocation(for: .origin) else { return }
        useQuickPlace(destination, for: .destination)
        await searchRoutes()
    }

    func swapOriginDestination() {
        invalidateInFlightSearch()
        suggestionTask?.cancel()
        suggestionTask = nil
        swap(&originName, &destinationName)
        swap(&originPlace, &destinationPlace)
    }

    func useRecentRoute(_ recentRoute: RecentRoute) {
        invalidateInFlightSearch()
        suggestionTask?.cancel()
        suggestionTask = nil
        originName = recentRoute.originStationName
        destinationName = recentRoute.destinationStationName
        originPlace = nil
        destinationPlace = nil
        clearSuggestions()
    }

    func useSavedTrip(_ savedTrip: SavedTrip) {
        invalidateInFlightSearch()
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
        var preferences = basePreference
        preferences.requiresWheelchairAccess = requiresWheelchairAccess
        preferences.prefersElevator = requiresElevator
        preferences.avoidStairs = avoidStairs
        return preferences
    }

    /// Flags routes whose total walking exceeds the user's configured maximum (the 无障碍
    /// sheet's slider), replacing the generic fixed-800m long-walk warning with one that
    /// names the user's own limit.
    private func withMaxWalkWarning(_ route: Route) -> Route {
        let limit = basePreference.maxWalkingDistance
        guard limit > 0, route.walkingDistance > limit else { return route }
        var route = route
        route.warnings.removeAll { $0.type == .longWalk }
        route.warnings.append(RouteWarning(
            type: .longWalk,
            message: AppLocalization.text(
                english: "Walking exceeds your \(AppLocalization.distance(limit)) limit",
                simplified: "步行距离超过你设置的\(AppLocalization.distance(limit))上限",
                traditional: "步行距離超過你設定的\(AppLocalization.distance(limit))上限"
            ),
            affectedStationID: nil
        ))
        return route
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
        invalidateInFlightSearch()
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

    private func saveRecentRoute(_ route: Route, cityID: String) {
        let recentRoute = RecentRoute(
            originStationID: route.originStationID,
            originStationName: route.origin,
            destinationStationID: route.destinationStationID,
            destinationStationName: route.destination,
            lineName: route.segments.first(where: { $0.type.isTransit })?.lineName,
            duration: route.formattedDuration,
            plannedDuration: route.totalDuration,
            cityID: cityID
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
        let quickPlace = QuickPlace(kind: kind, place: place, cityID: selectedCity?.id)
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
    /// City the route was planned in; nil on rows saved before this field existed.
    let cityID: String?

    /// Localized at display time from the raw duration so it follows a language switch;
    /// falls back to the legacy stored string for records saved before plannedDuration existed.
    var displayDuration: String {
        if let plannedDuration { return AppLocalization.minutes(Int(plannedDuration / 60)) }
        return duration
    }

    /// The stored city, or one recovered from the station ID for legacy rows — every route
    /// producer builds IDs as "network-<cityID>-<station>", so the middle component is the
    /// city. Returns nil (caller keeps the selected city) when neither source is usable.
    var resolvedCityID: String? {
        if let cityID { return cityID }
        let parts = originStationID.split(separator: "-")
        guard parts.count >= 3, parts[0] == "network" else { return nil }
        return String(parts[1])
    }
}
