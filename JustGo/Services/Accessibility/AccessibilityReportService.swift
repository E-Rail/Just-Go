import Foundation

@MainActor
@Observable
final class AccessibilityReportService {
    private let userDefaults: UserDefaults
    private let reportsKey = "localAccessibilityReports"
    private let maxReports = 100

    private(set) var reports: [LocalAccessibilityReport]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        reports = userDefaults.codableValue(forKey: reportsKey, as: [LocalAccessibilityReport].self, default: [])
    }

    func createStationReport(
        cityID: String,
        station: Station,
        itemType: VerificationItemType,
        status: VerificationStatus,
        severity: AccessibilityReportSeverity,
        note: String
    ) {
        let report = LocalAccessibilityReport(
            id: UUID().uuidString,
            relatedEntity: .station,
            cityID: cityID,
            stationID: station.stationID,
            stationName: station.localizedName,
            routeID: nil,
            routeTitle: nil,
            itemType: itemType,
            status: status,
            severity: severity,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: .now,
            updatedAt: .now
        )
        insert(report)
    }

    func createRouteReport(
        cityID: String,
        route: Route,
        itemType: VerificationItemType = .routeConcern,
        status: VerificationStatus,
        severity: AccessibilityReportSeverity,
        note: String
    ) {
        let report = LocalAccessibilityReport(
            id: UUID().uuidString,
            relatedEntity: .route,
            cityID: cityID,
            stationID: nil,
            stationName: nil,
            routeID: route.id.uuidString,
            routeTitle: "\(route.origin) -> \(route.destination)",
            itemType: itemType,
            status: status,
            severity: severity,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: .now,
            updatedAt: .now
        )
        insert(report)
    }

    func reports(for station: Station) -> [LocalAccessibilityReport] {
        reports
            .filter { $0.relatedEntity == .station && $0.stationID == station.stationID }
            .sorted { $0.severity > $1.severity }
    }

    func reports(affecting route: Route) -> [LocalAccessibilityReport] {
        let stationIDs = Set(route.stationTimelineStops.map(\.stationID))
        return reports
            .filter { report in
                if report.routeID == route.id.uuidString {
                    return true
                }
                guard let stationID = report.stationID else { return false }
                return stationIDs.contains(stationID)
            }
            .sorted { $0.severity > $1.severity }
    }

    func deleteReport(id: String) {
        reports.removeAll { $0.id == id }
        persist()
    }

    private func insert(_ report: LocalAccessibilityReport) {
        reports.insert(report, at: 0)
        reports = Array(reports.prefix(maxReports))
        persist()
    }

    private func persist() {
        userDefaults.setCodable(reports, forKey: reportsKey)
    }
}
