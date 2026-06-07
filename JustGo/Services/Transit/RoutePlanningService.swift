import Foundation

final class RoutePlanningService {
    private let aMapService: AMapService

    init(aMapService: AMapService) {
        self.aMapService = aMapService
    }

    func planRoute(
        from originName: String,
        to destinationName: String,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none
    ) async throws -> [Route] {
        async let originPlaces = aMapService.searchPlaces(keyword: originName, city: city, limit: 8)
        async let destinationPlaces = aMapService.searchPlaces(keyword: destinationName, city: city, limit: 8)

        let originPlace = try await originPlaces.first
        let destinationPlace = try await destinationPlaces.first

        guard let origin = originPlace,
              let destination = destinationPlace else {
            throw RoutePlanningError.stationNotFound
        }

        return try await aMapService.planTransitRoute(
            from: origin,
            to: destination,
            city: city,
            accessibilityFilter: accessibilityFilter
        )
    }

    func planRoute(
        from origin: TransitPlace,
        to destination: TransitPlace,
        city: String,
        accessibilityFilter: AccessibilityFilter = .none
    ) async throws -> [Route] {
        try await aMapService.planTransitRoute(
            from: origin,
            to: destination,
            city: city,
            accessibilityFilter: accessibilityFilter
        )
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

enum RoutePlanningError: Error {
    case stationNotFound
    case noRouteFound
    case networkError
    case realTimeDataUnavailable
    case trainScheduleUnavailable
    case amapScheduleLookupNotEnabled
    case amapServiceDiagnostic(AMapResponseDiagnostic)
    case amapNoScheduleForLine(AMapResponseDiagnostic)
    case amapAPIKeyMissing
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
        case .realTimeDataUnavailable:
            return AppLocalization.localized("Live countdown unavailable")
        case .trainScheduleUnavailable:
            return AppLocalization.localized("Schedule unavailable")
        case .amapScheduleLookupNotEnabled:
            return AppLocalization.localized("AMap schedule lookup is not enabled")
        case .amapServiceDiagnostic(let diagnostic):
            return diagnostic.userMessage
        case .amapNoScheduleForLine(let diagnostic):
            return diagnostic.userMessage
        case .amapAPIKeyMissing:
            return AppLocalization.localized("Add an AMap Web API key to enable public transit routing and place search.")
        }
    }
}

enum RoutePreference: String, Codable, CaseIterable, Identifiable {
    case metroFirst
    case fastest
    case leastWalking
    case fewestTransfers
    case leastConfusing
    case luggageFriendly
    case elderlyFriendly
    case officialDataOnly
    case stepFreeSupport

    var id: Self { self }

    var title: String {
        switch self {
        case .metroFirst:
            return "Metro First"
        case .fastest:
            return "Fastest"
        case .leastWalking:
            return "Least Walking"
        case .fewestTransfers: return "Fewest Transfers"
        case .leastConfusing: return "Least Confusing"
        case .luggageFriendly: return "Luggage Friendly"
        case .elderlyFriendly: return "Elderly Friendly"
        case .officialDataOnly: return "Official Data Only"
        case .stepFreeSupport: return "Step-Free Support"
        }
    }

    var icon: String {
        switch self {
        case .metroFirst:
            return "tram.fill"
        case .fastest:
            return "clock"
        case .leastWalking:
            return "figure.walk"
        case .fewestTransfers: return "arrow.triangle.branch"
        case .leastConfusing: return "signpost.right.fill"
        case .luggageFriendly: return "suitcase.fill"
        case .elderlyFriendly: return "figure.walk.motion"
        case .officialDataOnly: return "checkmark.seal.fill"
        case .stepFreeSupport: return "accessibility"
        }
    }

    init(routeStrategy: RouteStrategy) {
        switch routeStrategy {
        case .metroFirst:
            self = .metroFirst
        case .fastest:
            self = .fastest
        case .leastWalking:
            self = .leastWalking
        }
    }

    static let primary: [RoutePreference] = [.fastest, .leastWalking, .fewestTransfers, .leastConfusing]

    var isPrimary: Bool {
        Self.primary.contains(self)
    }
}

final class RouteConfidenceService {
    func confidence(
        for route: Route,
        feasibility: RouteFeasibility,
        preference: RoutePreference,
        alternatives: [Route]
    ) -> RouteConfidence {
        var score = 100
        var positives: [String] = []
        var warnings: [String] = []
        let coverage = route.dataCoverage

        score -= route.transferCount * 8
        score -= min(20, Int(route.walkingDistance / 100))
        if route.transferCount <= 1 {
            positives.append(AppLocalization.localized("Few transfers"))
        }
        if route.walkingDistance < 500 {
            positives.append(AppLocalization.localized("Low walking distance"))
        }

        if coverage.scheduleConfidence == .official {
            positives.append(AppLocalization.localized("Official schedule available"))
        } else {
            score -= 10
            warnings.append(AppLocalization.localized("Official schedule is incomplete"))
        }
        if coverage.stationMapConfidence == .official {
            positives.append(AppLocalization.localized("Official station maps available"))
        } else {
            score -= 10
            warnings.append(AppLocalization.localized("Some station maps are source pending"))
        }
        if coverage.accessibilityConfidence == .official {
            positives.append(AppLocalization.localized("Official accessibility information available"))
        } else {
            score -= 10
            warnings.append(AppLocalization.localized("Some station accessibility data is source pending"))
        }
        score -= min(15, coverage.unknownCoreCount * 5)

        switch feasibility.level {
        case .good:
            positives.append(feasibility.title)
        case .caution:
            score -= 8
            warnings.append(feasibility.title)
        case .risky:
            score -= 20
            warnings.append(feasibility.title)
        case .unknown:
            score -= 10
            warnings.append(feasibility.title)
        }
        if !feasibility.personalReports.isEmpty {
            score -= 15
            warnings.append(AppLocalization.localized("Personal issue reported"))
        }

        if let fewestTransfers = alternatives.map(\.transferCount).min(),
           route.transferCount == fewestTransfers {
            score += 5
            positives.append(AppLocalization.localized("Fewer transfers than alternatives"))
        }
        if coverage.hasOfficialCoreData && coverage.unknownCoreCount == 0 {
            score += 5
        }

        let clampedScore = min(100, max(0, score))
        let level: RouteConfidenceLevel = clampedScore >= 80 ? .high : clampedScore >= 60 ? .medium : .low
        return RouteConfidence(
            score: clampedScore,
            level: level,
            explanation: explanation(for: route, preference: preference, level: level),
            positiveReasons: unique(positives),
            warnings: unique(warnings)
        )
    }

    private func explanation(for route: Route, preference: RoutePreference, level: RouteConfidenceLevel) -> String {
        switch preference {
        case .luggageFriendly:
            return AppLocalization.localized("Best for luggage: lower walking and fewer difficult changes.")
        case .elderlyFriendly:
            return AppLocalization.localized("Easier option with less walking, fewer transfers, and clearer data.")
        case .leastConfusing:
            return AppLocalization.localized("Simpler route with fewer changes and clearer station information.")
        case .officialDataOnly:
            return AppLocalization.localized("Prioritized because more official station information is available.")
        case .fewestTransfers:
            return AppLocalization.localized("Prioritized for fewer line changes.")
        default:
            if level == .high {
                return AppLocalization.localized("This route is likely to be smooth based on available data.")
            }
            return AppLocalization.localized("This route works, but check the listed uncertainties before going.")
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
