import Foundation

struct UserProfile: Codable {
    var id: UUID
    var preferredLanguage: Language
    var accessibilityPreference: AccessibilityPreference
    var homeCityID: String?
    var visitedCityIDs: [String]
    var createdAt: Date
    var lastActiveAt: Date

    init() {
        self.id = UUID()
        self.preferredLanguage = .system
        self.accessibilityPreference = .default
        self.homeCityID = nil
        self.visitedCityIDs = []
        self.createdAt = .now
        self.lastActiveAt = .now
    }
}

enum Language: String, Codable, CaseIterable {
    case system = "system"
    case chinese = "zh"
    case english = "en"
    case both = "both"

    var displayName: String {
        switch self {
        case .system: return "System"
        case .chinese: return "中文"
        case .english: return "English"
        case .both: return "中英双语"
        }
    }
}
