import Foundation

@MainActor
protocol AIReportProviding {
    func insights(for station: Station) -> [AIReportInsight]
    func insights(affecting route: Route) -> [AIReportInsight]
}

@MainActor
final class AIReportService: AIReportProviding {
    func insights(for station: Station) -> [AIReportInsight] {
        []
    }

    func insights(affecting route: Route) -> [AIReportInsight] {
        []
    }
}
