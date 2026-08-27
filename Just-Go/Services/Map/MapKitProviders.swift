import CoreLocation
import MapKit

struct MapKitTimeoutError: Error {}

/// Races `operation` against a deadline so a stalled MapKit call (MKLocalSearch, MKDirections)
/// can't hang a user-facing spinner indefinitely. MapKit calls are known elsewhere in this
/// codebase to ignore Swift task cancellation, so the abandoned call may keep running in the
/// background after this throws, but the caller (and its loading UI) is unblocked either way.
func withMapKitTimeout<T: Sendable>(
    seconds: TimeInterval = 12,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
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

/// "Where I am", as somewhere a trip can start from.
///
/// The ladder below has four ways to go wrong. A cached fix that is fresh enough, a live request,
/// a coarser last-known fallback, and a reverse-geocode that may fail on its own, and it used to
/// live inside `RoutePlannerViewModel.useCurrentLocation` because the deleted route-entry page was
/// the only thing that ever asked. Two screens ask now, and a second copy of a four-branch fallback
/// is exactly the drift `CLAUDE.md` warns about.
struct CurrentPlaceResolver {
    let locationService: LocationService
    let placeSearchProvider: PlaceSearchProviding

    /// A fix good enough to route from, already in the map's coordinate frame. Throws rather than
    /// returning nil: "you have not allowed this" and "it never arrived" need different words on
    /// screen, and only the error carries which one happened.
    func coordinate() async throws -> CLLocationCoordinate2D {
        if let recent = locationService.currentLocation,
           recent.horizontalAccuracy >= 0,
           recent.horizontalAccuracy <= 100,
           abs(recent.timestamp.timeIntervalSinceNow) <= 120 {
            // A recent, sufficiently accurate fix (e.g. from pre-warming) is good enough for a
            // route origin: use it instead of waiting on a fresh one that can stall indoors, on
            // weak GPS, or in the simulator. The ≤120 s window is looser than
            // requestCurrentLocation's 30 s so a just-prewarmed fix answers instantly; the
            // accuracy gate is what keeps it safe.
            return locationService.mapSpaceCoordinate(from: recent.coordinate)
        }

        do {
            let fix = try await locationService.requestCurrentLocation()
            return locationService.mapSpaceCoordinate(from: fix.coordinate)
        } catch {
            if let locationError = error as? LocationServiceError, locationError == .permissionDenied {
                throw error
            }
            // Last resort: a last-known fix so the field still fills, but reject an obviously
            // coarse one (accuracy relaxed only to a city-level bound) rather than seed routing
            // with a km-off origin.
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

/// One direction of one line, established to have stopped running when the rider would board it.
///
/// A direction, not a line, because that is what the timetable actually says. 天通苑南 on 5号线 has
/// a southbound last train at 22:51 and a northbound one at 23:57 — 66 minutes apart, and across a
/// 60-station Beijing sample 92 % of station/line pairs differ by more than 15 minutes. Banning the
/// whole line on the strength of one direction threw away a train that was still running, which at
/// 23:20 is when there are fewest of them left.
///
/// The direction is carried as one oriented hop the shut service makes rather than as a name or a
/// terminus: the graph can order any pattern against it, and it needs no vocabulary shared with
/// whichever operator supplied the verdict.
struct ClosedServiceDirection: Hashable, Sendable {
    let lineID: String
    /// Qualified (`network-<city>-<station>`) IDs, so a caller holding a route's own leg context can
    /// build one without reaching into the graph's internal identifiers.
    let fromStationID: String
    let toStationID: String
}

protocol TransitRouteProviding {
    /// - Parameter excludingServices: line directions the caller has established are not running
    ///   when this rider would board them. The graph itself is deliberately time-blind — it is a
    ///   mechanical shortest path, and first/last train is enrichment's business, arriving from an
    ///   operator or a routing provider long after the search would need it. This is how the clock
    ///   reaches the search anyway: not as a timetable it cannot read, but as the conclusion drawn
    ///   from one.
    func routes(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter,
        excludingServices: Set<ClosedServiceDirection>
    ) async throws -> [Route]
}

/// Builds one walking leg. Extracted from `BundledMetroRouteProvider` because enrichment needs it
/// too: the graph walks the rider to the station, then `RoutePlanningService` picks which door they
/// should actually use, and the leg has to be recomputed against that door. Two callers, one
/// implementation: a second copy would drift on exactly the numbers riders read.
protocol WalkingRouteProviding {
    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment?

    /// The same leg by whichever mode its length calls for. Walking is unchanged; the other two
    /// are described on the implementation, which is where their honesty caveats belong.
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
            mapRoute = try await withMapKitTimeout {
                try await MKDirections(request: request).calculate().routes.first
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

    /// A bike ride along the **walking** route, re-timed.
    ///
    /// `MKDirectionsTransportType` has `.automobile`, `.walking`, `.transit` and `.any`. There is
    /// no cycling type, and `.transit` refuses to calculate at all (measured: `MKErrorDomain` 5).
    /// So there is no cycling routing available to this app, and the honest thing to do with that
    /// is say it rather than draw a line that pretends otherwise: the shape is the pedestrian
    /// route, and the leg says so.
    ///
    /// The failure this guards against is a walking route that no bike can follow. Apple's own
    /// steps name stairs, and a step-mentioning leg keeps the pedestrian duration and carries the
    /// warning instead of quietly promising a 14 km/h average over a staircase.
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
        // 14 km/h: a shared bike in city traffic, and slow enough that a rider who beats it is
        // early rather than late. Not applied where stairs were named. See above.
        let duration = hasStairs ? walk.duration : walk.distance / Self.cyclingMetresPerSecond
        return walk.retyped(as: .cycling, duration: duration, accessibilityNotes: notes)
    }

    /// A real driving route from MapKit. `.Automobile` is a transport type `MKDirections` will
    /// actually calculate, unlike `.transit`, so unlike the bike this one is measured rather than
    /// derived. Falls back to the walking leg when MapKit declines, because a leg that exists is
    /// worth more than a mode that is missing.
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
            mapRoute = try await withMapKitTimeout {
                try await MKDirections(request: request).calculate().routes.first
            }
        } catch {
            AppLog.routing.info("Driving directions unavailable, falling back to the walking leg: \(error)")
            mapRoute = nil
        }
        guard let mapRoute else {
            return await walkingSegment(from: from, to: to, fromName: fromName, toName: toName)
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
            // Deliberately nil rather than the driving steps: `walkingDirections` is what the
            // stairs and step-free checks read, and a car's turn list has nothing to say to them.
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
            let response = try await withMapKitTimeout {
                try await MKLocalSearch(request: request).start()
            }
            return response.mapItems.prefix(limit).map {
                TransitPlace(mapItem: $0, source: .mapKit)
            }
        } catch {
            throw RoutePlanningError.placeSearchUnavailable
        }
    }

    func reverseGeocode(location: CLLocationCoordinate2D, name: String?) async throws -> TransitPlace {
        // A fresh CLGeocoder per call: CLGeocoder allows only one in-flight request per
        // instance and cancels a prior request when a new one starts, so a shared instance
        // would make overlapping reverse-geocodes (e.g. quick Current-Location taps across
        // fields) cancel each other. Reverse-geocode is one-shot, not a hot path.
        let placemarks = try await withMapKitTimeout {
            try await CLGeocoder().reverseGeocodeLocation(
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
