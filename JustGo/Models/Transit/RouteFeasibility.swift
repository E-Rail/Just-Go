import Foundation

struct RouteFeasibility: Equatable {
    let level: RouteFeasibilityLevel
    let title: String
    let reasons: [String]
    let unknowns: [String]
    let aiReportInsights: [AIReportInsight]
    let bottleneck: RouteBottleneck?
    let estimatedExtraMinutes: Int

    var allExplanations: [String] {
        reasons + unknowns
    }
}

enum RouteFeasibilityLevel: Comparable {
    case good
    case caution
    case risky
    case unknown

    var sortValue: Int {
        switch self {
        case .good:
            return 0
        case .unknown:
            return 1
        case .caution:
            return 2
        case .risky:
            return 3
        }
    }

    static func < (lhs: RouteFeasibilityLevel, rhs: RouteFeasibilityLevel) -> Bool {
        lhs.sortValue < rhs.sortValue
    }
}

struct RouteBottleneck: Equatable {
    let segmentTitle: String
    let reason: String
}
