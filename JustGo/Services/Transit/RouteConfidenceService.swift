import Foundation

final class RouteConfidenceService {
    func confidence(
        for route: Route,
        feasibility: RouteFeasibility,
        preference: RoutePreference,
        alternatives: [Route],
        comfort: RouteComfortForecast? = nil
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
            positives.append(AppLocalization.text(
                english: "Official station-layout links available",
                simplified: "有官方车站布局链接",
                traditional: "有官方車站佈局連結"
            ))
        } else {
            score -= 10
            warnings.append(AppLocalization.text(
                english: "Some station layouts are unavailable",
                simplified: "部分车站布局不可用",
                traditional: "部分車站佈局不可用"
            ))
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
        if !feasibility.aiReportInsights.isEmpty {
            score -= 15
            warnings.append(AppLocalization.localized("AI issue reported"))
        }

        switch route.serviceStatus {
        case .serviceEndedToday:
            score -= 40
            if let reason = route.serviceStatus.confidenceReason { warnings.append(reason) }
        case .notYetStarted:
            score -= 25
            if let reason = route.serviceStatus.confidenceReason { warnings.append(reason) }
        case .lastTrainSoon:
            score -= 12
            if let reason = route.serviceStatus.confidenceReason { warnings.append(reason) }
        case .running:
            if coverage.scheduleConfidence == .official {
                if let reason = route.serviceStatus.confidenceReason { positives.append(reason) }
            }
        case .unknown:
            break
        }

        if let comfort {
            switch comfort.level {
            case .busy:
                score -= 8
                warnings.append(comfort.summaryTitle)
            case .moderate:
                score -= 3
            case .comfortable:
                positives.append(comfort.summaryTitle)
            case .unknown:
                break
            }
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
            positiveReasons: positives.uniqued(),
            warnings: warnings.uniqued()
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
}
