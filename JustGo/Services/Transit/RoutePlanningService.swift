import Foundation
import CoreLocation
import MapKit

/// Memoises walking legs for the span of one plan.
///
/// Alternatives are enriched concurrently and mostly share their endpoints, so without this the
/// same door-to-destination walk is requested once per alternative per candidate door — enough
/// duplicate `MKDirections` traffic to get throttled. In-flight calls are shared, not just
/// finished ones, because the concurrent callers arrive together.
private actor WalkingLegMemo {
    private let provider: WalkingRouteProviding
    private var inFlight: [String: Task<RouteSegment?, Never>] = [:]

    init(provider: WalkingRouteProviding) {
        self.provider = provider
    }

    func leg(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String,
        mode: AccessLegMode
    ) async -> RouteSegment? {
        // ~1 m precision: finer than the coordinates differ by, coarser than float noise.
        // The mode is part of the key: the same two points cycled and driven are different legs.
        let key = String(
            format: "%.5f,%.5f>%.5f,%.5f|%@",
            from.latitude, from.longitude, to.latitude, to.longitude,
            String(describing: mode)
        )
        if let existing = inFlight[key] { return await existing.value }
        let provider = provider
        let task = Task {
            await provider.accessSegment(
                from: from,
                to: to,
                fromName: fromName,
                toName: toName,
                mode: mode
            )
        }
        inFlight[key] = task
        return await task.value
    }
}

final class RoutePlanningService {
    private let placeSearchProvider: PlaceSearchProviding
    private let routeProvider: TransitRouteProviding
    private let officialStationData: OfficialStationDataProviding
    private let walkingRoutes: WalkingRouteProviding
    /// The operator's own answer about a station, fetched on the rider's device. Optional because
    /// a route is still a route without it — and because most cities have no such source.
    private let officialStationInformation: (any OfficialStationInformationProviding)?
    private let stationInformationDirectory: StationInformationDirectory?
    private let serviceHoursResolver = ServiceHoursResolver()

    init(
        placeSearchProvider: PlaceSearchProviding,
        routeProvider: TransitRouteProviding,
        officialStationData: OfficialStationDataProviding,
        walkingRoutes: WalkingRouteProviding = MapKitWalkingRouteProvider(),
        officialStationInformation: (any OfficialStationInformationProviding)? = nil,
        stationInformationDirectory: StationInformationDirectory? = nil
    ) {
        self.placeSearchProvider = placeSearchProvider
        self.routeProvider = routeProvider
        self.officialStationData = officialStationData
        self.walkingRoutes = walkingRoutes
        self.officialStationInformation = officialStationInformation
        self.stationInformationDirectory = stationInformationDirectory
    }

    func planRoute(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter = .none,
        tripAnchor: TripTimeAnchor = .now
    ) async throws -> [Route] {
        // Walking is a real answer, and until now it was one the app could not give: every result
        // had to contain a train. Asking for a route to your nearest station therefore produced a
        // ride one stop out and back, because that was the cheapest thing the graph was allowed to
        // return. Built alongside the search rather than after it — it costs one MKDirections call
        // and the two are independent.
        async let directWalk = directWalkingRoute(from: origin, to: destination)

        let metroRoutes: [Route]
        do {
            metroRoutes = try await routeProvider.routes(
                from: origin,
                to: destination,
                accessibilityFilter: accessibilityFilter
            )
        } catch {
            // No train answer at all. If the two ends are within walking distance that is not a
            // failure, it is the answer; otherwise the original error is still the honest reply.
            if let walk = await directWalk { return [walk] }
            throw error
        }

        // Anything the rider could beat on foot is not worth showing. This is also the backstop for
        // the out-and-back above: even if some future cost change makes such a path legal again, it
        // cannot survive a comparison with simply walking there.
        let walk = await directWalk
        let routes = walk.map { walk in metroRoutes.filter { $0.totalDuration < walk.totalDuration } }
            ?? metroRoutes
        guard !routes.isEmpty else {
            // Every alternative lost to walking, which means walking is the plan.
            if let walk { return [walk] }
            throw RoutePlanningError.noRouteFound
        }

        // Alternatives overwhelmingly share their first and last stations, so one memo across the
        // whole plan collapses their duplicate door-walk lookups into a single call each.
        let legs = WalkingLegMemo(provider: walkingRoutes)

        // Each route's enrichment below is a handful of officialStationData lookups that don't
        // touch any shared mutable state — running them one route after another multiplied
        // enrichment latency by the number of alternatives. They're independent, so enrich
        // concurrently instead (same fix already applied to the analogous per-alternative
        // fetch in BundledMetroRouteProvider.routes).
        return await withTaskGroup(of: (Int, Route).self) { group in
            for (index, route) in routes.enumerated() {
                group.addTask {
                    let enriched = await self.enrichedRoute(
                        route,
                        // A POI's own entrance beats its centroid when MapKit knows one — it is
                        // the door the rider actually walks to, so it is the right thing to
                        // measure the station's exits against.
                        originTarget: CodableCoordinate(
                            origin.entranceCoordinate ?? origin.coordinate
                        ),
                        destinationTarget: CodableCoordinate(
                            destination.entranceCoordinate ?? destination.coordinate
                        ),
                        accessibilityFilter: accessibilityFilter,
                        tripAnchor: tripAnchor,
                        legs: legs
                    )
                    return (index, enriched)
                }
            }
            var collected: [(Int, Route)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Official station information

    /// The operator's own page for each stop the trip calls at, keyed by station name.
    ///
    /// Best effort in every direction: no source for the city, no directory entry, a timeout or a
    /// refusal all mean "no official answer", never a failed plan. Bounded at four seconds because
    /// this is an *upgrade* to an answer that already exists — a rider waiting on a route must not
    /// wait on an operator's website.
    private func officialStationSnapshots(
        for stops: [RouteStationStop]
    ) async -> [String: OfficialStationInformationSnapshot] {
        guard let provider = officialStationInformation,
              let directory = stationInformationDirectory else { return [:] }
        let requests: [(name: String, request: OfficialStationInformationRequest)] = stops.compactMap { stop in
            guard let reference = directory.officialReference(
                forStationID: stop.stationID,
                name: stop.name,
                nameEn: nil
            ) else { return nil }
            return (stop.name, OfficialStationInformationRequest(stationID: stop.stationID, reference: reference))
        }
        guard !requests.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, OfficialStationInformationSnapshot?).self) { group in
            for entry in requests {
                group.addTask {
                    let snapshot = try? await withDeadline(seconds: 4) {
                        OfficialStationInformationProviderError.timedOut
                    } operation: {
                        try await provider.information(for: entry.request)
                    }
                    return (entry.name, snapshot)
                }
            }
            var result: [String: OfficialStationInformationSnapshot] = [:]
            for await (name, snapshot) in group {
                if let snapshot { result[name] = snapshot }
            }
            return result
        }
    }

    /// Counts a stop as having official accessibility when the operator publishes a lift for it.
    ///
    /// The pack's count comes from OpenStreetMap `wheelchair` tags, which cover 20% of the bundled
    /// network — so a Beijing trip reported "accessibility source pending" for stations whose
    /// operator page lists a 直梯 and where it is. Taken as the larger of the two rather than a
    /// replacement: the pack still speaks for cities with no official source.
    private func coverage(
        _ coverage: RouteDataCoverage,
        upgradedWith snapshots: [String: OfficialStationInformationSnapshot]
    ) -> RouteDataCoverage {
        guard !snapshots.isEmpty else { return coverage }
        let officialCount = snapshots.values.filter { snapshot in
            snapshot.exits.contains { $0.isAccessible == true } ||
                snapshot.facilityGroups.contains { group in
                    group.items.contains { Self.describesStepFreeFacility($0.name) }
                }
        }.count
        // Same argument for the timetable: the operator publishes first and last train per line
        // per direction, and the app was reading only the pack — so a Beijing trip was docked for
        // an "incomplete official schedule" while bjsubway.com was answering with one.
        let scheduleCount = snapshots.values.filter { snapshot in
            snapshot.lines.contains { line in
                line.services.contains { $0.firstTrain != nil || $0.lastTrain != nil }
            }
        }.count
        return RouteDataCoverage(
            stationCount: coverage.stationCount,
            officialAccessibilityCount: min(coverage.stationCount, max(coverage.officialAccessibilityCount, officialCount)),
            officialScheduleCount: min(coverage.stationCount, max(coverage.officialScheduleCount, scheduleCount)),
            officialFacilityCount: max(coverage.officialFacilityCount, officialCount)
        )
    }

    /// Whether the subway is running for this trip — resolved for **every** ride it makes, at the
    /// moment each one departs, rather than only for the first.
    ///
    /// Two holes met here. `serviceWindows` reads the city pack and no pack carries a timetable:
    /// operator schedule content must not be committed, so `schedules` is empty for all 2,849
    /// bundled stations and this resolved to `.unknown` for every route in every city while the
    /// machinery below it — the banner, the confidence reason, the feasibility level — looked
    /// finished. The operator's own page does publish first and last train, and
    /// `officialStationSnapshots` has already fetched it; reading it here redistributes nothing
    /// that the accessibility upgrade above does not already read the same way, on the rider's
    /// device and cached device-only.
    ///
    /// And only the boarding leg was ever checked. The train a rider actually misses is rarely the
    /// first one — it is the connection, which departs later in the evening and stops earlier. A
    /// definite failure on any leg beats "fine" on the others; a leg nobody can answer for keeps
    /// the whole trip `.unknown` rather than letting a verified leg speak for it.
    private func serviceStatus(
        for route: Route,
        cityID: String,
        snapshots: [String: OfficialStationInformationSnapshot],
        tripAnchor: TripTimeAnchor
    ) async -> (status: RouteServiceStatus, warning: RouteWarning?) {
        let departure = TripTimeContext(
            anchor: tripAnchor,
            totalDuration: route.totalDuration
        ).departureDate

        var elapsed: TimeInterval = 0
        var worst: (status: RouteServiceStatus, segment: RouteSegment)?
        var sawUnknown = false
        var sawAnswer = false

        for segment in route.segments {
            defer { elapsed += segment.duration }
            guard segment.type.isTransit, let stationName = segment.fromStationName else { continue }

            // The operator first: it is the authority on its own timetable and the only source that
            // answers at all today. The pack remains the fallback so a city that later ships
            // redistributable times keeps working with no change here.
            let official = Self.serviceWindows(from: snapshots[stationName])
            let windows = official.isEmpty
                ? await officialStationData.serviceWindows(
                    cityID: segment.packCityID ?? cityID,
                    stationName: stationName
                )
                : official

            let status = serviceHoursResolver.status(
                boardingLineName: segment.lineName,
                windows: windows,
                at: departure.addingTimeInterval(elapsed)
            )
            if status == .unknown {
                sawUnknown = true
                continue
            }
            sawAnswer = true
            if status.severity > (worst?.status.severity ?? 0) {
                worst = (status, segment)
            }
        }

        guard let worst else {
            // Nothing to report: either every leg is inside its service hours, or nobody could
            // answer for one of them and saying "running" would be borrowing another leg's answer.
            return (sawAnswer && !sawUnknown ? .running : .unknown, nil)
        }

        // Name the leg. On a one-ride trip the station adds nothing the rider does not already
        // know; on a trip with a change it is the whole point — the ride that fails is usually not
        // the one they are standing at the entrance of.
        let banner = worst.status.bannerText
        let message: String? = {
            guard let banner else { return nil }
            guard route.transferCount > 0, let station = worst.segment.fromStationName else { return banner }
            return AppLocalization.text(
                english: "\(station): \(banner)",
                simplified: "\(station)：\(banner)",
                traditional: "\(station)：\(banner)"
            )
        }()

        return (
            worst.status,
            worst.status.warningType.flatMap { type in
                message.map {
                    RouteWarning(
                        type: type,
                        message: $0,
                        affectedStationID: worst.segment.fromStationID
                    )
                }
            }
        )
    }

    /// The operator's published first/last train, in the shape the resolver reads. Rows with
    /// neither time are dropped rather than passed through as blanks — the resolver treats an
    /// empty pool as "no answer", which is what a row with no times actually is.
    private static func serviceWindows(
        from snapshot: OfficialStationInformationSnapshot?
    ) -> [StationServiceWindow] {
        guard let snapshot else { return [] }
        return snapshot.lines.flatMap { line in
            line.services.compactMap { service in
                guard service.firstTrain != nil || service.lastTrain != nil else { return nil }
                return StationServiceWindow(
                    lineName: line.lineName,
                    direction: service.direction,
                    firstTime: service.firstTrain,
                    lastTime: service.lastTrain
                )
            }
        }
    }

    /// A lift, by the words the operators actually use. Escalators are deliberately absent: an
    /// escalator is not step-free access, and counting one as though it were is the difference
    /// between a wheelchair user reaching the platform and being stranded at the concourse.
    private static func describesStepFreeFacility(_ name: String) -> Bool {
        let stepFree = ["直梯", "垂直电梯", "电梯", "升降平台", "无障碍电梯", "轮椅", "無障礙", "升降機"]
        return stepFree.contains { name.contains($0) }
    }

    /// The operator's exit list laid over the pack's.
    ///
    /// Beijing signs its exits `A`, `B`, `D2`. OpenStreetMap surveyed 1,095 doors for Beijing and
    /// left 200 of them unnamed, calling another 246 things like 东南口 — so the app sent riders to
    /// a door whose sign says something else, or to one with no name at all. Where the two agree on
    /// a name the surveyed coordinate is kept and the point is marked official; where the operator
    /// lists an exit nobody surveyed it is added without a coordinate, which is the honest shape —
    /// the exit exists and is called `A`, and where exactly it stands is not known.
    private func merged(
        _ guidance: [String: StationAccessGuidance],
        with snapshots: [String: OfficialStationInformationSnapshot]
    ) -> [String: StationAccessGuidance] {
        guard !snapshots.isEmpty else { return guidance }
        var merged = guidance
        for (stationName, snapshot) in snapshots where !snapshot.exits.isEmpty {
            let existing = guidance[stationName]?.accessPoints ?? []
            var matchedOfficialNames = Set<String>()
            let upgraded = existing.map { point -> StationAccessPoint in
                guard let exit = snapshot.exits.first(where: {
                    Self.exitNamesMatch($0.name, point.name)
                }) else { return point }
                matchedOfficialNames.insert(exit.name)
                return StationAccessPoint(
                    id: point.id,
                    name: exit.name,
                    kind: point.kind,
                    coordinate: point.coordinate,
                    isAccessible: exit.isAccessible ?? point.isAccessible,
                    notes: (point.notes + exit.details).uniqued(),
                    source: point.source,
                    confidence: .official
                )
            }
            // One door, one exit: the operator says this station has exactly one exit and exactly
            // one was surveyed, so they are the same door and it is called what the sign says. Any
            // looser pairing would be a guess — with two surveyed doors and exits A and B there is
            // nothing in either dataset that says which is which, and a wrong exit letter sends a
            // rider up the wrong staircase with full confidence.
            var bound = upgraded
            let unnamed = upgraded.enumerated().filter { $0.element.name.trimmingCharacters(in: .whitespaces).isEmpty }
            let unmatched = snapshot.exits.filter { !matchedOfficialNames.contains($0.name) && !$0.name.isEmpty }
            if unnamed.count == 1, unmatched.count == 1, let exit = unmatched.first, let slot = unnamed.first {
                matchedOfficialNames.insert(exit.name)
                let point = slot.element
                bound[slot.offset] = StationAccessPoint(
                    id: point.id,
                    name: exit.name,
                    kind: point.kind,
                    coordinate: point.coordinate,
                    isAccessible: exit.isAccessible ?? point.isAccessible,
                    notes: (point.notes + exit.details).uniqued(),
                    source: point.source,
                    confidence: .official
                )
            }
            let unsurveyed = snapshot.exits
                .filter { !matchedOfficialNames.contains($0.name) && !$0.name.isEmpty }
                .map { exit in
                    StationAccessPoint(
                        id: "official-\(stationName)-\(exit.name)",
                        name: exit.name,
                        kind: .exit,
                        coordinate: nil,
                        isAccessible: exit.isAccessible ?? false,
                        notes: exit.details,
                        source: .stationPOI,
                        confidence: .official
                    )
                }
            merged[stationName] = StationAccessGuidance(
                accessPoints: bound + unsurveyed,
                confidence: .official
            )
        }
        return merged
    }

    /// Exit names match when they name the same sign. Compared case- and whitespace-insensitively
    /// because OpenStreetMap records `a`, `A` and `A ` for the same door.
    private static func exitNamesMatch(_ official: String, _ surveyed: String) -> Bool {
        let left = official.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let right = surveyed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return !left.isEmpty && !right.isEmpty && left == right
    }

    /// The trip on foot, when that is a thing a person would actually do.
    ///
    /// Bounded at 3 km straight-line: past that walking stops being an answer and starts being a
    /// way to make `MKDirections` slow for nothing. Deliberately carries no station IDs — it calls
    /// at none — which leaves `networkCityID` nil, the value every reader of it already handles.
    /// `strategy` is `.fastest` because when walking wins it *is* the fastest option, so this needs
    /// no new strategy case, no new localized strings, and no change to the sort chips.
    private func directWalkingRoute(from origin: TransitPlace, to destination: TransitPlace) async -> Route? {
        let from = origin.routeCoordinate
        let to = destination.routeCoordinate
        guard from.distance(to: to) <= 3_000 else { return nil }
        guard let segment = await walkingRoutes.walkingSegment(
            from: from,
            to: to,
            fromName: origin.name,
            toName: destination.name
        ) else {
            return nil
        }

        return Route(
            id: UUID(),
            origin: origin.name,
            destination: destination.name,
            originStationID: "",
            destinationStationID: "",
            strategy: .fastest,
            segments: [segment],
            totalDuration: segment.duration,
            walkingDistance: segment.distance,
            totalStops: 0,
            transferCount: 0,
            isFullyAccessible: false,
            stepFreeAssessment: segment.walkingDirections?.contains(where: \.hasStairs) == true
                ? .barrierDetected
                : .unknown,
            warnings: [],
            accessGuidance: [],
            dataCoverage: .unknown
        )
    }

    private func enrichedRoute(
        _ route: Route,
        originTarget: CodableCoordinate,
        destinationTarget: CodableCoordinate,
        accessibilityFilter: AccessibilityFilter,
        tripAnchor: TripTimeAnchor,
        legs: WalkingLegMemo
    ) async -> Route {
        var route = route
        // The pack that actually produced the route. A walking-only plan has none, and every
        // official-data lookup below then finds nothing and reports unavailable — which is the
        // truth: no station was involved, so there is nothing to say about one.
        let routeCityID = route.networkCityID ?? ""
        let criticalStops = criticalStops(for: route)
        let criticalStopNames = criticalStops.map(\.name)

        // These three official-data lookups are independent of one another — kick them
        // off concurrently and await results in the order their side effects are applied.
        async let dataCoverage = officialStationData.routeCoverage(
            cityID: routeCityID,
            stationNames: criticalStopNames
        )
        async let criticalStationsResult = officialStationData.enrichStations(
            criticalStops.compactMap { stop -> Station? in
                guard let coordinate = stop.coordinate else { return nil }
                return Station(
                    stationID: stop.stationID,
                    name: stop.name,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    // The stop's own pack, not the trip's. On a Dongguan → Guangzhou trip the two
                    // ends are in different packs, and every lookup keyed to the origin's city
                    // came back empty for the far half of the journey.
                    cityID: stop.packCityID ?? routeCityID
                )
            }
        )
        // The operator's own station pages, for the stops this trip actually calls at. Started
        // here so the network time overlaps the pack lookups above rather than adding to them.
        async let officialSnapshotsResult = officialStationSnapshots(for: criticalStops)
        route.dataCoverage = await dataCoverage
        let officialSnapshots = await officialSnapshotsResult
        route.dataCoverage = coverage(route.dataCoverage, upgradedWith: officialSnapshots)
        let criticalStations = await criticalStationsResult
        route.stepFreeAssessment = stepFreeAssessment(
            route: route,
            criticalStations: criticalStations,
            expectedStationCount: criticalStops.count
        )
        route.isFullyAccessible = route.stepFreeAssessment == .confirmed
        if route.stepFreeAssessment == .unknown,
           accessibilityFilter.requiresWheelchairAccess || accessibilityFilter.requiresElevator {
            route.warnings.append(RouteWarning(
                type: .stepFreeAccessUnconfirmed,
                message: AppLocalization.localized("Step-free access is not confirmed for the boarding and arrival points."),
                affectedStationID: nil
            ))
        }

        let service = await serviceStatus(
            for: route,
            cityID: routeCityID,
            snapshots: officialSnapshots,
            tripAnchor: tripAnchor
        )
        route.serviceStatus = service.status
        if let warning = service.warning {
            route.warnings.append(warning)
        }

        // Being in the routable network does not make a station one a rider can use. The reviewed
        // catalog marks eight that do not take passengers — 福寿岭 is still a building site, 黄土店
        // is open track with no passenger stop — and every one of them can be routed to today. The
        // status was only ever read by the station's own screen, so a plan could send someone to a
        // door that does not open and say nothing.
        route.warnings.append(contentsOf: await passengerServiceWarnings(
            stops: criticalStops,
            cityID: routeCityID
        ))

        // Per-station entrance/exit guidance (best available: official → estimated → unavailable).
        let packGuidance = await officialStationData.stationGuidance(
            cityID: routeCityID,
            stationNames: criticalStopNames
        )
        let guidanceByStation = merged(packGuidance, with: officialSnapshots)
        let stationPositions = criticalStops.reduce(into: [String: CodableCoordinate]()) { index, stop in
            if let coordinate = stop.coordinate { index[stop.name] = coordinate }
        }
        // Choose each end's door ONCE, by measured walking distance, and let every surface read
        // that one answer. When the timeline picked its own exit and the guide card picked another,
        // the same trip named two different doors on two screens.
        // Any access leg, not just a walked one — the door-measuring below is what turns a
        // straight-line exit guess into a measured one, and a cycled or driven first mile needs it
        // just as much.
        let originIndex = route.segments.first?.type.isAccessLeg == true ? 0 : nil
        let destinationIndex = route.segments.count > 1 && route.segments.last?.type.isAccessLeg == true
            ? route.segments.count - 1
            : nil
        // Read what the two lookups need before starting them: an `async let` body may not capture
        // the mutable `route` they are about to update.
        let originGuide = route.originAccessGuide
        let destinationGuide = route.destinationAccessGuide
        let originSegment = originIndex.map { route.segments[$0] }
        let destinationSegment = destinationIndex.map { route.segments[$0] }

        async let originChoiceTask = chooseExit(
            guide: originGuide,
            guidance: guidanceByStation,
            stationPositions: stationPositions,
            rider: originTarget,
            existing: originSegment,
            isArrival: false,
            requiresStepFree: accessibilityFilter.requiresStepFreeEntrance,
            legs: legs
        )
        async let destinationChoiceTask = chooseExit(
            guide: destinationGuide,
            guidance: guidanceByStation,
            stationPositions: stationPositions,
            rider: destinationTarget,
            existing: destinationSegment,
            isArrival: true,
            requiresStepFree: accessibilityFilter.requiresStepFreeEntrance,
            legs: legs
        )
        let originChoice = await originChoiceTask
        let destinationChoice = await destinationChoiceTask

        route.stationGuidance = buildStationGuidance(
            route: route,
            guidance: guidanceByStation,
            originExit: originChoice?.point,
            destinationExit: destinationChoice?.point,
            originTarget: originTarget,
            destinationTarget: destinationTarget,
            requiresStepFree: accessibilityFilter.requiresStepFreeEntrance
        )
        route.accessGuidance = upgradeAccessGuidance(
            route.accessGuidance,
            guidance: guidanceByStation,
            stationPositions: stationPositions,
            originChoice: originChoice,
            destinationChoice: destinationChoice
        )
        route = applyChosenExitLegs(
            route,
            originIndex: originIndex,
            destinationIndex: destinationIndex,
            originChoice: originChoice,
            destinationChoice: destinationChoice
        )

        return route
    }

    /// Distance below which re-walking the leg to a specific door is not worth an `MKDirections`
    /// round trip — the door is essentially where the graph already sent the rider.
    private static let exitRerouteThresholdMetres: Double = 40

    /// How many of the nearest doors get their walk actually measured. Three covers the case this
    /// exists for — one door on the wrong side of a barrier — without turning every plan into a
    /// dozen routing calls.
    private static let exitCandidateLimit = 3

    /// The end of a trip, resolved: which door, and the real walk to it.
    private struct ChosenExit {
        let point: StationAccessPoint
        let stepFreeUnavailable: Bool
        /// nil when the walk was not worth measuring; the caller keeps the leg it already had.
        let leg: RouteSegment?
    }

    /// Picks the door for one end of the trip and measures the walk to it.
    ///
    /// The graph walks the rider to the station's centre, because a centre is all a graph node has,
    /// and enrichment then names a specific door. Left there, the two halves of the screen disagree:
    /// the text says "Exit D" while the map draws — and the duration counts — a walk to the middle
    /// of the station. At 西单 that read as a 265 m walk to a door 34 m away.
    ///
    /// Straight-line distance alone is not enough to choose with, either. At 西直门 the nearest door
    /// by air is a 698 m walk, because the railway runs between it and the street. So the nearest
    /// few are measured for real and the shortest actual walk wins.
    private func chooseExit(
        guide: RouteAccessGuide?,
        guidance: [String: StationAccessGuidance],
        stationPositions: [String: CodableCoordinate],
        rider: CodableCoordinate,
        existing: RouteSegment?,
        isArrival: Bool,
        requiresStepFree: Bool,
        legs: WalkingLegMemo
    ) async -> ChosenExit? {
        guard let guide else { return nil }
        let access = guidance[guide.stationName] ?? .empty
        let ranked = access.rankedAccessPoints(
            near: rider,
            requiresStepFree: requiresStepFree,
            limit: Self.exitCandidateLimit
        )
        guard let nearest = ranked.points.first else { return nil }
        let fallback = ChosenExit(point: nearest, stepFreeUnavailable: ranked.stepFreeUnavailable, leg: nil)

        // Nothing to replace, or no station centre to judge against: keep the straight-line pick and
        // spend no calls on a difference that cannot be established.
        guard let existing, let centre = stationPositions[guide.stationName] else { return fallback }
        let mode = existing.accessLegMode

        let measurable = ranked.points.filter { point in
            guard let coordinate = point.coordinate else { return false }
            return centre.metres(to: coordinate) > Self.exitRerouteThresholdMetres
        }
        guard !measurable.isEmpty else { return fallback }

        let riderCoordinate = CLLocationCoordinate2D(latitude: rider.latitude, longitude: rider.longitude)
        let fromName = existing.fromStationName ?? ""
        let toName = existing.toStationName ?? ""

        let walked = await withTaskGroup(of: (StationAccessPoint, RouteSegment?).self) { group in
            for point in measurable {
                guard let door = point.coordinate else { continue }
                group.addTask {
                    let doorCoordinate = CLLocationCoordinate2D(
                        latitude: door.latitude,
                        longitude: door.longitude
                    )
                    let leg = await legs.leg(
                        from: isArrival ? doorCoordinate : riderCoordinate,
                        to: isArrival ? riderCoordinate : doorCoordinate,
                        fromName: fromName,
                        toName: toName,
                        // The assembler already decided how this end is covered. Re-measuring it
                        // against a specific door must not silently turn a 6 km drive back into
                        // a walk — the door moves, the mode does not.
                        mode: mode
                    )
                    return (point, leg)
                }
            }
            var results: [(StationAccessPoint, RouteSegment?)] = []
            for await result in group { results.append(result) }
            return results
        }

        let best = walked
            .compactMap { point, leg -> (point: StationAccessPoint, leg: RouteSegment)? in
                leg.map { (point, $0) }
            }
            .min { $0.leg.distance < $1.leg.distance }
        guard let best else { return fallback }
        return ChosenExit(
            point: best.point,
            stepFreeUnavailable: ranked.stepFreeUnavailable,
            leg: best.leg
        )
    }

    /// Swaps in the measured legs and restates everything derived from them.
    private func applyChosenExitLegs(
        _ route: Route,
        originIndex: Int?,
        destinationIndex: Int?,
        originChoice: ChosenExit?,
        destinationChoice: ChosenExit?
    ) -> Route {
        var route = route
        var changed = false
        if let index = originIndex, let leg = originChoice?.leg {
            route.segments[index] = leg
            changed = true
        }
        if let index = destinationIndex, let leg = destinationChoice?.leg {
            route.segments[index] = leg
            changed = true
        }
        guard changed else { return route }

        // The guides quote the walk they belong to, so they have to be restated from the new legs
        // rather than left holding the centroid's numbers.
        let updatedSegments = route.segments
        route.accessGuidance = route.accessGuidance.map { guide in
            guard let index = guide.kind == .origin ? originIndex : destinationIndex else { return guide }
            let leg = updatedSegments[index]
            return RouteAccessGuide(
                id: guide.id,
                kind: guide.kind,
                placeName: guide.placeName,
                stationName: guide.stationName,
                accessPoint: guide.accessPoint,
                walkingDistance: leg.distance,
                walkingDuration: leg.duration,
                walkingSteps: leg.walkingDirections ?? [],
                accessibilityNotes: guide.accessibilityNotes
            )
        }

        // `longWalk` was judged against the centroid walk in the assembler; a door can be several
        // hundred metres from a station's centre, so the verdict can genuinely flip either way.
        let walkingDistance = updatedSegments.filter { $0.type == .walking }.reduce(0) { $0 + $1.distance }
        route.walkingDistance = walkingDistance
        route.warnings.removeAll { $0.type == .longWalk }
        if walkingDistance >= 800 {
            route.warnings.append(RouteWarning(
                type: .longWalk,
                message: AppLocalization.localized("Long walking segment"),
                affectedStationID: nil
            ))
        }
        return route
    }

    /// Tags the boarding, transfer, and arrival stations of a route with the best-available
    /// access-point + confidence (and a transfer-corridor hint, when one is authored).
    private func buildStationGuidance(
        route: Route,
        guidance: [String: StationAccessGuidance],
        originExit: StationAccessPoint?,
        destinationExit: StationAccessPoint?,
        originTarget: CodableCoordinate,
        destinationTarget: CodableCoordinate,
        requiresStepFree: Bool
    ) -> [RouteStationGuidance] {
        let transitSegments = route.segments.filter { $0.type.isTransit }
        guard !transitSegments.isEmpty else { return [] }
        var result: [RouteStationGuidance] = []
        var seen = Set<String>()

        func add(_ stop: RouteStationStop, role: RouteStationGuidance.Role) {
            guard seen.insert("\(stop.stationID)-\(role.rawValue)").inserted else { return }
            let access = guidance[stop.name] ?? .empty
            // The boarding and arrival doors were already chosen — by measured walking distance —
            // so take those rather than re-deciding here. Deciding twice is how the timeline and
            // the guide card came to name two different exits for the same trip.
            //
            // A transfer never leaves the station, so it has no entrance to recommend at all.
            let chosen: StationAccessPoint?
            switch role {
            case .boarding: chosen = originExit
            case .arrival: chosen = destinationExit
            case .transfer: chosen = nil
            }
            // Downstream — the trip timeline, the arrival notification — only ever sees this point,
            // so an unlabeled entrance has its direction resolved here, while the station it is
            // measured from is still in hand.
            let exit = chosen?.labeled(relativeTo: stop.coordinate)
            result.append(RouteStationGuidance(
                stationID: stop.stationID,
                stationName: stop.name,
                role: role,
                exit: exit,
                confidence: access.confidence
            ))
        }

        for (index, segment) in transitSegments.enumerated() {
            if index == 0, let boarding = segment.stationStops.first {
                add(boarding, role: .boarding)
            }
            guard let alight = segment.stationStops.last else { continue }
            if index == transitSegments.count - 1 {
                add(alight, role: .arrival)
            } else {
                add(alight, role: .transfer)
            }
        }
        return result
    }

    /// Replaces the placeholder origin/destination access guides with a specific exit + confidence
    /// when station data provides one; otherwise leaves the honest "unavailable" guide untouched.
    private func upgradeAccessGuidance(
        _ guides: [RouteAccessGuide],
        guidance: [String: StationAccessGuidance],
        stationPositions: [String: CodableCoordinate],
        originChoice: ChosenExit?,
        destinationChoice: ChosenExit?
    ) -> [RouteAccessGuide] {
        guides.map { guide in
            let access = guidance[guide.stationName] ?? .empty
            guard let recommendation = guide.kind == .origin ? originChoice : destinationChoice
            else { return guide }
            let point = recommendation.point.labeled(relativeTo: stationPositions[guide.stationName])
            let upgradedPoint = RouteAccessPoint(
                id: point.id,
                name: point.name,
                coordinate: point.coordinate ?? guide.accessPoint?.coordinate,
                isWheelchairLikely: point.isAccessible,
                hasElevatorHint: point.kind == .elevator || point.isAccessible,
                source: point.source
            )
            var notes: [String]
            if access.confidence == .official {
                notes = guide.accessibilityNotes.filter {
                    $0 != AppLocalization.localized("Specific entrance or exit is unavailable")
                }
            } else {
                notes = [AppLocalization.text(
                    english: "Exit \(point.name) is estimated from station data — confirm on site.",
                    simplified: "出入口 \(point.name) 根据车站数据估算，请到现场确认。",
                    traditional: "出入口 \(point.name) 根據車站資料估算，請到現場確認。"
                )]
            }
            // The rider asked for step-free access and this station has no entrance recorded as
            // step-free. Say that, rather than let the nearest exit read as an accessible one —
            // most entrances are simply unsurveyed, which is not the same as being accessible.
            if recommendation.stepFreeUnavailable {
                notes.append(AppLocalization.text(
                    english: "No step-free entrance is recorded at \(guide.stationName) — this is the nearest one.",
                    simplified: "\(guide.stationName)暂无无障碍出入口记录，这是最近的一个。",
                    traditional: "\(guide.stationName)暫無無障礙出入口記錄，這是最近的一個。"
                ))
            }
            return RouteAccessGuide(
                id: guide.id,
                kind: guide.kind,
                placeName: guide.placeName,
                stationName: guide.stationName,
                accessPoint: upgradedPoint,
                walkingDistance: guide.walkingDistance,
                walkingDuration: guide.walkingDuration,
                walkingSteps: guide.walkingSteps,
                accessibilityNotes: notes
            )
        }
    }

    /// One warning per boarding, transfer or arrival station the operator does not serve. Transfers
    /// count: a transfer is a place the rider gets off one train and onto another, on foot, which
    /// is exactly what a station closed to passengers does not allow.
    private func passengerServiceWarnings(
        stops: [RouteStationStop],
        cityID: String
    ) async -> [RouteWarning] {
        var warnings: [RouteWarning] = []
        for stop in stops {
            let station = Station(
                stationID: stop.stationID,
                name: stop.name,
                latitude: stop.coordinate?.latitude ?? 0,
                longitude: stop.coordinate?.longitude ?? 0,
                cityID: cityID
            )
            guard let status = await officialStationData
                .officialResourceReview(for: station)?
                .stationInformationStatus,
                !status.servesPassengers,
                let message = status.routeWarning(stationName: stop.name) else { continue }

            warnings.append(RouteWarning(
                type: .stationNotServingPassengers,
                message: message,
                affectedStationID: stop.stationID
            ))
        }
        return warnings
    }

    private func criticalStops(for route: Route) -> [RouteStationStop] {
        var result: [RouteStationStop] = []
        var seen = Set<String>()
        for segment in route.segments where segment.type.isTransit {
            for stop in [segment.stationStops.first, segment.stationStops.last].compactMap({ $0 })
                where seen.insert(stop.stationID).inserted {
                result.append(stop)
            }
        }
        return result
    }

    private func stepFreeAssessment(
        route: Route,
        criticalStations: [Station],
        expectedStationCount: Int
    ) -> RouteStepFreeAssessment {
        if route.warnings.contains(where: { $0.type == .stairsDetected }) {
            return .barrierDetected
        }
        guard expectedStationCount >= 2,
              criticalStations.count == expectedStationCount else {
            return .unknown
        }
        let access = criticalStations.compactMap(\.accessibility)
        guard access.count == criticalStations.count else { return .unknown }
        if access.allSatisfy(\.isFullyAccessible) { return .confirmed }
        if access.allSatisfy({ $0.hasElevator || $0.hasWheelchairRamp }) { return .likely }
        return .unknown
    }

    private func accessibilityScore(for route: Route, preferences: AccessibilityPreference) -> Double {
        var score: Double = 1.0

        if preferences.requiresWheelchairAccess {
            if !route.stepFreeAssessment.supportsStepFreeTravel {
                score -= 0.5
            }
        }

        if preferences.avoidStairs {
            for segment in route.segments {
                for note in segment.accessibilityNotes where note.localizedCaseInsensitiveContains("stairs") || note.contains("楼梯") || note.contains("階梯") {
                    score -= 0.2
                }
            }
        }

        for warning in route.warnings {
            switch warning.type {
            case .stairsDetected:
                score -= preferences.avoidStairs ? 0.3 : 0.1
            case .stepFreeAccessUnconfirmed:
                score -= preferences.requiresWheelchairAccess ? 0.3 : 0.15
            case .longWalk:
                score -= 0.1
            default:
                break
            }
        }

        return max(0, min(1, score))
    }

    func sortRoutes(
        _ routes: [Route],
        by strategy: RoutePreference,
        preferences: AccessibilityPreference,
        tripAnchor: TripTimeAnchor = .now
    ) -> [Route] {
        let ranked = rankedRoutes(routes, by: strategy, preferences: preferences, tripAnchor: tripAnchor)
        // A hard accessibility requirement demotes routes with a DETECTED barrier under
        // every strategy, not just the step-free sort — otherwise the toggles have no
        // visible effect on the default orderings. Demoted, not removed: hiding every
        // option behind an unmet requirement helps no one, and the route cards carry the
        // barrier warning explaining the ordering. (Path-level avoidance would need
        // accessibility data inside the routing graph — not available there today.)
        guard preferences.requiresWheelchairAccess || preferences.prefersElevator else { return ranked }
        let clear = ranked.filter { $0.stepFreeAssessment != .barrierDetected }
        let barriers = ranked.filter { $0.stepFreeAssessment == .barrierDetected }
        return clear + barriers
    }

    private func rankedRoutes(
        _ routes: [Route],
        by strategy: RoutePreference,
        preferences: AccessibilityPreference,
        tripAnchor: TripTimeAnchor
    ) -> [Route] {
        switch strategy {
        case .metroFirst:
            return routes.sorted {
                if $0.strategy != $1.strategy {
                    return $0.strategy == .metroFirst
                }
                return $0.totalDuration < $1.totalDuration
            }
        case .fastest:
            return routes.sorted {
                if $0.strategy != $1.strategy {
                    return $0.strategy == .fastest
                }
                return $0.totalDuration < $1.totalDuration
            }
        case .leastWalking:
            return routes.sorted {
                if $0.strategy != $1.strategy {
                    return $0.strategy == .leastWalking
                }
                return $0.walkingDistance < $1.walkingDistance
            }
        case .stepFreeSupport:
            return routes.sorted { accessibilityScore(for: $0, preferences: preferences) > accessibilityScore(for: $1, preferences: preferences) }
        case .fewestTransfers:
            return routes.sorted {
                ($0.transferCount, $0.totalDuration, $0.walkingDistance) <
                    ($1.transferCount, $1.totalDuration, $1.walkingDistance)
            }
        case .leastConfusing:
            return routes.sorted { ranked($0, before: $1, score: routeClarityScore, tripAnchor: tripAnchor) }
        case .luggageFriendly:
            return routes.sorted { ranked($0, before: $1, score: luggageScore, tripAnchor: tripAnchor) }
        case .elderlyFriendly:
            return routes.sorted { ranked($0, before: $1, score: elderlyScore, tripAnchor: tripAnchor) }
        case .officialDataOnly:
            return routes.sorted { ranked($0, before: $1, score: officialDataScore, tripAnchor: tripAnchor) }
        }
    }

    private func routeClarityScore(_ route: Route) -> Double {
        officialDataScore(route) - Double(route.transferCount * 20) - route.walkingDistance / 100
    }

    private func luggageScore(_ route: Route) -> Double {
        accessibilityScore(for: route, preferences: .default) * 100 +
            stepFreeScore(route) -
            Double(route.transferCount * 18) - route.walkingDistance / 80 -
            Double(route.warnings.count * 12)
    }

    private func elderlyScore(_ route: Route) -> Double {
        accessibilityScore(for: route, preferences: .default) * 120 +
            stepFreeScore(route) -
            Double(route.transferCount * 22) - route.walkingDistance / 70 -
            Double(route.warnings.count * 15)
    }

    private func stepFreeScore(_ route: Route) -> Double {
        switch route.stepFreeAssessment {
        case .confirmed: return 20
        case .likely: return 12
        case .unknown: return 0
        case .barrierDetected: return -25
        }
    }

    private func officialDataScore(_ route: Route) -> Double {
        let coverage = route.dataCoverage
        return Double(
            coverage.officialAccessibilityCount * 3 +
            coverage.officialScheduleCount * 2 +
            coverage.officialFacilityCount
        )
    }

    private func ranked(_ lhs: Route, before rhs: Route, score: (Route) -> Double, tripAnchor: TripTimeAnchor) -> Bool {
        let lhsScore = score(lhs)
        let rhsScore = score(rhs)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        if lhs.warnings.count != rhs.warnings.count { return lhs.warnings.count < rhs.warnings.count }
        if lhs.walkingDistance != rhs.walkingDistance { return lhs.walkingDistance < rhs.walkingDistance }
        if lhs.totalDuration != rhs.totalDuration { return lhs.totalDuration < rhs.totalDuration }
        return false
    }
}

extension Route {
    /// The pack the trip *starts* in, and nothing more. A trip spans packs now, so anything about
    /// one particular station has to ask that station — see `RouteStationStop.packCityID`.
    var networkCityID: String? {
        MetroStationIdentifier.cityID(of: originStationID)
    }
}

enum RoutePlanningError: Error {
    case stationNotFound
    case noRouteFound
    case networkError
    case outsideSubwayCoverage
    case placeSearchUnavailable
}

extension RoutePlanningError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .stationNotFound:
            return AppLocalization.localized("Station not found. Try another station name.")
        case .noRouteFound:
            return AppLocalization.localized("No route found between these stations.")
        case .networkError:
            return AppLocalization.localized("Network connection failed. Try again later.")
        case .outsideSubwayCoverage:
            return AppLocalization.localized("Journey is outside supported subway coverage")
        case .placeSearchUnavailable:
            return AppLocalization.localized("Place search requires a network connection")
        }
    }
}
