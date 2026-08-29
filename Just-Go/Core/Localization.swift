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

    // Every `localizedName` on City/Station/SubwayLine/MetroLine funnels through here for
    // Traditional Chinese users; the underlying set of names is small and finite, so caching
    // the transform avoids re-running it on every row render.
    private static let hansToHantCache = NSCache<NSString, NSString>()

    static func chinese(_ simplified: String) -> String {
        guard isTraditionalChinese else { return simplified }
        let key = simplified as NSString
        if let cached = hansToHantCache.object(forKey: key) {
            return cached as String
        }
        let converted = simplified.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplified
        hansToHantCache.setObject(converted as NSString, forKey: key)
        return converted
    }

    static func text(english: String, chinese: String) -> String {
        guard isChinese else { return english }
        return self.chinese(chinese)
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
        AppLocalization.isChinese ? AppLocalization.chinese(name) : nameEn
    }

    var alternateLocalizedName: String? {
        AppLocalization.isChinese ? nil : name
    }
}

extension Station {
    var localizedName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(name) : (nameEn ?? name)
    }

    /// The second line of a station label. Nil when it would merely repeat the first. A station
    /// carrying no English name renders `localizedName` as its Chinese name, and returning that
    /// same string here printed every map pin twice. The first expression is kept verbatim
    /// because `validate_localizations.rb` pins it: in Chinese this must be nil, always.
    var alternateLocalizedName: String? {
        let alternate = AppLocalization.isChinese ? nil : name
        return alternate == localizedName ? nil : alternate
    }

    var accessibilityLabel: String {
        var label = localizedName
        if let alternateName = alternateLocalizedName { label += ", \(alternateName)" }
        if isTransferStation {
            label += AppLocalization.text(english: ", transfer station", chinese: "，换乘站")
        }
        if accessibility?.hasElevator == true {
            label += AppLocalization.text(english: ", has elevator", chinese: "，有电梯")
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
        AppLocalization.isChinese ? AppLocalization.chinese(name) : (nameEn ?? name)
    }

    var alternateLocalizedName: String? {
        AppLocalization.isChinese ? nil : name
    }
}

extension MetroLine {
    var localizedName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(name) : (nameEn ?? name)
    }
}

extension RouteSegment {
    var summaryLabel: String {
        switch type {
        case .walking:
            return AppLocalization.text(
                english: "Walk \(AppLocalization.distance(distance))",
                chinese: "步行 \(AppLocalization.distance(distance))"
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
