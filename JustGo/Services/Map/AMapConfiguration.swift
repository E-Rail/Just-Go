import Foundation

enum AMapConfiguration {
    static var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "AMapAPIKey") as? String ?? ""
    }

    static func configure() {
        // AMap SDK configuration will be done when the framework is integrated
        // This placeholder handles privacy compliance
        configurePrivacy()
    }

    private static func configurePrivacy() {
        // AMap requires privacy compliance calls before any SDK usage
        // These will be called when AMap SDK is integrated
        #if canImport(AMapFoundationKit)
        AMapServices.updatePrivacyShow(.didShow, privacyInfo: .didContain)
        AMapServices.updatePrivacyAgree(.didAgree)
        if !apiKey.isEmpty {
            AMapServices.shared().apiKey = apiKey
        }
        #endif
    }
}
