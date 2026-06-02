import Foundation

enum AppLocalization {
    private static var languageCode: String {
        (Bundle.main.preferredLocalizations.first ?? Locale.autoupdatingCurrent.identifier)
            .lowercased()
    }

    static var isChinese: Bool {
        languageCode.hasPrefix("zh")
    }

    static var isTraditionalChinese: Bool {
        languageCode.hasPrefix("zh-hant") ||
        languageCode.hasPrefix("zh_tw") ||
        languageCode.hasPrefix("zh-hk") ||
        languageCode.hasPrefix("zh_hk") ||
        languageCode.hasPrefix("zh-mo") ||
        languageCode.hasPrefix("zh_mo")
    }

    static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func chinese(_ simplified: String) -> String {
        guard isTraditionalChinese else { return simplified }
        return simplified.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplified
    }

    static func searchVariants(for text: String) -> Set<String> {
        let base = normalizedSearchText(text)
        guard !base.isEmpty else { return [] }

        var variants: Set<String> = [base]
        if let simplified = base.applyingTransform(StringTransform("Hant-Hans"), reverse: false) {
            variants.insert(normalizedSearchText(simplified))
        }
        if let traditional = base.applyingTransform(StringTransform("Hans-Hant"), reverse: false) {
            variants.insert(normalizedSearchText(traditional))
        }
        if let latin = text.applyingTransform(.toLatin, reverse: false) {
            let normalizedLatin = normalizedSearchText(latin)
            variants.insert(normalizedLatin)
            variants.insert(normalizedLatin.replacingOccurrences(of: " ", with: ""))
        }
        return variants.filter { !$0.isEmpty }
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

    static func stopsLeft(_ count: Int) -> String {
        text(english: "\(count) stop\(count == 1 ? "" : "s") left", simplified: "还剩\(count)站", traditional: "還剩\(count)站")
    }

    static func transfers(_ count: Int) -> String {
        if count == 0 {
            return localized("Direct")
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

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}

extension City {
    var localizedName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(name) : nameEn
    }

    var alternateLocalizedName: String? {
        AppLocalization.isChinese ? nameEn : name
    }
}

extension SubwayLineData {
    var localizedName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(name) : (nameEn ?? name)
    }
}

extension Station {
    var localizedName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(name) : (nameEn ?? name)
    }

    var alternateLocalizedName: String? {
        AppLocalization.isChinese ? nameEn : name
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
            label += AppLocalization.text(english: ", fully accessible", chinese: "，完全无障碍")
        }
        return label
    }
}

extension SubwayLine {
    var localizedName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(name) : (nameEn ?? name)
    }

    var alternateLocalizedName: String? {
        AppLocalization.isChinese ? nameEn : name
    }
}

extension StationExit {
    var localizedName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(name) : (nameEn ?? name)
    }

    var alternateLocalizedName: String? {
        AppLocalization.isChinese ? nameEn : name
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
        case .subway:
            return "\(lineName ?? AppLocalization.localized("Subway")) • \(AppLocalization.stops(stops))"
        case .transfer:
            return AppLocalization.localized("Transfer")
        }
    }

    var navigationLabel: String {
        switch type {
        case .walking:
            if let fromStationName, let toStationName {
                return AppLocalization.text(
                    english: "Walk from \(fromStationName) to \(toStationName)",
                    simplified: "从 \(fromStationName) 步行至 \(toStationName)",
                    traditional: "從 \(fromStationName) 步行至 \(toStationName)"
                )
            }
            let station = toStationName ?? fromStationName ?? AppLocalization.localized("station")
            return AppLocalization.text(english: "Walk to \(station)", chinese: "步行至 \(station)")
        case .subway:
            let line = lineName ?? AppLocalization.localized("Subway")
            let direction = toStationName ?? ""
            return AppLocalization.text(english: "\(line) toward \(direction)", chinese: "\(line) 开往 \(direction)")
        case .transfer:
            let line = lineName ?? AppLocalization.localized("next line")
            return AppLocalization.text(english: "Transfer to \(line)", chinese: "换乘至 \(line)")
        }
    }
}
