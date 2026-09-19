import Foundation
import CoreLocation
import MapKit

/// The operator's service hours for one boarding station, and which service day they describe. The
/// note qualifies every window: Hangzhou publishes a weekday-only timetable, and those times shown
/// on a Saturday without it are a claim the operator never made.
struct BoardingServiceHours {
    let windows: [StationServiceWindow]
    let serviceDayNote: String?

    static let none = BoardingServiceHours(windows: [], serviceDayNote: nil)
}

/// One trip's verdict on whether it can be ridden when it departs. `closedServices` are the line
/// directions an operator definitively says are not running when this rider would board them.
/// Search state, not a field on `Route`: `ActiveTripStore` persists routes, and a stale "10号线 was
/// shut" from last night is worse than no answer.
struct ServiceReading {
    let status: RouteServiceStatus
    let warning: RouteWarning?
    let closedServices: Set<ClosedServiceDirection>

}

final class RoutePlanningService {
    private let placeSearchProvider: PlaceSearchProviding
    private let routeProvider: TransitRouteProviding
    private let officialStationData: OfficialStationDataProviding
    private let walkingRoutes: WalkingRouteProviding
    /// The operator's own answer about a station, fetched on the rider's device. Optional because
    /// a route is still a route without it, and because most cities have no such source.
    private let officialStationInformation: (any OfficialStationInformationProviding)?
    private let stationInformationDirectory: StationInformationDirectory?
    private let tripObservations: (any TripObservationProviding)?
    private let serviceHoursResolver = ServiceHoursResolver()

    init(
        placeSearchProvider: PlaceSearchProviding,
        routeProvider: TransitRouteProviding,
        officialStationData: OfficialStationDataProviding,
        walkingRoutes: WalkingRouteProviding = MapKitWalkingRouteProvider(),
        officialStationInformation: (any OfficialStationInformationProviding)? = nil,
        stationInformationDirectory: StationInformationDirectory? = nil,
        tripObservations: (any TripObservationProviding)? = nil
    ) {
        self.placeSearchProvider = placeSearchProvider
        self.routeProvider = routeProvider
        self.officialStationData = officialStationData
        self.walkingRoutes = walkingRoutes
        self.officialStationInformation = officialStationInformation
        self.stationInformationDirectory = stationInformationDirectory
        self.tripObservations = tripObservations
    }

    func planRoute(
        from origin: TransitPlace,
        to destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter = .none,
        tripAnchor: TripTimeAnchor = .now
    ) async throws -> [Route] {
        // Walking is a real answer, so a trip to a nearby station need not be a train ride out and
        // back. Started beside the search: one MKDirections call, independent of it.
        async let directWalk = directWalkingRoute(from: origin, to: destination)
        // Started beside the search for the same reason: a MapKit call the graph does not wait on.
        let driveTask = Task { [weak self] in
            await self?.directDrivingRoute(from: origin, to: destination) ?? nil
        }

        let metroRoutes: [Route]
        do {
            metroRoutes = try await routeProvider.routes(
                from: origin,
                to: destination,
                accessibilityFilter: accessibilityFilter,
                excludingServices: []
            )
        } catch {
            // No train answer at all. Within walking distance that is the answer; otherwise the
            // original error is the honest reply.
            if let walk = await directWalk { return including(await driveTask.value, beside: [walk]) }
            if let drive = await driveTask.value { return [drive] }
            throw error
        }

        // Anything the rider could beat on foot is not worth showing, which also rules out any
        // out-and-back path.
        let walk = await directWalk
        let routes = walk.map { walk in metroRoutes.filter { $0.totalDuration < walk.totalDuration } }
            ?? metroRoutes
        guard !routes.isEmpty else {
            // Every alternative lost to walking, which means walking is the plan.
            if let walk { return including(await driveTask.value, beside: [walk]) }
            throw RoutePlanningError.noRouteFound
        }

        // Started here, not awaited, and shared by both passes below: the plan's only Baidu call,
        // carrying first and last trains for every line in the response, not only those this pass
        // picked. A `Task`, so its 3-second budget overlaps enrichment rather than preceding it.
        let observation = Task { [weak self] in
            await self?.observations(
                from: origin.routeCoordinate,
                to: destination.routeCoordinate
            ) ?? .none
        }

        // The walk was compared against these trains before enrichment knew the clock. A shut train
        // is not faster than walking, so whenever nothing listed can be boarded, the walk comes
        // back.
        func answer(_ routes: [Route]) async -> [Route] {
            guard let walk, !routes.contains(where: { !$0.serviceStatus.blocksBoarding }) else {
                return including(await driveTask.value, beside: routes)
            }
            return including(await driveTask.value, beside: routes + [walk])
        }

        let planned = await enrichAll(
            routes,
            origin: origin,
            destination: destination,
            accessibilityFilter: accessibilityFilter,
            tripAnchor: tripAnchor,
            observation: observation
        )
        guard !planned.closedServices.isEmpty else {
            return await answer(planned.routes)
        }

        // The graph is time-blind by design; enrichment knows the clock. Rather than teach the
        // search a timetable, tell it which line directions the timetable just ruled out and search
        // again. No network: the graph is cached and the observation already fetched.
        let alternatives: [Route]
        do {
            alternatives = try await routeProvider.routes(
                from: origin,
                to: destination,
                accessibilityFilter: accessibilityFilter,
                excludingServices: planned.closedServices
            )
        } catch {
            // Nothing runs at this hour, which is a real answer and the one already in hand.
            return await answer(planned.routes)
        }
        let viable = walk.map { walk in alternatives.filter { $0.totalDuration < walk.totalDuration } }
            ?? alternatives
        guard !viable.isEmpty else { return await answer(planned.routes) }

        let replanned = await enrichAll(
            viable,
            origin: origin,
            destination: destination,
            accessibilityFilter: accessibilityFilter,
            tripAnchor: tripAnchor,
            observation: observation
        )
        // The re-plan exists to find a train the rider can catch. If nothing in it runs either, the
        // first answer stands.
        guard replanned.routes.contains(where: { !$0.serviceStatus.blocksBoarding }) else {
            return await answer(planned.routes)
        }
        // One pass only: a second could ban its way to nothing, and a named shut line serves the
        // rider better than an empty screen.
        return await answer(merging(running: replanned.routes, with: planned.routes))
    }

    /// Enriches a set of alternatives together and reports which lines came back definitively shut.
    private func enrichAll(
        _ routes: [Route],
        origin: TransitPlace,
        destination: TransitPlace,
        accessibilityFilter: AccessibilityFilter,
        tripAnchor: TripTimeAnchor,
        observation: Task<TripObservations, Never>
    ) async -> (routes: [Route], closedServices: Set<ClosedServiceDirection>) {
        // Each route's enrichment is independent lookups with no shared mutable state, so the
        // alternatives enrich concurrently.
        let enriched = await withTaskGroup(of: (Int, Route, Set<ClosedServiceDirection>).self) { group in
            for (index, route) in routes.enumerated() {
                group.addTask {
                    let result = await self.enrichedRoute(
                        route,
                        // A POI's own entrance beats its centroid when MapKit knows one: it is the
                        // door the rider walks to.
                        originTarget: CodableCoordinate(
                            origin.entranceCoordinate ?? origin.coordinate
                        ),
                        destinationTarget: CodableCoordinate(
                            destination.entranceCoordinate ?? destination.coordinate
                        ),
                        accessibilityFilter: accessibilityFilter,
                        tripAnchor: tripAnchor,
                    )
                    return (index, result.route, result.closedServices)
                }
            }
            var collected: [(Int, Route, Set<ClosedServiceDirection>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        var closed = enriched.reduce(into: Set<ClosedServiceDirection>()) { $0.formUnion($1.2) }
        // Awaited only now, so it ran beside enrichment. On the second pass it is already resolved.
        let applied = applying(await observation.value, to: enriched.map(\.1), tripAnchor: tripAnchor)
        closed.formUnion(applied.closedServices)
        return (applied.routes, closed)
    }

    /// Puts the trains a rider can board above the ones they cannot, keeping both: the shut one,
    /// named and badged, is what explains why something slower is offered.
    private func merging(running: [Route], with original: [Route]) -> [Route] {
        var seen = Set(running.map(Self.itinerarySignature))
        var merged = running
        for route in original where seen.insert(Self.itinerarySignature(route)).inserted {
            merged.append(route)
        }
        return merged
    }

    /// The rides that make this trip what it is, so two passes that rediscover one journey list it
    /// once. Duration and walking are ignored: the same itinerary measured against a different door
    /// is still the same itinerary.
    private static func itinerarySignature(_ route: Route) -> String {
        route.segments
            .filter { $0.type.isTransit }
            .map { "\($0.lineName ?? "")>\($0.fromStationID ?? "")>\($0.toStationID ?? "")" }
            .joined(separator: "|")
    }

    /// Applies everything one trip-observation call answers: measured corridor lengths and the
    /// gate-to-gate fare. Re-costed changes feed `totalDuration`, which the sorters already order
    /// by, so a 231 m interchange beats a 689 m one without a separate ranking rule.
    ///
    /// Optional and bounded: an upgrade to an answer the app already has offline. No key, no
    /// network or a slow network leaves the modelled cost and no fare, never a failed or delayed
    /// plan.
    private func observations(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> TripObservations {
        guard let tripObservations else { return .none }
        // Started outside the deadline, so the deadline stops the waiting and not the request: left
        // to finish, the answer lands in the service's cache and the next plan reads it free.
        // `withDeadline` returns on time because the client's request is genuinely cancellable.
        let request = Task { await tripObservations.observations(from: origin, to: destination) }
        let observed = try? await withDeadline(seconds: 3) {
            CancellationError()
        } operation: {
            await request.value
        }
        return observed ?? .none
    }

    /// Applies one already-fetched observation to a set of alternatives. Pure and synchronous, so
    /// the re-plan reuses the response.
    private func applying(
        _ observed: TripObservations,
        to routes: [Route],
        tripAnchor: TripTimeAnchor
    ) -> (routes: [Route], closedServices: Set<ClosedServiceDirection>) {
        // A direct ride has no change to measure but still has a fare.
        guard !observed.isEmpty, !routes.isEmpty else { return (routes, []) }

        // Transfers first, then annotations: re-costing rebuilds the route through
        // `replacingSegments`, so annotations go last where nothing can drop them.
        var closed: Set<ClosedServiceDirection> = []
        let applied = routes.map { route -> Route in
            let measured = measuringTransfers(in: route, with: observed.transfers)
            let timed = upgradingServiceHours(of: measured, with: observed, tripAnchor: tripAnchor)
            closed.formUnion(timed.closedServices)
            return pricing(timed.route, with: observed)
        }
        return (applied, closed)
    }

    /// Answers "can I still get home?" for cities no operator answers for, and prices the
    /// consequence of no. Only routes still reading `.unknown` are touched, so an operator's own
    /// timetable keeps the last word. No bundled pack carries a timetable, because operator
    /// schedule content must not be committed. The taxi price arrives in the same response.
    private func upgradingServiceHours(
        of route: Route,
        with observed: TripObservations,
        tripAnchor: TripTimeAnchor
    ) -> (route: Route, closedServices: Set<ClosedServiceDirection>) {
        let departure = TripTimeContext(
            anchor: tripAnchor,
            totalDuration: route.totalDuration
        ).departureDate

        var upgraded = route
        var closedServices: Set<ClosedServiceDirection> = []
        if route.serviceStatus == .unknown, !observed.lineHours.isEmpty {
            let verdict = serviceVerdict(for: route, departure: departure) { segment in
                guard let station = segment.fromStationName, let line = segment.lineName else { return [] }
                return observed.lineHours
                    .filter { $0.matches(lineName: line, boardingStation: station) }
                    .map {
                        StationServiceWindow(
                            lineName: $0.lineName,
                            // `direct_text` ("潞阳方向") names the service Baidu costed, which is what
                            // makes these hours attributable: 花园桥 → 潞城 comes back 05:27–22:45, the
                            // full run, not the 23:56 short-turn.
                            direction: $0.directionText,
                            firstTime: $0.firstTrain,
                            lastTime: $0.lastTrain
                        )
                    }
            }
            if verdict.status != .unknown {
                upgraded.serviceStatus = verdict.status
                closedServices = verdict.closedServices
                if let warning = verdict.warning { upgraded.warnings.append(warning) }
            }
        }

        // Only when the rider is against the clock: a taxi price beside a normal trip is noise, and
        // beside one nobody could time it is a guess.
        switch upgraded.serviceStatus {
        case .lastTrainSoon, .serviceEndedToday:
            // China Standard Time: the tariff windows are the city's local hours, whatever timezone
            // the trip is planned from.
            upgraded.missedTrainTaxiYuan = observed.taxi?.yuan(
                atHour: ChinaClock.minutesOfDay(of: departure) / 60
            )
        case .running, .notYetStarted, .unknown:
            break
        }
        return (upgraded, closedServices)
    }

    /// Re-costs the changes this route makes, where a corridor was measured for one.
    private func measuringTransfers(in route: Route, with geometries: [TransferGeometry]) -> Route {
        guard !geometries.isEmpty else { return route }

        var didMeasure = false
        var segments = route.segments
        for index in segments.indices {
            let segment = segments[index]
            guard segment.type == .transfer,
                  let station = segment.fromStationName,
                  let toLine = segment.lineName,
                  let fromLine = segment.incomingLineName else { continue }
            let key = TransferKey(stationID: station, fromLineID: fromLine, toLineID: toLine)
            guard let match = geometries.first(where: { $0.matches(key) }) else { continue }
            segments[index] = segment.measuringTransfer(distance: Double(match.distanceMetres))
            didMeasure = true
        }
        guard didMeasure else { return route }

        let corrected = route.totalDuration
            - route.segments.reduce(0) { $0 + ($1.type == .transfer ? $1.duration : 0) }
            + segments.reduce(0) { $0 + ($1.type == .transfer ? $1.duration : 0) }
        return route.replacingSegments(segments, totalDuration: max(60, corrected))
    }

    /// Attaches a fare only to a route that boards and alights where the priced journey did. A
    /// Chinese metro fare is charged on the entry and exit gates, not the path between them, so an
    /// observed fare is this route's when the gates agree and a different number when they do not.
    /// No match leaves `fare` nil and the screens print nothing.
    private func pricing(_ route: Route, with observed: TripObservations) -> Route {
        let rides = route.segments.filter { $0.type.isTransit }
        guard let boarding = rides.first?.fromStationName,
              let alighting = rides.last?.toStationName,
              let fare = observed.railFares.first(where: {
                  $0.matches(boarding: boarding, alighting: alighting)
              }) else { return route }

        var priced = route
        priced.fare = RouteFare(
            yuan: fare.yuan,
            // Only worth naming when it actually undercuts the fare the rider would otherwise pay.
            cheaperBus: observed.cheaperBus.flatMap { bus in
                guard bus.yuan < fare.yuan else { return nil }
                return RouteFare.BusAlternative(yuan: bus.yuan, duration: bus.duration)
            }
        )
        return priced
    }

    // MARK: - Official station information

    /// The operator's own first and last train at one boarding station, one row per direction and
    /// service, for the trip screen. Same lookup the planner makes for the same station, so no
    /// extra request; the pack is the fallback for a city that ships redistributable times.
    func boardingServiceWindows(
        stationID: String,
        stationName: String,
        cityID: String,
        lineName: String?
    ) async -> BoardingServiceHours {
        let snapshot = await officialStationSnapshots(
            for: [RouteStationStop(
                stationID: stationID,
                name: stationName,
                lineName: lineName,
                lineColorHex: nil,
                coordinate: nil,
                arrivalTimeText: nil,
                isTransfer: false
            )]
        )[stationName]
        let windows = Self.serviceWindows(from: snapshot)
        guard let lineName, !lineName.isEmpty else {
            return BoardingServiceHours(windows: windows, serviceDayNote: snapshot?.serviceDayNote)
        }
        let matched = windows.filter {
            fullTransitLineName($0.lineName) == fullTransitLineName(lineName) ||
                !transitLineReferences($0.lineName).isDisjoint(with: transitLineReferences(lineName))
        }
        // No line match is no answer: another line's first and last train under this ride's heading
        // would be wrong.
        return BoardingServiceHours(windows: matched, serviceDayNote: snapshot?.serviceDayNote)
    }

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
    /// The pack's count comes from OpenStreetMap `wheelchair` tags (about 20% of the network); the
    /// larger of the two stands, so the pack still speaks for cities with no official source.
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
        // The same for timetables: the operator publishes first and last trains per line and
        // direction.
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

    /// Whether the subway is running for this trip, resolved for every ride at the moment it
    /// departs. Operator pages are the source (read on the device and cached device-only): no
    /// bundled pack carries a timetable. The train a rider misses is usually the connection, later
    /// and closer to closing, so every leg is checked.
    private func serviceStatus(
        for route: Route,
        cityID: String,
        snapshots: [String: OfficialStationInformationSnapshot],
        tripAnchor: TripTimeAnchor
    ) async -> ServiceReading {
        let departure = TripTimeContext(
            anchor: tripAnchor,
            totalDuration: route.totalDuration
        ).departureDate

        // Gathered first so the verdict below is a pure reduction, shared with the fallback path
        // that has no operator to await.
        var windowsBySegment: [UUID: [StationServiceWindow]] = [:]
        for segment in route.segments {
            guard segment.type.isTransit, let stationName = segment.fromStationName else { continue }

            // The operator first, the authority on its own timetable; the pack as fallback for a
            // city that later ships redistributable times.
            let official = Self.serviceWindows(from: snapshots[stationName])
            windowsBySegment[segment.id] = official.isEmpty
                ? await officialStationData.serviceWindows(
                    cityID: segment.packCityID ?? cityID,
                    stationName: stationName
                )
                : official
        }

        return serviceVerdict(for: route, departure: departure) { windowsBySegment[$0.id] ?? [] }
    }

    /// Reduces a route's rides to one verdict: a definite failure on any leg beats "fine" on the
    /// others, and a leg nobody can answer for keeps the trip `.unknown` rather than borrowing a
    /// verified leg's answer.
    private func serviceVerdict(
        for route: Route,
        departure: Date,
        windows: (RouteSegment) -> [StationServiceWindow]
    ) -> ServiceReading {
        var elapsed: TimeInterval = 0
        var worst: (verdict: ServiceHoursVerdict, segment: RouteSegment)?
        var closedServices: Set<ClosedServiceDirection> = []
        var sawUnknown = false
        var sawAnswer = false

        for segment in route.segments {
            defer { elapsed += segment.duration }
            guard segment.type.isTransit, segment.fromStationName != nil else { continue }

            let verdict = serviceHoursResolver.verdict(
                boardingLineName: segment.lineName,
                onwardStationNames: segment.transitContext?.onwardStationNames,
                alightingStationName: segment.toStationName,
                windows: windows(segment),
                at: departure.addingTimeInterval(elapsed)
            )
            if verdict.status == .unknown {
                sawUnknown = true
                continue
            }
            sawAnswer = true
            // Only a definitive closure takes something out of the search
            // (`ServiceHoursVerdict.isDefinitive`): a merged window that reads as running may be
            // another direction's train. And the direction, not the line: the verdict came from
            // this rider's onward stations, and at 天通苑南 on 5号线 southbound ends at 22:51 while
            // northbound runs to 23:57. `directionNextStationID` names the direction as an oriented
            // hop.
            if verdict.isDefinitive,
               let context = segment.transitContext,
               let next = context.directionNextStationID,
               verdict.status == .serviceEndedToday || verdict.status.isNotYetStarted {
                closedServices.insert(ClosedServiceDirection(
                    lineID: context.lineID,
                    fromStationID: context.boardingStationID,
                    toStationID: next
                ))
            }
            if verdict.status.severity > (worst?.verdict.status.severity ?? 0) {
                worst = (verdict, segment)
            }
        }

        guard let worst else {
            // Nothing to report: every leg is inside its hours, or nobody could answer for one and
            // "running" would borrow another leg's answer.
            return ServiceReading(
                status: sawAnswer && !sawUnknown ? .running : .unknown,
                warning: nil,
                closedServices: []
            )
        }

        // Name the leg on a trip with a change: the ride that fails is usually not the one the
        // rider is standing at.
        let banner = worst.verdict.status.bannerText
        let message: String? = {
            guard let banner else { return nil }
            guard route.transferCount > 0, let station = worst.segment.fromStationName else { return banner }
            return AppLocalization.text(
                english: "\(station): \(banner)",
                simplified: "\(station)：\(banner)",
                traditional: "\(station)：\(banner)"
            )
        }()

        return ServiceReading(
            status: worst.verdict.status,
            warning: worst.verdict.status.warningType.flatMap { type in
                message.map {
                    RouteWarning(
                        type: type,
                        message: $0,
                        affectedStationID: worst.segment.fromStationID
                    )
                }
            },
            closedServices: closedServices
        )
    }

    /// The operator's first and last trains in the shape the resolver reads. Rows with neither time
    /// are dropped: an empty pool is "no answer", which is what they are.
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
                    destination: service.destination,
                    firstTime: service.firstTrain,
                    lastTime: service.lastTrain
                )
            }
        }
    }

    /// A lift, in the words operators use. Escalators are not step-free access, and counting one
    /// could strand a wheelchair user at the concourse.
    private static func describesStepFreeFacility(_ name: String) -> Bool {
        let stepFree = ["直梯", "垂直电梯", "电梯", "升降平台", "无障碍电梯", "轮椅", "無障礙", "升降機"]
        return stepFree.contains { name.contains($0) }
    }

    /// The operator's exit list laid over the pack's. Beijing signs exits `A`, `B`, `D2`, while
    /// OpenStreetMap leaves many doors unnamed or calls them 东南口. Where the names agree the
    /// surveyed coordinate is kept and the point marked official; an exit nobody surveyed is added
    /// without a coordinate: it exists and is called `A`, and where exactly it stands is not known.
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
                return Self.surveyed(point, namedBy: exit)
            }
            // One door, one exit: the operator lists exactly one exit and exactly one door was
            // surveyed, so they are the same door. Any looser pairing is a guess, and a wrong exit
            // letter sends a rider up the wrong staircase with full confidence.
            var bound = upgraded
            let unnamed = upgraded.enumerated().filter { $0.element.name.trimmingCharacters(in: .whitespaces).isEmpty }
            let unmatched = snapshot.exits.filter { !matchedOfficialNames.contains($0.name) && !$0.name.isEmpty }
            if unnamed.count == 1, unmatched.count == 1, let exit = unmatched.first, let slot = unnamed.first {
                matchedOfficialNames.insert(exit.name)
                bound[slot.offset] = Self.surveyed(slot.element, namedBy: exit)
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

    /// A surveyed door, called what the operator's sign says: the survey keeps the coordinate, the
    /// operator supplies the name and details, and the point becomes official.
    private static func surveyed(_ point: StationAccessPoint, namedBy exit: OfficialStationExitInformation) -> StationAccessPoint {
        StationAccessPoint(
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

    /// Exit names match when they name the same sign. Compared case- and whitespace-insensitively
    /// because OpenStreetMap records `a`, `A` and `A ` for the same door.
    private static func exitNamesMatch(_ official: String, _ surveyed: String) -> Bool {
        let left = official.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let right = surveyed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return !left.isEmpty && !right.isEmpty && left == right
    }

    /// The trip on foot, within 3 km in a straight line; past that walking is not an answer and
    /// only makes `MKDirections` slow.
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

        return Self.singleLegRoute(
            segment,
            from: origin,
            to: destination,
            walkingDistance: segment.distance,
            stepFreeAssessment: segment.walkingDirections?.contains(where: \.hasStairs) == true ? .barrierDetected : .unknown
        )
    }

    /// A journey that is one access leg and nothing else: no station, so no IDs and no
    /// `networkCityID`, which every reader already handles. `.fastest`, because when it is offered it
    /// is the fastest option.
    private static func singleLegRoute(
        _ segment: RouteSegment,
        from origin: TransitPlace,
        to destination: TransitPlace,
        walkingDistance: Double,
        stepFreeAssessment: RouteStepFreeAssessment
    ) -> Route {
        Route(
            id: UUID(),
            origin: origin.name,
            destination: destination.name,
            originStationID: "",
            destinationStationID: "",
            strategy: .fastest,
            segments: [segment],
            totalDuration: segment.duration,
            walkingDistance: walkingDistance,
            totalStops: 0,
            transferCount: 0,
            isFullyAccessible: false,
            stepFreeAssessment: stepFreeAssessment,
            warnings: [],
            accessGuidance: [],
            dataCoverage: .unknown
        )
    }

    /// The whole journey by car: one access leg from MapKit's `.automobile` router, no enrichment,
    /// no fare, no provider quota. No distance ceiling: a drive gets better the further it goes,
    /// which is where the metro's transfers start to cost more than the ride.
    private func directDrivingRoute(from origin: TransitPlace, to destination: TransitPlace) async -> Route? {
        let from = origin.routeCoordinate
        let to = destination.routeCoordinate
        guard from.distance(to: to) >= 1_000 else { return nil }
        guard let segment = await walkingRoutes.accessSegment(
            from: from,
            to: to,
            fromName: origin.name,
            toName: destination.name,
            mode: .driving
        ), segment.type == .driving else {
            return nil
        }

        // Not one metre of this is walked, and `walkingDistance` is what the card prints as "N m walk".
        return Self.singleLegRoute(segment, from: origin, to: destination, walkingDistance: 0, stepFreeAssessment: .unknown)
    }

    /// Adds the drive only where it answers something the trains do not: it is faster than every
    /// train plan, or nothing on rail can be boarded (the honest answer at 01:00).
    private func including(_ drive: Route?, beside routes: [Route]) -> [Route] {
        guard let drive, !routes.isEmpty else { return routes }
        let nothingRuns = routes.allSatisfy { $0.serviceStatus.blocksBoarding }
        let beatsEveryTrain = routes.allSatisfy { drive.totalDuration < $0.totalDuration }
        guard nothingRuns || beatsEveryTrain else { return routes }
        return nothingRuns ? [drive] + routes : routes + [drive]
    }

    private func enrichedRoute(
        _ route: Route,
        originTarget: CodableCoordinate,
        destinationTarget: CodableCoordinate,
        accessibilityFilter: AccessibilityFilter,
        tripAnchor: TripTimeAnchor,
    ) async -> (route: Route, closedServices: Set<ClosedServiceDirection>) {
        var route = route
        // The pack that produced the route. A walking-only plan has none, so the official lookups
        // below find nothing, which is right: no station was involved.
        let routeCityID = route.networkCityID ?? ""
        let criticalStops = criticalStops(for: route)
        let criticalStopNames = criticalStops.map(\.name)

        // Independent lookups, started together and awaited in the order their results are applied.
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
                    // The stop's own pack, not the trip's: on a Dongguan → Guangzhou trip the ends
                    // are in different packs.
                    cityID: stop.packCityID ?? routeCityID
                )
            }
        )
        // The operator's own pages for the stops this trip calls at, started here so the network
        // time overlaps the pack lookups.
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

        // Being routable does not make a station usable: the reviewed catalog marks eight that take
        // no passengers (福寿岭 is a building site, 黄土店 is track with no passenger stop). A plan must
        // not send a rider to a door that does not open without saying so.
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
        // Choose each end's door once, by measured walking distance, and let every surface read
        // that answer, or the timeline and the guide card name different doors. Any access leg, not
        // only a walk: a cycled or driven first mile needs a measured door just as much.
        let originIndex = route.segments.first?.type.isAccessLeg == true ? 0 : nil
        let destinationIndex = route.segments.count > 1 && route.segments.last?.type.isAccessLeg == true
            ? route.segments.count - 1
            : nil
        // Read what the lookups need before starting them: an `async let` body may not capture the
        // mutable `route`.
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
        )
        async let destinationChoiceTask = chooseExit(
            guide: destinationGuide,
            guidance: guidanceByStation,
            stationPositions: stationPositions,
            rider: destinationTarget,
            existing: destinationSegment,
            isArrival: true,
            requiresStepFree: accessibilityFilter.requiresStepFreeEntrance,
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

        return (route, service.closedServices)
    }

    /// Distance below which re-walking the leg to a specific door is not worth an `MKDirections`
    /// round trip: the door is essentially where the graph already sent the rider.
    private static let exitRerouteThresholdMetres: Double = 40

    /// How many of the nearest doors get their walk measured: enough for one door on the wrong side
    /// of a barrier, without a dozen routing calls per plan.
    private static let exitCandidateLimit = 3

    /// The end of a trip, resolved: which door, and the real walk to it.
    private struct ChosenExit {
        let point: StationAccessPoint
        let stepFreeUnavailable: Bool
        /// nil when the walk was not worth measuring; the caller keeps the leg it already had.
        let leg: RouteSegment?
    }

    /// Picks the door for one end of the trip and measures the walk to it. The graph walks to a
    /// station's centre, the only point a node has; left there, the text says "Exit D" while the
    /// map and duration describe a walk to the middle of the station (at 西单, 265 m to a door 34 m
    /// away).
    ///
    /// Straight-line distance alone cannot choose: at 西直门 the nearest door by air is a 698 m walk
    /// because the railway is in the way. The nearest few are measured and the shortest walk wins.
    private func chooseExit(
        guide: RouteAccessGuide?,
        guidance: [String: StationAccessGuidance],
        stationPositions: [String: CodableCoordinate],
        rider: CodableCoordinate,
        existing: RouteSegment?,
        isArrival: Bool,
        requiresStepFree: Bool,
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

        // Nothing to replace, or no station centre to judge against: keep the straight-line pick
        // and spend no calls.
        guard let existing, let centre = stationPositions[guide.stationName] else { return fallback }
        let mode = existing.accessLegMode

        let candidates = ranked.points.filter { point in
            guard let coordinate = point.coordinate else { return false }
            return centre.metres(to: coordinate) > Self.exitRerouteThresholdMetres
        }
        // Comparing doors is free on foot and expensive by bike. MapKit walking and driving legs
        // cost nothing, so every candidate is measured; a cycling leg is a Baidu call per route,
        // per end, per door, and against a 3 km ride the gap between two doors is noise, so the
        // straight-line nearest stands.
        let measurable = mode == .cycling ? Array(candidates.prefix(1)) : candidates
        guard !measurable.isEmpty else { return fallback }

        let riderCoordinate = CLLocationCoordinate2D(latitude: rider.latitude, longitude: rider.longitude)
        let fromName = existing.fromStationName ?? ""
        let toName = existing.toStationName ?? ""

        let legs = walkingRoutes
        let walked = await withTaskGroup(of: (StationAccessPoint, RouteSegment?).self) { group in
            for point in measurable {
                guard let door = point.coordinate else { continue }
                group.addTask {
                    let doorCoordinate = CLLocationCoordinate2D(
                        latitude: door.latitude,
                        longitude: door.longitude
                    )
                    let leg = await legs.accessSegment(
                        from: isArrival ? doorCoordinate : riderCoordinate,
                        to: isArrival ? riderCoordinate : doorCoordinate,
                        fromName: fromName,
                        toName: toName,
                        // The assembler decided how this end is covered. A new door must not turn a
                        // 6 km drive back into a walk: the door moves, the mode does not.
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
        let replacedDuration = route.segments.reduce(0) { $0 + $1.duration }
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

        // The guides quote the walk they belong to, so they are restated from the new legs.
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

        // `longWalk` was judged against the centroid walk; a door can be hundreds of metres from a
        // station's centre, so the verdict can flip either way.
        let walkingDistance = updatedSegments.filter { $0.type.isOnFoot }.reduce(0) { $0 + $1.distance }
        route.walkingDistance = walkingDistance
        route.warnings.removeAll { $0.type == .longWalk }
        if walkingDistance >= 800 {
            route.warnings.append(RouteWarning(
                type: .longWalk,
                message: AppLocalization.localized("Long walking segment"),
                affectedStationID: nil
            ))
        }
        // The headline follows its legs: arrive-by, reminders and the fastest sort all read it.
        let delta = updatedSegments.reduce(0) { $0 + $1.duration } - replacedDuration
        return route.replacingSegments(updatedSegments, totalDuration: max(60, route.totalDuration + delta))
    }

    /// Tags the boarding, transfer and arrival stations of a route with the best-available access
    /// point and its confidence.
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
            // The boarding and arrival doors were already chosen by measured walking distance; take
            // those, so the timeline and the guide card name the same exit. A transfer never leaves
            // the station, so it has no entrance to recommend.
            let chosen: StationAccessPoint?
            switch role {
            case .boarding: chosen = originExit
            case .arrival: chosen = destinationExit
            case .transfer: chosen = nil
            }
            // Downstream (the timeline, the arrival notification) only sees this point, so an
            // unlabeled entrance gets its direction resolved here, while the station is in hand.
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

    /// Replaces the placeholder origin and destination guides with a specific exit and confidence
    /// when station data has one; otherwise the honest "unavailable" guide stays.
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
                    english: "Exit \(point.name) is estimated from station data. Confirm it on site.",
                    simplified: "出入口 \(point.name) 根据车站数据估算，请到现场确认。",
                    traditional: "出入口 \(point.name) 根據車站資料估算，請到現場確認。"
                )]
            }
            // The rider needs step-free access and no entrance here is recorded as step-free. Say
            // so rather than let the nearest exit read as accessible; most entrances are
            // unsurveyed, which is not accessible.
            if recommendation.stepFreeUnavailable {
                notes.append(AppLocalization.text(
                    english: "No step-free entrance is recorded at \(guide.stationName). This is the nearest one.",
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

    /// One warning per boarding, transfer or arrival station the operator does not serve. A
    /// transfer counts: it means getting off one train and onto another, on foot.
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

    func sortRoutes(
        _ routes: [Route],
        by strategy: RoutePreference,
        preferences: AccessibilityPreference,
        tripAnchor: TripTimeAnchor = .now
    ) -> [Route] {
        // Boardable first, whatever the chip says: a shut line's route stays listed and badged, one
        // position down, rather than vanishing or winning the list at 23:50.
        let byStrategy = rankedRoutes(routes, by: strategy, preferences: preferences, tripAnchor: tripAnchor)
        let ranked = byStrategy.filter { !$0.serviceStatus.blocksBoarding }
            + byStrategy.filter { $0.serviceStatus.blocksBoarding }
        // A hard accessibility requirement demotes routes with a detected barrier under every
        // strategy, or the toggles would do nothing visible on the default orderings. Demoted, not
        // removed; the card carries the barrier warning. Avoiding barriers in the path would need
        // accessibility data in the routing graph, which it does not have.
        guard preferences.requiresStepFreeEntrance else { return ranked }
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
            // Ranks on what the chip says: a trip that rides something before one that does not,
            // then the quicker. Only the metric each chip names is compared, so the ordering stays
            // a strict weak ordering `sorted(by:)` requires.
            return routes.sorted {
                let lhsRides = $0.boardingTransitSegment != nil
                let rhsRides = $1.boardingTransitSegment != nil
                if lhsRides != rhsRides { return lhsRides }
                return ($0.totalDuration, $0.transferCount, $0.walkingDistance)
                    < ($1.totalDuration, $1.transferCount, $1.walkingDistance)
            }
        case .fastest:
            return routes.sorted {
                ($0.totalDuration, $0.transferCount, $0.walkingDistance)
                    < ($1.totalDuration, $1.transferCount, $1.walkingDistance)
            }
        case .leastWalking:
            return routes.sorted {
                ($0.walkingDistance, $0.totalDuration, $0.transferCount)
                    < ($1.walkingDistance, $1.totalDuration, $1.transferCount)
            }
        case .fewestTransfers:
            return routes.sorted {
                ($0.transferCount, $0.totalDuration, $0.walkingDistance)
                    < ($1.transferCount, $1.totalDuration, $1.walkingDistance)
            }
        }
    }
}

extension Route {
    /// The pack the trip starts in, and nothing more: a trip can span packs, so anything about one
    /// station asks that station (`RouteStationStop.packCityID`).
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
