import Foundation

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese
    case traditionalChinese

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .system:
            return AppLocalization.localized("System Default")
        case .english:
            return AppLocalization.localized("English")
        case .simplifiedChinese:
            return AppLocalization.localized("Simplified Chinese")
        case .traditionalChinese:
            return AppLocalization.localized("Traditional Chinese")
        }
    }

    fileprivate var localizationIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChinese:
            return "zh-Hant"
        }
    }
}

enum AppLocalization {
    static let preferenceKey = "appLanguagePreference"
    static let launchPreference = AppLanguagePreference(
        rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? ""
    ) ?? .system

    private static let appleLanguagesKey = "AppleLanguages"
    /// The value `applyToSystem` last wrote, so "System Default" undoes only its own write.
    private static let writtenAppleLanguageKey = "appleLanguagesWrittenByApp"

    /// Hands the rider's choice to iOS as this app's language, which is what MapKit names places in
    /// and what the system draws inside the app (alerts, permission prompts, pickers). The in-app
    /// choice alone only swaps the app's own strings. Takes effect at the next launch, like the
    /// choice itself.
    ///
    /// `AppleLanguages` in the app's own domain is the key Settings → Just Go → Language writes; the
    /// phone's language is in the global domain and is untouched.
    static func applyToSystem(_ preference: AppLanguagePreference) {
        let defaults = UserDefaults.standard
        if let identifier = preference.localizationIdentifier {
            defaults.set([identifier], forKey: appleLanguagesKey)
            defaults.set(identifier, forKey: writtenAppleLanguageKey)
            return
        }
        // Read from the app's domain only: `stringArray(forKey:)` falls through to the phone's
        // languages. A language the rider set in iOS Settings is not this app's write, so it stays.
        let appDomain = Bundle.main.bundleIdentifier.flatMap(defaults.persistentDomain(forName:))
        if let written = defaults.string(forKey: writtenAppleLanguageKey),
           appDomain?[appleLanguagesKey] as? [String] == [written] {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
        defaults.removeObject(forKey: writtenAppleLanguageKey)
    }

    private static let activeLanguage: AppLanguagePreference = {
        guard launchPreference == .system else { return launchPreference }
        let languageCode = Bundle.main.preferredLocalizations.first
            ?? Locale.autoupdatingCurrent.identifier
        return supportedLanguage(for: languageCode)
    }()

    private static let localizationBundle: Bundle = {
        guard let identifier = activeLanguage.localizationIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }()

    static var isChinese: Bool {
        activeLanguage == .simplifiedChinese || activeLanguage == .traditionalChinese
    }

    static var isTraditionalChinese: Bool {
        activeLanguage == .traditionalChinese
    }

    static func localized(_ key: String) -> String {
        localizationBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func text(english: String, simplified: String, traditional: String) -> String {
        guard isChinese else { return english }
        return isTraditionalChinese ? traditional : simplified
    }

    static func minutes(_ count: Int) -> String {
        text(english: "\(count) min", simplified: "\(count)分钟", traditional: "\(count)分鐘")
    }

    static func stops(_ count: Int) -> String {
        isChinese ? "\(count)站" : "\(count) stop\(count == 1 ? "" : "s")"
    }

    static func stopsLeft(_ count: Int) -> String {
        text(
            english: "\(count) stop\(count == 1 ? "" : "s") left",
            simplified: "还剩\(count)站",
            traditional: "還剩\(count)站"
        )
    }

    static func stepProgress(current: Int, total: Int) -> String {
        text(
            english: "Step \(current) of \(total)",
            simplified: "第 \(current) / \(total) 步",
            traditional: "第 \(current) / \(total) 步"
        )
    }

    static func distance(_ meters: Double) -> String {
        let rounded = max(0, meters)
        if rounded < 1000 {
            return text(english: "\(Int(rounded)) m", simplified: "\(Int(rounded))米", traditional: "\(Int(rounded))米")
        }
        return text(
            english: String(format: "%.1f km", rounded / 1000),
            simplified: String(format: "%.1f 公里", rounded / 1000),
            traditional: String(format: "%.1f 公里", rounded / 1000)
        )
    }

    static func transfers(_ count: Int) -> String {
        if count == 0 {
            return AppLocalization.localized("Direct")
        }
        return text(english: "\(count) transfer\(count == 1 ? "" : "s")", simplified: "\(count)次换乘", traditional: "\(count)次轉乘")
    }

    static func stationCount(_ count: Int) -> String {
        text(english: "\(count) station\(count == 1 ? "" : "s")", simplified: "\(count)座车站", traditional: "\(count)座車站")
    }

    static func lineCount(_ count: Int) -> String {
        text(english: "\(count) line\(count == 1 ? "" : "s")", simplified: "\(count)条线路", traditional: "\(count)條路線")
    }

    static func cityLineSummary(stations: Int, lines: Int) -> String {
        "\(stationCount(stations)) • \(lineCount(lines))"
    }

    private static func supportedLanguage(for languageCode: String) -> AppLanguagePreference {
        let normalized = languageCode.replacingOccurrences(of: "_", with: "-").lowercased()
        guard normalized.hasPrefix("zh") else {
            return .english
        }
        if normalized.contains("hant") ||
            normalized.hasPrefix("zh-tw") ||
            normalized.hasPrefix("zh-hk") ||
            normalized.hasPrefix("zh-mo") {
            return .traditionalChinese
        }
        return .simplifiedChinese
    }
}

extension City {
    var localizedName: String {
        AppLocalization.isChinese ? name : nameEn
    }

    var alternateLocalizedName: String? {
        AppLocalization.isChinese ? nil : name
    }
}

extension Station {
    var localizedName: String {
        AppLocalization.isChinese ? name : (nameEn ?? name)
    }

    /// The second line of a station label, or nil when it would repeat the first (a station with no
    /// English name shows its Chinese name as `localizedName`). `validate_localizations.rb` pins
    /// the first expression: in Chinese this is always nil.
    var alternateLocalizedName: String? {
        let alternate = AppLocalization.isChinese ? nil : name
        return alternate == localizedName ? nil : alternate
    }

    /// The line under a station's name everywhere it is listed: its other name and its city, since
    /// search spans every bundled city and 中山公园 is in several.
    var subtitle: String? {
        let parts = [alternateLocalizedName, city].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        var label = localizedName
        if let alternateName = alternateLocalizedName { label += ", \(alternateName)" }
        if let city { label += ", \(city)" }
        if isTransferStation {
            label += AppLocalization.text(english: ", transfer station", simplified: "，换乘站", traditional: "，轉乘站")
        }
        if accessibility?.hasElevator == true {
            label += AppLocalization.text(english: ", has elevator", simplified: "，有电梯", traditional: "，有電梯")
        }
        if accessibility?.isFullyAccessible == true {
            label += AppLocalization.text(
                english: ", lift and step-free entrance listed",
                simplified: "，已列出电梯与无障碍入口",
                traditional: "，已列出電梯與無障礙入口"
            )
        }
        return label
    }
}

extension SubwayLine {
    var localizedName: String {
        AppLocalization.isChinese ? name : (nameEn ?? name)
    }

    var alternateLocalizedName: String? {
        AppLocalization.isChinese ? nil : name
    }
}

extension MetroLine {
    var localizedName: String {
        AppLocalization.isChinese ? name : (nameEn ?? name)
    }
}

extension RouteSegment {
    var summaryLabel: String {
        switch type {
        case .walking:
            return AppLocalization.text(
                english: "Walk \(AppLocalization.distance(distance))",
                simplified: "步行 \(AppLocalization.distance(distance))",
                traditional: "步行 \(AppLocalization.distance(distance))"
            )
        case .cycling:
            return AppLocalization.text(
                english: "Cycle \(AppLocalization.distance(distance))",
                simplified: "骑行 \(AppLocalization.distance(distance))",
                traditional: "騎行 \(AppLocalization.distance(distance))"
            )
        case .driving:
            return AppLocalization.text(
                english: "Drive \(AppLocalization.distance(distance))",
                simplified: "驾车 \(AppLocalization.distance(distance))",
                traditional: "駕車 \(AppLocalization.distance(distance))"
            )
        case .subway:
            return "\(lineName ?? AppLocalization.localized("Transit")) • \(AppLocalization.stops(stops))"
        case .transfer:
            return AppLocalization.localized("Transfer")
        }
    }
}
