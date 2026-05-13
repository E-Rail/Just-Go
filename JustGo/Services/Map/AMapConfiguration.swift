import Foundation

enum AMapConfiguration {
    static var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "AMapAPIKey") as? String ?? ""
    }

    static func configure() {
    }
}
