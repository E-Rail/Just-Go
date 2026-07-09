import Foundation

final class RouteFeasibilityService {
    func feasibility(for route: Route, aiReportInsights: [AIReportInsight], comfort: RouteComfortForecast? = nil) -> RouteFeasibility {
        var level: RouteFeasibilityLevel = route.stepFreeAssessment.supportsStepFreeTravel ? .good : .unknown
        var reasons: [String] = []
        var unknowns: [String] = []
        var estimatedExtraMinutes = 0
        var bottleneck: RouteBottleneck?
        var hasStepFreeUncertainty = false
        var hasAccessibilityRisk = route.stepFreeAssessment == .barrierDetected
        var hasLongWalk = false

        switch route.stepFreeAssessment {
        case .confirmed, .likely:
            reasons.append(AppLocalization.localized("Step-free likely from available station data."))
        case .barrierDetected:
            level = .risky
            reasons.append(AppLocalization.localized("Step-free barrier detected"))
        case .unknown:
            break
        }

        for warning in route.warnings {
            switch warning.type {
            case .stairsDetected:
                hasAccessibilityRisk = true
                level = max(level, .risky)
                reasons.append(warning.message)
                estimatedExtraMinutes += 8
                bottleneck = bottleneck ?? RouteBottleneck(
                    segmentTitle: AppLocalization.localized("Walking or transfer step"),
                    reason: warning.message
                )
            case .stepFreeAccessUnconfirmed:
                hasStepFreeUncertainty = true
                level = max(level, .caution)
                unknowns.append(warning.message)
                bottleneck = bottleneck ?? RouteBottleneck(
                    segmentTitle: AppLocalization.localized("Station access"),
                    reason: warning.message
                )
            case .longWalk:
                hasLongWalk = true
                level = max(level, .caution)
                reasons.append(warning.message)
                estimatedExtraMinutes += 5
            case .serviceEnded, .serviceNotStarted:
                level = max(level, .risky)
                reasons.append(warning.message)
            case .lastTrainSoon:
                level = max(level, .caution)
                reasons.append(warning.message)
            case .elevatorOutage, .escalatorOutage, .serviceDisruption, .crowding:
                level = max(level, .caution)
                reasons.append(warning.message)
            }
        }

        let walkingSteps = route.segments.flatMap { $0.walkingDirections ?? [] }
        if walkingSteps.contains(where: \.hasStairs) {
            hasAccessibilityRisk = true
            level = max(level, .risky)
            reasons.append(AppLocalization.localized("Apple Maps walking directions mention stairs."))
            estimatedExtraMinutes += 8
            bottleneck = bottleneck ?? RouteBottleneck(
                segmentTitle: AppLocalization.localized("Walking segment"),
                reason: AppLocalization.localized("Stairs detected")
            )
        }
        if walkingSteps.contains(where: \.hasElevator) {
            reasons.append(AppLocalization.localized("Apple Maps walking directions mention an elevator."))
        }
        if walkingSteps.contains(where: \.hasRamp) {
            reasons.append(AppLocalization.localized("Apple Maps walking directions mention a ramp."))
        }
        if walkingSteps.contains(where: \.hasEscalator) {
            reasons.append(AppLocalization.localized("Apple Maps walking directions mention an escalator."))
        }

        let riskInsights = aiReportInsights.filter { $0.severity >= .risk }
        if !riskInsights.isEmpty {
            level = max(level, .risky)
            estimatedExtraMinutes += min(15, riskInsights.count * 5)
            let titles = riskInsights.prefix(2).map { "\($0.title): \($0.detail)" }
            reasons.append(AppLocalization.text(
                english: "AI reports flag this route: \(titles.joined(separator: "; "))",
                chinese: "AI 报告提示此路线：\(titles.joined(separator: "；"))"
            ))
            bottleneck = bottleneck ?? RouteBottleneck(
                segmentTitle: AppLocalization.localized("AI report"),
                reason: riskInsights.first?.detail ?? AppLocalization.localized("AI report needs review")
            )
        }

        if let comfort, comfort.level >= .busy || !comfort.activeCrowdControl.isEmpty {
            level = max(level, .caution)
            estimatedExtraMinutes += 5
            reasons.append(comfort.summaryTitle)
        }

        let title: String
        if !riskInsights.isEmpty {
            title = AppLocalization.localized("AI issue reported")
        } else if hasAccessibilityRisk {
            title = AppLocalization.localized("Accessibility risk")
        } else if hasStepFreeUncertainty {
            title = AppLocalization.localized("Step-free not confirmed")
        } else if hasLongWalk {
            title = AppLocalization.localized("Walking-heavy route")
        } else if route.stepFreeAssessment.supportsStepFreeTravel {
            title = AppLocalization.localized("Step-free likely")
        } else {
            title = AppLocalization.localized("Accessibility unknown")
        }

        return RouteFeasibility(
            level: level,
            title: title,
            reasons: reasons.uniqued(),
            unknowns: unknowns.uniqued(),
            aiReportInsights: aiReportInsights,
            bottleneck: bottleneck,
            estimatedExtraMinutes: estimatedExtraMinutes
        )
    }
}
