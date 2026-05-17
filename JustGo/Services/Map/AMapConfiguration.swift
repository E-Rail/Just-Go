import Foundation

enum AMapConfiguration {
    static var apiKey: String {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "AMapAPIKey") as? String ?? ""
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.hasPrefix("$(") else { return "" }
        return trimmedValue
    }

    static func configure() {
    }
}
