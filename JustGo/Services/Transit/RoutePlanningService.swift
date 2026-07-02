import Foundation
import CoreLocation
import MapKit

final class RoutePlanningService {
    private let placeSearchProvider: PlaceSearchProviding
    private let routeProvider: TransitRouteProviding
    private let officialStationData: OfficialStationDataProviding
    private let cityService: CityService
    private let comfortForecastService: ComfortForecastService
    private let serviceHoursResolver = ServiceHoursResolver()

    init(
        placeSearchProvider: PlaceSearchProviding,
        routeProvider: TransitRouteProviding,
        officialStationData: OfficialStationDataProviding,
        cityService: CityService,
        comfortForecastService: ComfortForecastService
    ) {
        self.placeSearchProvider = placeSearchProvider
        self.routeProvider = routeProvider
        self.officialStationData = officialStationData
        self.cityService = cityService
        self.comfortForecastService = comfortForecastService
    }

    func planRoute(
        from originName: String,
        to destinationName: String,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none,
        tripAnchor: TripTimeAnchor = .now
    ) async throws -> [Route] {
        let region = cityService.getCity(byID: city).map {
            MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 120_000, longitudinalMeters: 120_000)
        }
        async let originPlaces = placeSearchProvider.searchPlaces(keyword: originName, region: region, limit: 8)
        async let destinationPlaces = placeSearchProvider.searchPlaces(keyword: destinationName, region: region, limit: 8)

        let originPlace = try await originPlaces.first
        let destinationPlace = try await destinationPlaces.first

        guard let origin = originPlace,
              let destination = destinationPlace else {
            throw RoutePlanningError.stationNotFound
        }

        return try await planRoute(from: origin, to: destination, city: city, accessibilityFilter: accessibilityFilter, tripAnchor: tripAnchor)
    }

    func planRoute(
        from origin: TransitPlace,
        to destination: TransitPlace,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none,
        tripAnchor: TripTimeAnchor = .now
    ) async throws -> [Route] {
        let routes = try await routeProvider.routes(
            from: origin,
            to: destination,
            accessibilityFilter: accessibilityFilter
        )

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
                        city: city,
                        accessibilityFilter: accessibilityFilter,
                        tripAnchor: tripAnchor
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

    private func enrichedRoute(
        _ route: Route,
        city: String,
        accessibilityFilter: AccessibilityFilter,
        tripAnchor: TripTimeAnchor
    ) async -> Route {
        var route = route
        let routeCityID = route.networkCityID ?? city
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
                    cityID: routeCityID
                )
            }
        )
        async let crowdControlStations = officialStationData.crowdControlWindows(
            cityID: routeCityID,
            stationNames: criticalStopNames
        )

        route.dataCoverage = await dataCoverage
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

        if let boarding = route.boardingTransitSegment, let boardingName = boarding.fromStationName {
            let windows = await officialStationData.serviceWindows(cityID: routeCityID, stationName: boardingName)
            let boardingMoment = TripTimeContext(anchor: tripAnchor, totalDuration: route.totalDuration).departureDate
            let status = serviceHoursResolver.status(
                boardingLineName: boarding.lineName,
                windows: windows,
                at: boardingMoment
            )
            route.serviceStatus = status
            if let warningType = status.warningType, let banner = status.bannerText {
                route.warnings.append(RouteWarning(type: warningType, message: banner, affectedStationID: nil))
            }
        }
        route.crowdControl = RouteCrowdControl(stations: await crowdControlStations)

        // Per-station entrance/exit guidance (best available: official → estimated → unavailable).
        let guidanceByStation = await officialStationData.stationGuidance(
            cityID: routeCityID,
            stationNames: criticalStopNames
        )
        route.stationGuidance = buildStationGuidance(route: route, guidance: guidanceByStation)
        route.accessGuidance = upgradeAccessGuidance(route.accessGuidance, guidance: guidanceByStation)

        return route
    }

    /// Tags the boarding, transfer, and arrival stations of a route with the best-available
    /// access-point + confidence (and a transfer-corridor hint, when one is authored).
    private func buildStationGuidance(
        route: Route,
        guidance: [String: StationAccessGuidance]
    ) -> [RouteStationGuidance] {
        let transitSegments = route.segments.filter { $0.type.isTransit }
        guard !transitSegments.isEmpty else { return [] }
        var result: [RouteStationGuidance] = []
        var seen = Set<String>()

        func add(_ stop: RouteStationStop, role: RouteStationGuidance.Role, interchange: StationInterchangeHint? = nil) {
            guard seen.insert("\(stop.stationID)-\(role.rawValue)").inserted else { return }
            let access = guidance[stop.name] ?? .empty
            result.append(RouteStationGuidance(
                stationID: stop.stationID,
                stationName: stop.name,
                role: role,
                exit: role == .transfer ? nil : access.primaryAccessPoint,
                interchange: interchange,
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
                let next = transitSegments[index + 1]
                let interchange = (guidance[alight.name] ?? .empty).interchangeHints.first {
                    $0.fromLineName == segment.lineName && $0.toLineName == next.lineName
                }
                add(alight, role: .transfer, interchange: interchange)
            }
        }
        return result
    }

    /// Replaces the placeholder origin/destination access guides with a specific exit + confidence
    /// when station data provides one; otherwise leaves the honest "unavailable" guide untouched.
    private func upgradeAccessGuidance(
        _ guides: [RouteAccessGuide],
        guidance: [String: StationAccessGuidance]
    ) -> [RouteAccessGuide] {
        guides.map { guide in
            let access = guidance[guide.stationName] ?? .empty
            guard let point = access.primaryAccessPoint else { return guide }
            let upgradedPoint = RouteAccessPoint(
                id: point.id,
                name: point.name,
                coordinate: point.coordinate ?? guide.accessPoint?.coordinate,
                isWheelchairLikely: point.isAccessible,
                hasElevatorHint: point.kind == .elevator || point.isAccessible,
                source: point.source
            )
            let notes: [String]
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
            for warning in route.warnings where warning.type == .elevatorOutage {
                score -= 0.3
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
            coverage.officialStationMapCount * 2 +
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
        return comfortPenalty(lhs, tripAnchor: tripAnchor) < comfortPenalty(rhs, tripAnchor: tripAnchor)
    }

    /// Comfort tie-break (lower is calmer). Applied only after every other ranking key is equal,
    /// so it never overrides the rider's chosen strategy.
    private func comfortPenalty(_ route: Route, tripAnchor: TripTimeAnchor) -> Int {
        let tripTime = TripTimeContext(anchor: tripAnchor, totalDuration: route.totalDuration).departureDate
        return comfortForecastService.forecast(for: route.crowdControl, tripTime: tripTime).level.sortValue
    }
}

extension Route {
    var networkCityID: String? {
        let prefix = "network-"
        guard originStationID.hasPrefix(prefix) else { return nil }
        return originStationID.dropFirst(prefix.count).split(separator: "-", maxSplits: 1).first.map(String.init)
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
