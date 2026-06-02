import Foundation

struct StationFacility: Identifiable, Codable, Equatable {
    let id: String
    let stationID: String?
    let type: StationFacilityType
    let name: String
    let locationText: String?
    let source: StationFacilitySource
    let verification: StationFacilityVerification
    let updatedAt: Date?

    init(
        id: String = UUID().uuidString,
        stationID: String? = nil,
        type: StationFacilityType,
        name: String,
        locationText: String? = nil,
        source: StationFacilitySource = .officialCityPack,
        verification: StationFacilityVerification = .verified,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.stationID = stationID
        self.type = type
        self.name = name
        self.locationText = locationText
        self.source = source
        self.verification = verification
        self.updatedAt = updatedAt
    }
}

enum StationFacilityType: String, Codable, CaseIterable {
    case elevator
    case escalator
    case ramp
    case accessibleRestroom
    case tactilePath
    case audioAnnouncement
    case visualDisplay
    case restroom
    case aed
    case serviceCenter
    case security
    case motherBabyRoom
    case staffAssistance
    case wheelchairBoarding
    case general

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
        case .tactilePath:
            return AppLocalization.localized("Tactile Path")
        case .audioAnnouncement:
            return AppLocalization.localized("Audio Announcement")
        case .visualDisplay:
            return AppLocalization.localized("Visual Display")
        case .restroom:
            return AppLocalization.localized("Restroom")
        case .aed:
            return AppLocalization.localized("AED")
        case .serviceCenter:
            return AppLocalization.localized("Service Center")
        case .security:
            return AppLocalization.localized("Security")
        case .motherBabyRoom:
            return AppLocalization.localized("Mother and Baby Room")
        case .staffAssistance:
            return AppLocalization.localized("Staff Assistance")
        case .wheelchairBoarding:
            return AppLocalization.localized("Wheelchair Boarding")
        case .general:
            return AppLocalization.localized("Station Facility")
        }
    }

    var iconName: String {
        switch self {
        case .elevator:
            return "arrow.up.arrow.down.circle.fill"
        case .escalator:
            return "arrow.up.to.line"
        case .ramp, .wheelchairBoarding:
            return "figure.roll"
        case .accessibleRestroom:
            return "figure.roll"
        case .tactilePath:
            return "hand.raised.fill"
        case .audioAnnouncement:
            return "speaker.wave.2.fill"
        case .visualDisplay:
            return "eye.fill"
        case .restroom:
            return "toilet"
        case .aed:
            return "heart.text.square.fill"
        case .serviceCenter, .staffAssistance:
            return "person.crop.circle.badge.questionmark"
        case .security:
            return "shield.fill"
        case .motherBabyRoom:
            return "figure.2.and.child.holdinghands"
        case .general:
            return "info.circle"
        }
    }

    var isAccessibilityCritical: Bool {
        switch self {
        case .elevator, .escalator, .ramp, .accessibleRestroom, .tactilePath, .audioAnnouncement, .visualDisplay, .staffAssistance, .wheelchairBoarding:
            return true
        case .restroom, .aed, .serviceCenter, .security, .motherBabyRoom, .general:
            return false
        }
    }

    static func inferred(from text: String) -> StationFacilityType {
        let normalized = text.lowercased()
        if normalized.contains("直梯") || normalized.contains("电梯") || normalized.contains("升降") || normalized.contains("elevator") {
            return .elevator
        }
        if normalized.contains("扶梯") || normalized.contains("escalator") {
            return .escalator
        }
        if normalized.contains("坡道") || normalized.contains("ramp") {
            return .ramp
        }
        if normalized.contains("无障碍厕所") || normalized.contains("accessible restroom") {
            return .accessibleRestroom
        }
        if normalized.contains("盲道") || normalized.contains("tactile") {
            return .tactilePath
        }
        if normalized.contains("aed") || normalized.contains("急救") {
            return .aed
        }
        if normalized.contains("母婴") || normalized.contains("baby") {
            return .motherBabyRoom
        }
        if normalized.contains("卫生间") || normalized.contains("厕所") || normalized.contains("toilet") || normalized.contains("restroom") {
            return .restroom
        }
        if normalized.contains("客服") || normalized.contains("服务") || normalized.contains("service") {
            return .serviceCenter
        }
        if normalized.contains("警务") || normalized.contains("安保") || normalized.contains("security") || normalized.contains("police") {
            return .security
        }
        return .general
    }
}

enum StationFacilitySource: String, Codable {
    case officialCityPack
    case personalReport
    case amapHint
    case unknown

    var label: String {
        switch self {
        case .officialCityPack:
            return AppLocalization.localized("Official city data")
        case .personalReport:
            return AppLocalization.localized("Personal report")
        case .amapHint:
            return AppLocalization.localized("AMap route hint")
        case .unknown:
            return AppLocalization.localized("Unknown source")
        }
    }
}

enum StationFacilityVerification: String, Codable {
    case verified
    case unverified
    case sourcePending
    case personal

    var label: String {
        switch self {
        case .verified:
            return AppLocalization.localized("Verified")
        case .unverified:
            return AppLocalization.localized("Not verified")
        case .sourcePending:
            return AppLocalization.localized("Source pending")
        case .personal:
            return AppLocalization.localized("Personal")
        }
    }
}
