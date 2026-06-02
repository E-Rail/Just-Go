import Foundation

struct LocalAccessibilityReport: Identifiable, Codable, Equatable {
    let id: String
    let relatedEntity: AccessibilityReportEntity
    let cityID: String
    let stationID: String?
    let stationName: String?
    let routeID: String?
    let routeTitle: String?
    var itemType: VerificationItemType
    var status: VerificationStatus
    var severity: AccessibilityReportSeverity
    var note: String
    let createdAt: Date
    var updatedAt: Date

    var title: String {
        routeTitle ?? stationName ?? itemType.title
    }

    var displayNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? status.title
            : note
    }
}

enum AccessibilityReportEntity: String, Codable {
    case station
    case route
}

enum AccessibilityReportSeverity: String, Codable, CaseIterable, Comparable {
    case low
    case medium
    case high
    case critical

    static func < (lhs: AccessibilityReportSeverity, rhs: AccessibilityReportSeverity) -> Bool {
        lhs.sortValue < rhs.sortValue
    }

    private var sortValue: Int {
        switch self {
        case .low:
            return 0
        case .medium:
            return 1
        case .high:
            return 2
        case .critical:
            return 3
        }
    }

    var title: String {
        switch self {
        case .low:
            return AppLocalization.localized("Low")
        case .medium:
            return AppLocalization.localized("Medium")
        case .high:
            return AppLocalization.localized("High")
        case .critical:
            return AppLocalization.localized("Critical")
        }
    }
}

enum VerificationItemType: String, Codable, CaseIterable {
    case elevator
    case escalator
    case ramp
    case accessibleRestroom
    case wheelchairBoarding
    case tactilePath
    case audioAnnouncement
    case visualDisplay
    case staffAssistance
    case stepFreeAccess
    case routeConcern

    var title: String {
        switch self {
        case .elevator:
            return AppLocalization.localized("Elevator")
        case .escalator:
            return AppLocalization.localized("Escalator")
        case .ramp:
            return AppLocalization.localized("Wheelchair Ramp")
        case .accessibleRestroom:
            return AppLocalization.localized("Accessible Restroom")
        case .wheelchairBoarding:
            return AppLocalization.localized("Wheelchair Boarding")
        case .tactilePath:
            return AppLocalization.localized("Tactile Path")
        case .audioAnnouncement:
            return AppLocalization.localized("Audio Announcement")
        case .visualDisplay:
            return AppLocalization.localized("Visual Display")
        case .staffAssistance:
            return AppLocalization.localized("Staff Assistance")
        case .stepFreeAccess:
            return AppLocalization.localized("Step-free Access")
        case .routeConcern:
            return AppLocalization.localized("Route Concern")
        }
    }

    var facilityType: StationFacilityType {
        switch self {
        case .elevator:
            return .elevator
        case .escalator:
            return .escalator
        case .ramp:
            return .ramp
        case .accessibleRestroom:
            return .accessibleRestroom
        case .wheelchairBoarding:
            return .wheelchairBoarding
        case .tactilePath:
            return .tactilePath
        case .audioAnnouncement:
            return .audioAnnouncement
        case .visualDisplay:
            return .visualDisplay
        case .staffAssistance:
            return .staffAssistance
        case .stepFreeAccess, .routeConcern:
            return .general
        }
    }
}

enum VerificationStatus: String, Codable, CaseIterable {
    case working
    case outOfService
    case maintenance
    case unknown
    case notPresent
    case note

    var title: String {
        switch self {
        case .working:
            return AppLocalization.localized("Working")
        case .outOfService:
            return AppLocalization.localized("Out of service")
        case .maintenance:
            return AppLocalization.localized("Under maintenance")
        case .unknown:
            return AppLocalization.localized("Unknown")
        case .notPresent:
            return AppLocalization.localized("Not present")
        case .note:
            return AppLocalization.localized("Note")
        }
    }

    var isProblem: Bool {
        switch self {
        case .outOfService, .maintenance, .unknown, .notPresent:
            return true
        case .working, .note:
            return false
        }
    }
}

struct AccessibilityVerification: Identifiable, Codable, Equatable {
    let id: String
    let stationID: String
    let itemType: VerificationItemType
    let officialStatus: VerificationStatus?
    let reports: [VerificationReport]

    var confidence: VerificationConfidence {
        VerificationConfidence(reports: reports)
    }

    var displayStatus: VerificationStatus {
        confidence.status ?? officialStatus ?? .unknown
    }

    var canDisplayCommunityStatus: Bool {
        confidence.reportCount >= 3 && confidence.score >= 0.7
    }
}

struct VerificationReport: Identifiable, Codable, Equatable {
    let id: String
    let stationID: String
    let itemType: VerificationItemType
    let reportedStatus: VerificationStatus
    let reportDate: Date
    let isReliableReporter: Bool
    let note: String?
}

struct VerificationConfidence: Codable, Equatable {
    let status: VerificationStatus?
    let score: Double
    let reportCount: Int

    init(reports: [VerificationReport], now: Date = .now) {
        reportCount = reports.count
        guard reports.count >= 3 else {
            status = nil
            score = 0
            return
        }

        var weightsByStatus: [VerificationStatus: Double] = [:]
        var totalWeight = 0.0

        for report in reports {
            let age = now.timeIntervalSince(report.reportDate)
            let days = age / 86_400
            guard days <= 60 else { continue }

            var weight = report.isReliableReporter ? 2.0 : 1.0
            if days > 30 {
                weight *= 0.3
            } else if days > 14 {
                weight *= 0.7
            } else if days > 7 {
                weight *= 0.9
            }

            weightsByStatus[report.reportedStatus, default: 0] += weight
            totalWeight += weight
        }

        guard totalWeight > 0,
              let winner = weightsByStatus.max(by: { $0.value < $1.value }) else {
            status = nil
            score = 0
            return
        }

        let thresholdPenalty = reports.count < 5 ? 0.8 : 1.0
        status = winner.key
        score = min(1.0, max(0, (winner.value / totalWeight) * thresholdPenalty))
    }
}
