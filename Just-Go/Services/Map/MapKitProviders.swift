import CoreLocation
import MapKit

struct MapKitTimeoutError: Error {}

/// Something MapKit will stop when told to: `MKDirections`, `MKLocalSearch` and `CLGeocoder` each
/// have a `cancel()`, and none observes Swift task cancellation. `@unchecked Sendable` with a lock,
/// like `SessionTaskBox`: the deadline and the operation are different tasks.
final class MapKitOperationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    func cancelOperation() {
        lock.lock()
        let work = cancel
        cancel = nil
        lock.unlock()
        work?()
    }

    /// Releases the closure once the operation has finished on its own, so the captured MapKit
    /// object is not held alive by a deadline that no longer matters.
    func finish() {
        lock.lock()
        cancel = nil
        lock.unlock()
    }
}

/// Races `operation` against a deadline so a stalled MapKit call cannot hang a spinner. The `box`
/// is the mechanism: a task group cannot return while a child runs, `cancelAll()` only marks
/// children, and these completion-handler APIs ignore task cancellation. Calling the operation's
/// own `cancel()` is what makes the deadline real.
func withMapKitTimeout<T: Sendable>(
    seconds: TimeInterval = 12,
    box: MapKitOperationBox,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            defer { box.finish() }
            return try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            box.cancelOperation()
            throw MapKitTimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw MapKitTimeoutError()
        }
        return result
    }
}

protocol PlaceSearchProviding {
    func searchPlaces(keyword: String, region: MKCoordinateRegion?, limit: Int) async throws -> [TransitPlace]
    func reverseGeocode(location: CLLocationCoordinate2D, name: String?) async throws -> TransitPlace
}

/// "Where I am", as somewhere a trip can start from, shared by the planner and the search page so
/// its four-branch fallback exists once: a fresh cached fix, a live request, a coarser last-known
/// fix, and a reverse geocode that may fail on its own.
struct CurrentPlaceResolver {
    let locationService: LocationService
    let placeSearchProvider: PlaceSearchProviding

    /// A fix good enough to route from, already in the map's coordinate frame. Throws rather than
    /// returning nil, because "not allowed" and "never arrived" need different words on screen.
    /// `@MainActor` because every branch reads `LocationService` state.
    @MainActor
    func coordinate() async throws -> CLLocationCoordinate2D {
        if let recent = locationService.currentLocation,
           recent.horizontalAccuracy >= 0,
           recent.horizontalAccuracy <= 100,
           abs(recent.timestamp.timeIntervalSinceNow) <= 120 {
            // A recent, accurate fix (from pre-warming, say) is good enough for an origin and
            // avoids a fresh request that can stall indoors. The 120 s window is looser than
            // `requestCurrentLocation`'s 30 s; the accuracy gate keeps it safe.
            return locationService.mapSpaceCoordinate(from: recent.coordinate)
        }

        do {
            let fix = try await locationService.requestCurrentLocation()
            return locationService.mapSpaceCoordinate(from: fix.coordinate)
        } catch {
            if let locationError = error as? LocationServiceError, locationError == .permissionDenied {
                throw error
            }
            // Last resort: a last-known fix, relaxed only to city-level accuracy, so the field
            // fills without seeding a route kilometres off.
            guard let lastKnown = locationService.currentLocation,
                  lastKnown.horizontalAccuracy >= 0,
                  lastKnown.horizontalAccuracy <= 1000 else {
                throw error
            }
            return locationService.mapSpaceCoordinate(from: lastKnown.coordinate)
        }
    }

    /// Names the coordinate. A failed reverse-geocode is not a failed locate. The rider still
    /// gets a start they can route from, just labelled generically.
    func place(at coordinate: CLLocationCoordinate2D) async -> TransitPlace {
        do {
            return try await placeSearchProvider.reverseGeocode(
                location: coordinate,
                name: AppLocalization.localized("Current Location")
            ).withSource(.currentLocation)
        } catch {
            return TransitPlace(
                name: AppLocalization.localized("Current Location"),
                coordinate: coordinate,
                source: .currentLocation
            )
        }
    }

    func place() async throws -> TransitPlace {
        await place(at: try await coordinate())
    }
}

/// One direction of one line that has stopped running when the rider would board it. A direction,
/// not a line: at 天通苑南 on 5号线 the southbound last train is 22:51 and the northbound 23:57, and
/// banning the line would throw away a train still running late at night.
///
/// Carried as one oriented hop the service makes, so the graph can order any pattern against it
/// with no vocabulary shared with the operator that supplied the verdict.
struct ClosedServiceDirection: Hashable, Sendable {
    let lineID: String
    /// Qualified (`network-<city>-<station>`) IDs, so a caller holding a route's own leg context can
    /// build one without reaching into the graph's internal identifiers.
    let fromStationID: String
    let toStationID: String
}

protocol TransitRouteProviding {
    /// - Parameter excludingServices: line directions the caller has established are not running
    /// when this rider would board them. The graph is time-blind by design; this is how the
    /// conclusion of a timetable reaches it without the graph reading one.
    func routes(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter,
        excludingServices: Set<ClosedServiceDirection>
    ) async throws -> [Route]
}

/// Builds one walking leg, for both the graph (to the station) and `RoutePlanningService` (to the
/// door it picks), so the numbers riders read come from one implementation.
protocol WalkingRouteProviding {
    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment?

    /// The same leg by whichever mode its length calls for; the other modes' caveats are on their
    /// implementations.
    func accessSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String,
        mode: AccessLegMode
    ) async -> RouteSegment?
}

final class MapKitWalkingRouteProvider: WalkingRouteProviding {
    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        let directDistance = from.distance(to: to)
        guard directDistance >= 10 else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .walking
        let mapRoute: MKRoute?
        do {
            let directions = MKDirections(request: request)
            mapRoute = try await withMapKitTimeout(box: MapKitOperationBox { directions.cancel() }) {
                try await directions.calculate().routes.first
            }
        } catch {
            AppLog.routing.info("Walking directions unavailable, using straight-line estimate: \(error)")
            mapRoute = nil
        }
        let distance = mapRoute?.distance ?? directDistance
        let duration = mapRoute?.expectedTravelTime ?? distance / 1.25
        let steps = mapRoute?.steps.filter { $0.distance >= 10 || !$0.instructions.isEmpty }.map {
            WalkingStep(
                instruction: AppLocalization.isChinese ? "" : $0.instructions,
                distance: $0.distance,
                duration: max(1, duration * ($0.distance / max(distance, 1))),
                isAccessible: !$0.instructions.localizedCaseInsensitiveContains("stairs"),
                road: nil,
                action: nil,
                assistantAction: nil,
                walkType: nil
            )
        } ?? [WalkingStep(
            instruction: AppLocalization.text(
                english: "Walk from \(fromName) to \(toName)",
                simplified: "从\(fromName)步行至\(toName)",
                traditional: "從\(fromName)步行至\(toName)"
            ),
            distance: distance,
            duration: duration,
            isAccessible: true,
            road: nil,
            action: nil,
            assistantAction: nil,
            walkType: nil
        )]
        return RouteSegment(
            id: UUID(),
            type: .walking,
            lineName: nil,
            lineColorHex: nil,
            fromStationName: fromName,
            toStationName: toName,
            fromStationID: nil,
            toStationID: nil,
            duration: duration,
            distance: distance,
            stops: 0,
            stationStops: [],
            polylineCoordinates: mapRoute?.polyline.routeCoordinates.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) } ?? [],
            walkingDirections: steps,
            accessibilityNotes: mapRoute == nil ? [AppLocalization.localized("Walking distance is estimated")] : []
        )
    }

    func accessSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String,
        mode: AccessLegMode
    ) async -> RouteSegment? {
        switch mode {
        case .walking:
            return await walkingSegment(from: from, to: to, fromName: fromName, toName: toName)
        case .cycling:
            return await cyclingSegment(from: from, to: to, fromName: fromName, toName: toName)
        case .driving:
            return await drivingSegment(from: from, to: to, fromName: fromName, toName: toName)
        }
    }

    /// A bike ride along the **walking** route, re-timed, used where no cycling router is
    /// available: MapKit has no cycling transport type, and `.transit` refuses to calculate
    /// (`MKErrorDomain` 5). The leg says it is the pedestrian shape.
    ///
    /// Where Apple's steps name stairs, the leg keeps the walking duration and carries the warning
    /// instead of promising 14 km/h over a staircase.
    private func cyclingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        guard let walk = await walkingSegment(from: from, to: to, fromName: fromName, toName: toName) else {
            return nil
        }
        let steps = walk.walkingDirections ?? []
        let hasStairs = steps.contains(where: \.hasStairs)
        var notes = walk.accessibilityNotes
        notes.append(AppLocalization.text(
            english: "Follows the walking route. No cycling directions are published.",
            simplified: "沿步行路线绘制，没有可用的骑行导航数据。",
            traditional: "沿步行路線繪製，沒有可用的騎行導航資料。"
        ))
        if hasStairs {
            notes.append(AppLocalization.text(
                english: "This route includes stairs. You may have to walk the bike.",
                simplified: "此路线含台阶，可能需要推行。",
                traditional: "此路線含階梯，可能需要推行。"
            ))
        }
        // 14 km/h: a shared bike in city traffic, slow enough that a faster rider is early rather
        // than late. Not applied where stairs were named.
        let duration = hasStairs ? walk.duration : walk.distance / Self.cyclingMetresPerSecond
        return walk.retyped(as: .cycling, duration: duration, accessibilityNotes: notes)
    }

    /// A real driving route from MapKit, measured rather than derived. Falls back to the walking
    /// leg when MapKit declines: a leg that exists beats a missing mode.
    private func drivingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        let mapRoute: MKRoute?
        do {
            let directions = MKDirections(request: request)
            mapRoute = try await withMapKitTimeout(box: MapKitOperationBox { directions.cancel() }) {
                try await directions.calculate().routes.first
            }
        } catch {
            AppLog.routing.info("Driving directions unavailable, falling back to the walking leg: \(error)")
            mapRoute = nil
        }
        guard let mapRoute else {
            // Retyped, not returned as-is: the mode was decided by distance and does not change
            // because MapKit declined to draw it. A fallback typed `.walking` would put "Walk 12
            // km" on the card and into the walking total, the Least Walking sort and the confidence
            // penalty.
            guard let walk = await walkingSegment(
                from: from,
                to: to,
                fromName: fromName,
                toName: toName
            ) else { return nil }
            var notes = walk.accessibilityNotes
            notes.append(AppLocalization.text(
                english: "Drawn along the walking route. No driving directions are available.",
                simplified: "沿步行路线绘制，没有可用的驾车导航数据。",
                traditional: "沿步行路線繪製，沒有可用的駕車導航資料。"
            ))
            return walk.retyped(as: .driving, duration: walk.duration, accessibilityNotes: notes)
        }
        return RouteSegment(
            id: UUID(),
            type: .driving,
            lineName: nil,
            lineColorHex: nil,
            fromStationName: fromName,
            toStationName: toName,
            fromStationID: nil,
            toStationID: nil,
            duration: mapRoute.expectedTravelTime,
            distance: mapRoute.distance,
            stops: 0,
            stationStops: [],
            polylineCoordinates: mapRoute.polyline.routeCoordinates.map {
                CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            },
            // nil rather than the driving steps: `walkingDirections` feeds the stairs and step-free
            // checks, which a car's turn list means nothing to.
            walkingDirections: nil,
            accessibilityNotes: [AppLocalization.text(
                english: "Driving time excludes parking",
                simplified: "驾车时间不含停车",
                traditional: "駕車時間不含停車"
            )]
        )
    }

    /// 14 km/h. A guess, and labelled as one wherever the leg is shown.
    private static let cyclingMetresPerSecond: Double = 14_000.0 / 3_600.0
}

@MainActor
final class MapKitPlaceSearchProvider: PlaceSearchProviding {
    func searchPlaces(keyword: String, region: MKCoordinateRegion?, limit: Int) async throws -> [TransitPlace] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let region {
            request.region = region
        }

        do {
            let search = MKLocalSearch(request: request)
            let response = try await withMapKitTimeout(box: MapKitOperationBox { search.cancel() }) {
                try await search.start()
            }
            return response.mapItems.prefix(limit).map {
                TransitPlace(mapItem: $0, source: .mapKit)
            }
        } catch {
            throw RoutePlanningError.placeSearchUnavailable
        }
    }

    func reverseGeocode(location: CLLocationCoordinate2D, name: String?) async throws -> TransitPlace {
        // A fresh `CLGeocoder` per call: one instance allows one request at a time and cancels the
        // previous one, so overlapping reverse geocodes would cancel each other.
        let geocoder = CLGeocoder()
        let placemarks = try await withMapKitTimeout(box: MapKitOperationBox { geocoder.cancelGeocode() }) {
            try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: location.latitude, longitude: location.longitude)
            )
        }
        let placemark = placemarks.first
        return TransitPlace(
            name: name ?? placemark?.name ?? AppLocalization.localized("Current Location"),
            coordinate: location,
            address: [placemark?.locality, placemark?.subLocality, placemark?.thoroughfare]
                .compactMap { $0 }
                .joined(separator: " "),
            source: .currentLocation
        )
    }
}

struct TransitPlace: Identifiable, Equatable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let type: String?
    let address: String?
    let entranceCoordinate: CLLocationCoordinate2D?
    let source: TransitPlaceSource

    init(
        name: String,
        coordinate: CLLocationCoordinate2D,
        type: String? = nil,
        address: String? = nil,
        entranceCoordinate: CLLocationCoordinate2D? = nil,
        source: TransitPlaceSource = .mapKit
    ) {
        self.name = name
        self.coordinate = coordinate
        self.type = type
        self.address = address
        self.entranceCoordinate = entranceCoordinate
        self.source = source
    }

    init(mapItem: MKMapItem, source: TransitPlaceSource = .mapKit) {
        self.init(
            name: mapItem.name ?? AppLocalization.localized("Unknown place"),
            coordinate: mapItem.placemark.coordinate,
            address: mapItem.placemark.title,
            source: source
        )
    }

    var id: String {
        "\(name)-\(String(format: "%.6f", coordinate.latitude))-\(String(format: "%.6f", coordinate.longitude))"
    }

    var routeCoordinate: CLLocationCoordinate2D { entranceCoordinate ?? coordinate }

    func withSource(_ source: TransitPlaceSource) -> TransitPlace {
        TransitPlace(
            name: name,
            coordinate: coordinate,
            type: type,
            address: address,
            entranceCoordinate: entranceCoordinate,
            source: source
        )
    }

    var detailText: String? {
        [type, address]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
    }

    static func == (lhs: TransitPlace, rhs: TransitPlace) -> Bool { lhs.id == rhs.id }
}
