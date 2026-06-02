import Foundation

final class RouteFeasibilityService {
    func feasibility(for route: Route, personalReports: [LocalAccessibilityReport]) -> RouteFeasibility {
        var level: RouteFeasibilityLevel = route.isFullyAccessible ? .good : .unknown
        var reasons: [String] = []
        var unknowns: [String] = []
        var estimatedExtraMinutes = 0
        var bottleneck: RouteBottleneck?

        if route.isFullyAccessible {
            reasons.append(AppLocalization.localized("Step-free likely from available station data."))
        } else {
            unknowns.append(AppLocalization.localized("Step-free access is not confirmed for every station on this route."))
        }

        for warning in route.warnings {
            switch warning.type {
            case .stairsDetected:
                level = max(level, .risky)
                reasons.append(warning.message)
                estimatedExtraMinutes += 8
                bottleneck = bottleneck ?? RouteBottleneck(
                    segmentTitle: AppLocalization.localized("Walking or transfer step"),
                    reason: warning.message,
                    severity: .risky
                )
            case .stepFreeAccessUnconfirmed:
                level = max(level, .caution)
                unknowns.append(warning.message)
                bottleneck = bottleneck ?? RouteBottleneck(
                    segmentTitle: AppLocalization.localized("Station access"),
                    reason: warning.message,
                    severity: .caution
                )
            case .longWalk:
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
            level = max(level, .risky)
            reasons.append(AppLocalization.localized("AMap walking hints include stairs."))
            estimatedExtraMinutes += 8
            bottleneck = bottleneck ?? RouteBottleneck(
                segmentTitle: AppLocalization.localized("Walking segment"),
                reason: AppLocalization.localized("Stairs detected"),
                severity: .risky
            )
        }
        if walkingSteps.contains(where: \.hasElevator) {
            reasons.append(AppLocalization.localized("AMap walking hints include an elevator."))
        }
        if walkingSteps.contains(where: \.hasRamp) {
            reasons.append(AppLocalization.localized("AMap walking hints include a ramp."))
        }
        if walkingSteps.contains(where: \.hasEscalator) {
            reasons.append(AppLocalization.localized("AMap walking hints include an escalator."))
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
        switch level {
        case .good:
            title = AppLocalization.localized("Step-free likely")
        case .caution:
            title = AppLocalization.localized("Step-free not confirmed")
        case .risky:
            title = problemReports.isEmpty
                ? AppLocalization.localized("Accessibility risk")
                : AppLocalization.localized("Personal issue reported")
        case .unknown:
            title = AppLocalization.localized("Accessibility unknown")
        }

        return RouteFeasibility(
            level: level,
            title: title,
            reasons: Array(unique(reasons)),
            unknowns: Array(unique(unknowns)),
            personalReports: personalReports,
            bottleneck: bottleneck,
            estimatedExtraMinutes: estimatedExtraMinutes
        )
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
