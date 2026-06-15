import Foundation

private let chineseLineNumberExpression = try! NSRegularExpression(pattern: "[零〇一二三四五六七八九十百]+(?=号线)")

func formatScheduleText(first: String?, last: String?) -> String? {
    let first = normalizedTime(first)
    let last = normalizedTime(last)
    switch (first, last) {
    case let (first?, last?):
        return AppLocalization.text(
            english: "First \(first), last \(last)",
            simplified: "首班 \(first)，末班 \(last)",
            traditional: "首班 \(first)，末班 \(last)"
        )
    case let (first?, nil):
        return AppLocalization.text(english: "First \(first)", simplified: "首班 \(first)", traditional: "首班 \(first)")
    case let (nil, last?):
        return AppLocalization.text(english: "Last \(last)", simplified: "末班 \(last)", traditional: "末班 \(last)")
    default:
        return nil
    }
}

func normalizeTransitLineName(_ value: String) -> String {
    normalizeChineseLineNumber(
        value
        .replacingOccurrences(of: "（.*?）|\\(.*?\\)", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "地铁", with: "")
        .replacingOccurrences(of: "轨道交通", with: "")
        .lowercased()
    )
}

func lineColorHex(for lineName: String, in network: MetroNetwork?, fallback: String = "#007AFF") -> String {
    lineColorHex(for: lineName, in: network, preferredLineIDs: [], fallback: fallback)
}

func lineColorHex(
    for lineName: String,
    in network: MetroNetwork?,
    preferredLineIDs: Set<String>,
    fallback: String = "#007AFF"
) -> String {
    guard let network else { return fallback }
    let target = normalizeTransitLineName(lineName)
    guard !target.isEmpty else { return fallback }

    let preferredLines = network.lines.filter { preferredLineIDs.contains($0.id) }
    let lines = preferredLines.isEmpty ? network.lines : preferredLines
    let namesByLine = lines.map { line in
        (line, [line.name, line.nameEn].compactMap { $0 }.map(normalizeTransitLineName))
    }
    let matchingPriorities: [((String) -> Bool)] = [
        { $0 == target },
        { compactLineName($0) == compactLineName(target) },
        { lineNameTokens($0) == lineNameTokens(target) },
        { suffixSafeContains($0, target) || suffixSafeContains(target, $0) }
    ]

    for matches in matchingPriorities {
        let matchedColors = Set(namesByLine.compactMap { line, names in
            names.contains(where: matches) ? line.colorHex : nil
        })
        if matchedColors.count == 1, let color = matchedColors.first {
            return color
        }
        if !matchedColors.isEmpty { return fallback }
    }
    return fallback
}

func normalizeStationKey(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "地铁站", with: "")
        .lowercased()
}

func normalizedStationName(_ value: String) -> String {
    value
        .replacingOccurrences(of: "地铁站", with: "")
        .replacingOccurrences(of: "站", with: "")
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
}

extension SubwayLine {
    var logicalLineIdentity: String {
        "\(cityID.lowercased())|\(lineID.lowercased())"
    }
}

extension Station {
    var uniqueLogicalLines: [SubwayLine] {
        lines.uniqued(by: \.logicalLineIdentity)
    }
}

private func compactLineName(_ value: String) -> String {
    value.replacingOccurrences(of: "[/／、+＋&＆]", with: "", options: .regularExpression)
}

private func lineNameTokens(_ value: String) -> Set<String> {
    Set(
        value
            .components(separatedBy: CharacterSet(charactersIn: "/／、+＋&＆"))
            .filter { !$0.isEmpty }
    )
}

private func suffixSafeContains(_ longer: String, _ shorter: String) -> Bool {
    guard longer != shorter, !shorter.isEmpty else { return false }
    var searchStart = longer.startIndex
    while searchStart < longer.endIndex,
          let range = longer.range(of: shorter, range: searchStart..<longer.endIndex) {
        let before = range.lowerBound == longer.startIndex ? nil : longer[longer.index(before: range.lowerBound)]
        let after = range.upperBound == longer.endIndex ? nil : longer[range.upperBound]
        if before?.isNumber != true, after?.isNumber != true {
            return true
        }
        searchStart = range.upperBound
    }
    return false
}

private func normalizeChineseLineNumber(_ value: String) -> String {
    let source = value as NSString
    let matches = chineseLineNumberExpression.matches(in: value, range: NSRange(location: 0, length: source.length))
    var result = value
    for match in matches.reversed() {
        let text = source.substring(with: match.range)
        guard let number = chineseNumber(text),
              let range = Range(match.range, in: result) else { continue }
        result.replaceSubrange(range, with: String(number))
    }
    return result
}

private func chineseNumber(_ value: String) -> Int? {
    let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]
    var total = 0
    var digit = 0
    for character in value {
        if let value = digits[character] {
            digit = value
        } else if character == "十" {
            total += (digit == 0 ? 1 : digit) * 10
            digit = 0
        } else if character == "百" {
            total += (digit == 0 ? 1 : digit) * 100
            digit = 0
        } else {
            return nil
        }
    }
    return total + digit
}

private func normalizedTime(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.count == 4, text.allSatisfy(\.isNumber) {
        return "\(text.prefix(2)):\(text.suffix(2))"
    }
    return text
}
