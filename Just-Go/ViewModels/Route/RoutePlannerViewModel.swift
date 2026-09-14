import Foundation
import CoreLocation
import MapKit

enum RouteInputField: Hashable, Identifiable {
    case origin
    case destination

    // Identifiable so the map picker can be presented with `sheet(item:)`: the field being filled
    // is the sheet's identity.
    var id: Self { self }
}

/// `@MainActor`: it publishes SwiftUI-observed state and reads `LocationService`, which lives on
/// the main actor.
@MainActor
@Observable
final class RoutePlannerViewModel {
    var originName: String = ""
    var destinationName: String = ""
    var originPlace: TransitPlace?
    var destinationPlace: TransitPlace?
    var routes: [Route] = []
    var isLoading = false
    var errorMessage: String?
    var sortStrategy: RoutePreference = UserDefaults.standard.codableValue(forKey: "sortStrategy", as: RoutePreference.self, default: .metroFirst) {
        didSet { UserDefaults.standard.setCodable(sortStrategy, forKey: "sortStrategy") }
    }
    var tripAnchor: TripTimeAnchor = .now {
        didSet { invalidateInFlightSearch() }
    }

    private var routeSearchGeneration = 0
    /// A search published routes and no input has changed since. Cleared by every mutation, so what
    /// is snapshotted is what is on screen.
    private(set) var hasPlannedForCurrentInputs = false

    /// The persisted accessibility defaults (the 无障碍 sheet), refreshed by the view on each
    /// appearance. Feeds max-walk warnings and ranking; the per-trip chips override the mobility
    /// flags. A plain set: refreshing it must not invalidate an in-flight search.
    var basePreference: AccessibilityPreference = .default

    // Accessibility filters. A toggle mid-search supersedes the search: its routes were
    // planned with the old filter and must not publish under the new one.
    var requiresWheelchairAccess = false {
        didSet { routeAffectingSettingsChanged() }
    }
    var requiresElevator = false {
        didSet { routeAffectingSettingsChanged() }
    }
    var avoidStairs = false {
        didSet { routeAffectingSettingsChanged() }
    }

    private let routePlanningService: RoutePlanningService
    private let placeSearchProvider: PlaceSearchProviding
    private let locationService: LocationService
    private var isSyncingAccessibilityPreference = false
    private var syncedDefaultAccessibilitySignature: RouteAffectingAccessibilitySignature?

    init(
        routePlanningService: RoutePlanningService,
        placeSearchProvider: PlaceSearchProviding,
        locationService: LocationService
    ) {
        self.routePlanningService = routePlanningService
        self.placeSearchProvider = placeSearchProvider
        self.locationService = locationService
    }

    var accessibilityFilter: AccessibilityFilter {
        AccessibilityFilter(
            requiresWheelchairAccess: requiresWheelchairAccess,
            requiresElevator: requiresElevator,
            avoidStairs: avoidStairs,
            maxWalkingDistance: basePreference.maxWalkingDistance
        )
    }

    /// Where to bias a place lookup: the other end of the trip when it is resolved, else the
    /// rider's position, else nowhere. If one end is known, the other is near it; a city centroid
    /// would resolve a typed station name in the wrong city.
    private func searchRegion(for field: RouteInputField, radiusMeters: CLLocationDistance) -> MKCoordinateRegion? {
        let other: RouteInputField = field == .origin ? .destination : .origin
        guard let center = place(for: other)?.coordinate ?? locationService.mapSpaceLocation?.coordinate else {
            return nil
        }
        return MKCoordinateRegion(
            center: center,
            latitudinalMeters: radiusMeters,
            longitudinalMeters: radiusMeters
        )
    }

    func name(for field: RouteInputField) -> String {
        field == .origin ? originName : destinationName
    }

    func updateName(_ name: String, for field: RouteInputField) {
        invalidateInFlightSearch()
        setName(name, for: field)
        setPlace(nil, for: field)
    }

    /// Any input change supersedes an in-flight route search: bump the generation so a slow
    /// search's publish and error guards fail, and clear the spinner here (the superseded search's
    /// `defer` will not touch it). Also voids the plan flag and any error, which described the
    /// previous inputs.
    private func invalidateInFlightSearch() {
        routeSearchGeneration += 1
        isLoading = false
        hasPlannedForCurrentInputs = false
        errorMessage = nil
    }

    private func clearCurrentPlan() {
        routes = []
        hasPlannedForCurrentInputs = false
    }

    private func routeAffectingSettingsChanged() {
        guard !isSyncingAccessibilityPreference else { return }
        invalidateInFlightSearch()
        clearCurrentPlan()
    }

    /// Pulls the persisted accessibility defaults into the planner. Returns true when
    /// route-affecting defaults changed while a search/current plan existed, so the view
    /// can pop the stale results screen. Non-route accessibility toggles are ignored here.
    @discardableResult
    func syncAccessibilityPreference(_ preference: AccessibilityPreference) -> Bool {
        let oldSignature = syncedDefaultAccessibilitySignature
        let newSignature = preference.routeAffectingSignature
        let shouldSeedMobilityDefaults = oldSignature.map { !$0.mobilityMatches(newSignature) } ?? true
        let shouldClearCurrentPlan = oldSignature != nil &&
            oldSignature != newSignature &&
            (isLoading || hasCurrentPlan || !routes.isEmpty)

        isSyncingAccessibilityPreference = true
        basePreference = preference
        if shouldSeedMobilityDefaults {
            requiresWheelchairAccess = preference.requiresWheelchairAccess
            requiresElevator = preference.prefersElevator
            avoidStairs = preference.avoidStairs
        }
        isSyncingAccessibilityPreference = false
        syncedDefaultAccessibilitySignature = newSignature

        if shouldClearCurrentPlan {
            invalidateInFlightSearch()
            clearCurrentPlan()
        }
        return shouldClearCurrentPlan
    }

    /// A successful plan matching the current inputs exists.
    var hasCurrentPlan: Bool {
        hasPlannedForCurrentInputs && !routes.isEmpty
    }

    func selectPlace(_ place: TransitPlace, for field: RouteInputField) {
        assignPlace(place, for: field)
    }

    /// Fills one end of the trip from the device, and returns whether this call applied the fill:
    /// false on failure, denial, or when the field changed while the fix was coming. The coordinate
    /// itself comes from `CurrentPlaceResolver`, shared with the search page.
    @discardableResult
    func useCurrentLocation(for field: RouteInputField) async -> Bool {
        // The fix can take up to 15 s. A fill or error landing after the rider edited the field or
        // picked a suggestion is dropped.
        let expectedName = name(for: field)
        let expectedPlace = self.place(for: field)
        // self.place(for:): the local `place` declared below shadows the method in here.
        func contextUnchanged() -> Bool {
            name(for: field) == expectedName && self.place(for: field) == expectedPlace
        }

        let resolver = CurrentPlaceResolver(
            locationService: locationService,
            placeSearchProvider: placeSearchProvider
        )
        let coordinate: CLLocationCoordinate2D
        do {
            coordinate = try await resolver.coordinate()
        } catch {
            guard contextUnchanged() else { return false }
            errorMessage = userFacingErrorMessage(for: error)
            return false
        }

        let place = await resolver.place(at: coordinate)
        guard contextUnchanged() else { return false }
        assignPlace(place, for: field)
        return true
    }

    /// Begin populating the device location in the background when already authorized, so a
    /// later "Current Location" tap fills the field instantly instead of waiting on a fix.
    /// No-op (and no permission prompt) when location access hasn't been granted yet.
    func prewarmLocation() {
        locationService.prewarmLocation()
    }

    /// Returns whether this call published non-empty routes. A superseded or failed search returns
    /// false, so callers act only on the search they own.
    @discardableResult
    func searchRoutes() async -> Bool {
        // Generation guard: a superseded search must not overwrite a newer result or turn the
        // spinner off mid-search.
        routeSearchGeneration += 1
        let generation = routeSearchGeneration
        isLoading = true
        errorMessage = nil
        routes = []
        // The association describes the previous plan; void it until this one publishes.
        hasPlannedForCurrentInputs = false
        defer { if generation == routeSearchGeneration { isLoading = false } }

        do {
            let planned: [Route]
            // Typed ends resolved during planning, written back on success so the planner holds
            // coordinates rather than names.
            var resolvedOrigin: TransitPlace?
            var resolvedDestination: TransitPlace?
            switch (originPlace, destinationPlace) {
            case let (originPlace?, destinationPlace?):
                planned = try await routePlanningService.planRoute(
                    from: originPlace,
                    to: destinationPlace,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case let (originPlace?, nil):
                let destination = try await resolveTypedPlace(destinationName, field: .destination, generation: generation)
                resolvedDestination = destination
                planned = try await routePlanningService.planRoute(
                    from: originPlace,
                    to: destination,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case let (nil, destinationPlace?):
                let origin = try await resolveTypedPlace(originName, field: .origin, generation: generation)
                resolvedOrigin = origin
                planned = try await routePlanningService.planRoute(
                    from: origin,
                    to: destinationPlace,
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            case (nil, nil):
                // Neither end is resolved: resolve both names here, concurrently, so the
                // resolutions can be written back.
                let originQuery = originName.trimmingCharacters(in: .whitespacesAndNewlines)
                let destinationQuery = destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !originQuery.isEmpty, !destinationQuery.isEmpty else {
                    throw RoutePlanningError.stationNotFound
                }
                // Neither end is resolved, so there is nothing to bias against but the rider.
                let region = searchRegion(for: .origin, radiusMeters: 120_000)
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
                    accessibilityFilter: accessibilityFilter,
                    tripAnchor: tripAnchor
                )
            }
            guard generation == routeSearchGeneration else { return false }
            // A matching generation proves no input changed since this search began, so the
            // write-back cannot clobber newer input. `setPlace`, not `assignPlace`, which would
            // invalidate this very search.
            if let resolvedOrigin { setPlace(resolvedOrigin, for: .origin) }
            if let resolvedDestination { setPlace(resolvedDestination, for: .destination) }
            hasPlannedForCurrentInputs = true
            routes = planned.map(withMaxWalkWarning)
            sortRoutes()
            return !routes.isEmpty
        } catch is CancellationError {
            return false
        } catch {
            guard generation == routeSearchGeneration else { return false }
            errorMessage = userFacingErrorMessage(for: error)
            return false
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

    func swapOriginDestination() {
        invalidateInFlightSearch()
        swap(&originName, &destinationName)
        swap(&originPlace, &destinationPlace)
    }

    private var accessibilityPreferences: AccessibilityPreference {
        var preferences = basePreference
        preferences.requiresWheelchairAccess = requiresWheelchairAccess
        preferences.prefersElevator = requiresElevator
        preferences.avoidStairs = avoidStairs
        return preferences
    }

    /// Flags routes whose walking exceeds the rider's own limit (the 无障碍 sheet's slider), replacing
    /// the generic long-walk warning with one that names that limit.
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

    private func resolveTypedPlace(_ name: String, field: RouteInputField, generation: Int) async throws -> TransitPlace {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw RoutePlanningError.stationNotFound }
        let region = searchRegion(for: field, radiusMeters: 120_000)
        guard let place = try await placeSearchProvider.searchPlaces(keyword: query, region: region, limit: 8).first else {
            throw RoutePlanningError.stationNotFound
        }
        guard routeSearchGeneration == generation,
              self.name(for: field).trimmingCharacters(in: .whitespacesAndNewlines) == query,
              self.place(for: field) == nil else {
            throw CancellationError()
        }
        return place
    }

    private func assignPlace(_ place: TransitPlace, for field: RouteInputField) {
        invalidateInFlightSearch()
        setPlace(place, for: field)
        setName(place.name, for: field)
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

    func place(for field: RouteInputField) -> TransitPlace? {
        field == .origin ? originPlace : destinationPlace
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
