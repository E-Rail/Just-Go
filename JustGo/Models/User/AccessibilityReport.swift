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
    case exit
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
        case .exit:
            return AppLocalization.text(english: "Exit / Entrance", simplified: "出入口", traditional: "出入口")
        case .routeConcern:
            return AppLocalization.localized("Route Concern")
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
