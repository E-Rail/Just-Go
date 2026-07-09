import Foundation

struct AIReportInsight: Identifiable, Codable, Equatable {
    let id: String
    let scope: AIReportScope
    let cityID: String
    let stationID: String?
    let stationName: String?
    let routeID: String?
    let routeTitle: String?
    let title: String
    let detail: String
    let severity: AIReportSeverity
    let source: AIReportSource
    var updatedAt: Date
}

enum AIReportScope: String, Codable {
    case station
    case route
}

enum AIReportSeverity: String, Codable, CaseIterable, Comparable {
    case info
    case caution
    case risk

    static func < (lhs: AIReportSeverity, rhs: AIReportSeverity) -> Bool {
        lhs.sortValue < rhs.sortValue
    }

    private var sortValue: Int {
        switch self {
        case .info:
            return 0
        case .caution:
            return 1
        case .risk:
            return 2
        }
    }

    var title: String {
        switch self {
        case .info:
            return AppLocalization.text(english: "Info", simplified: "提示", traditional: "提示")
        case .caution:
            return AppLocalization.localized("Caution")
        case .risk:
            return AppLocalization.localized("Risk")
        }
    }
}

enum AIReportSource: String, Codable {
    case ai
    case official
    case partner
}
