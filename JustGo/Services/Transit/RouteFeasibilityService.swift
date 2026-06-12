import Foundation

final class RouteFeasibilityService {
    func feasibility(for route: Route, personalReports: [LocalAccessibilityReport]) -> RouteFeasibility {
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
                    reason: warning.message,
                    severity: .risky
                )
            case .stepFreeAccessUnconfirmed:
                hasStepFreeUncertainty = true
                level = max(level, .caution)
                unknowns.append(warning.message)
                bottleneck = bottleneck ?? RouteBottleneck(
                    segmentTitle: AppLocalization.localized("Station access"),
                    reason: warning.message,
                    severity: .caution
                )
            case .longWalk:
                hasLongWalk = true
                level = max(level, .caution)
                reasons.append(warning.message)
                estimatedExtraMinutes += 5
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
                reason: AppLocalization.localized("Stairs detected"),
                severity: .risky
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

        let problemReports = personalReports.filter { $0.status.isProblem || $0.severity >= .high }
        if !problemReports.isEmpty {
            level = max(level, .risky)
            estimatedExtraMinutes += min(15, problemReports.count * 5)
            let titles = problemReports.prefix(2).map { "\($0.itemType.title): \($0.displayNote)" }
            reasons.append(AppLocalization.text(
                english: "Your personal reports affect this route: \(titles.joined(separator: "; "))",
                chinese: "你的个人记录影响此路线：\(titles.joined(separator: "；"))"
            ))
            bottleneck = bottleneck ?? RouteBottleneck(
                segmentTitle: AppLocalization.localized("Personal report"),
                reason: problemReports.first?.displayNote ?? AppLocalization.localized("You reported an issue"),
                severity: .risky
            )
        }

        let title: String
        if !problemReports.isEmpty {
            title = AppLocalization.localized("Personal issue reported")
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
            personalReports: personalReports,
            bottleneck: bottleneck,
            estimatedExtraMinutes: estimatedExtraMinutes
        )
    }
}
