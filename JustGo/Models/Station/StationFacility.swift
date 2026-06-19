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

    var iconName: String {
        switch self {
        case .elevator:
            return "arrow.up.arrow.down.circle.fill"
        case .escalator:
            return "arrow.up.to.line"
        case .ramp, .wheelchairBoarding, .accessibleRestroom:
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

    var localizedName: String {
        switch self {
        case .elevator:
            return AppLocalization.text(english: "Elevator", simplified: "电梯", traditional: "電梯")
        case .escalator:
            return AppLocalization.text(english: "Escalator", simplified: "扶梯", traditional: "扶梯")
        case .ramp:
            return AppLocalization.text(english: "Ramp", simplified: "坡道", traditional: "坡道")
        case .accessibleRestroom:
            return AppLocalization.text(english: "Accessible Restroom", simplified: "无障碍卫生间", traditional: "無障礙廁所")
        case .tactilePath:
            return AppLocalization.text(english: "Tactile Path", simplified: "盲道", traditional: "盲道")
        case .audioAnnouncement:
            return AppLocalization.text(english: "Audio Announcement", simplified: "语音播报", traditional: "語音播報")
        case .visualDisplay:
            return AppLocalization.text(english: "Visual Display", simplified: "视觉显示", traditional: "視覺顯示")
        case .restroom:
            return AppLocalization.text(english: "Restroom", simplified: "卫生间", traditional: "廁所")
        case .aed:
            return AppLocalization.text(english: "AED", simplified: "自动体外除颤器", traditional: "自動體外除顫器")
        case .serviceCenter:
            return AppLocalization.text(english: "Service Center", simplified: "客服中心", traditional: "客服中心")
        case .security:
            return AppLocalization.text(english: "Security", simplified: "安保", traditional: "安保")
        case .motherBabyRoom:
            return AppLocalization.text(english: "Mother & Baby Room", simplified: "母婴室", traditional: "母嬰室")
        case .staffAssistance:
            return AppLocalization.text(english: "Staff Assistance", simplified: "工作人员协助", traditional: "工作人員協助")
        case .wheelchairBoarding:
            return AppLocalization.text(english: "Wheelchair Boarding", simplified: "轮椅上车", traditional: "輪椅上車")
        case .general:
            return AppLocalization.text(english: "General", simplified: "其他", traditional: "其他")
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
    case unknown

    var label: String {
        switch self {
        case .officialCityPack:
            return AppLocalization.localized("Official city data")
        case .personalReport:
            return AppLocalization.localized("Personal report")
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
