import Foundation
import CoreLocation
import MapKit

final class RoutePlanningService {
    private let placeSearchProvider: PlaceSearchProviding
    private let routeProvider: TransitRouteProviding
    private let officialStationData: OfficialStationDataProviding
    private let cityService: CityService

    init(
        placeSearchProvider: PlaceSearchProviding,
        routeProvider: TransitRouteProviding,
        officialStationData: OfficialStationDataProviding,
        cityService: CityService
    ) {
        self.placeSearchProvider = placeSearchProvider
        self.routeProvider = routeProvider
        self.officialStationData = officialStationData
        self.cityService = cityService
    }

    func planRoute(
        from originName: String,
        to destinationName: String,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none
    ) async throws -> [Route] {
        let region = cityService.getCity(byID: city).flatMap { $0.id == "automatic" ? nil : $0 }.map {
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

        return try await planRoute(from: origin, to: destination, city: city, accessibilityFilter: accessibilityFilter)
    }

    func planRoute(
        from origin: TransitPlace,
        to destination: TransitPlace,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none
    ) async throws -> [Route] {
        let routes = try await routeProvider.routes(
            from: origin,
            to: destination,
            accessibilityFilter: accessibilityFilter
        )
        var enrichedRoutes: [Route] = []
        for route in routes {
            var route = route
            let routeCityID = route.networkCityID ?? city
            let criticalStops = criticalStops(for: route)
            route.dataCoverage = await officialStationData.routeCoverage(
                cityID: routeCityID,
                stationNames: criticalStops.map(\.name)
            )
            let criticalStations = await officialStationData.enrichStations(
                criticalStops.compactMap { stop in
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
            enrichedRoutes.append(route)
        }
        return enrichedRoutes
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

    func sortRoutes(_ routes: [Route], by strategy: RoutePreference, preferences: AccessibilityPreference) -> [Route] {
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
            return routes.sorted { ranked($0, before: $1, score: routeClarityScore) }
        case .luggageFriendly:
            return routes.sorted { ranked($0, before: $1, score: luggageScore) }
        case .elderlyFriendly:
            return routes.sorted { ranked($0, before: $1, score: elderlyScore) }
        case .officialDataOnly:
            return routes.sorted { ranked($0, before: $1, score: officialDataScore) }
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

    private func ranked(_ lhs: Route, before rhs: Route, score: (Route) -> Double) -> Bool {
        let lhsScore = score(lhs)
        let rhsScore = score(rhs)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        if lhs.warnings.count != rhs.warnings.count { return lhs.warnings.count < rhs.warnings.count }
        if lhs.walkingDistance != rhs.walkingDistance { return lhs.walkingDistance < rhs.walkingDistance }
        return lhs.totalDuration < rhs.totalDuration
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

