import Foundation

private let chineseLineNumberExpression = try! NSRegularExpression(pattern: "[零〇一二三四五六七八九十百]+(?=号线)")
private let scheduleUnknownLineColorHex = "#8E8E93"

// Pre-compiled once instead of recompiling the pattern on every call. NSRegularExpression is
// immutable and thread-safe.
private let whitespaceExpression = try! NSRegularExpression(pattern: "\\s+")
private let parentheticalExpression = try! NSRegularExpression(pattern: "（.*?）|\\(.*?\\)")
private let lineReferenceExpression = try! NSRegularExpression(pattern: "[a-z]?\\d+(?=号?线|$)")
private let lineSeparatorExpression = try! NSRegularExpression(pattern: "[/／、+＋&＆]")

private extension String {
    func removingMatches(of expression: NSRegularExpression) -> String {
        let range = NSRange(startIndex..., in: self)
        return expression.stringByReplacingMatches(in: self, range: range, withTemplate: "")
    }

    func firstMatch(of expression: NSRegularExpression) -> String? {
        let range = NSRange(startIndex..., in: self)
        guard let match = expression.firstMatch(in: self, range: range),
              let matchRange = Range(match.range, in: self) else { return nil }
        return String(self[matchRange])
    }
}

struct ScheduleLineColorResolver {
    private struct IndexedLine {
        let line: MetroLine
        let fullNames: Set<String>
        let simplifiedNames: Set<String>
        let references: Set<String>
        let logicalIDs: Set<String>
    }

    private let stationLines: [IndexedLine]
    private let globalLines: [IndexedLine]

    init(network: MetroNetwork?, stationLineIDs: Set<String>) {
        let indexedLines = network?.lines.map(Self.index) ?? []
        stationLines = indexedLines.filter { stationLineIDs.contains($0.line.id) }
        globalLines = indexedLines
    }

    func colorHex(for lineName: String) -> String {
        let target = Self.target(for: lineName)
        if !stationLines.isEmpty {
            return resolve(target, in: stationLines, allowFuzzyMatching: true, allowSoleLineFallback: true) ??
                scheduleUnknownLineColorHex
        }
        return resolve(target, in: globalLines, allowFuzzyMatching: false, allowSoleLineFallback: false) ??
            scheduleUnknownLineColorHex
    }

    private func resolve(
        _ target: Target,
        in lines: [IndexedLine],
        allowFuzzyMatching: Bool,
        allowSoleLineFallback: Bool
    ) -> String? {
        var matchers: [((IndexedLine) -> Bool)] = [
            { !$0.fullNames.isDisjoint(with: target.fullNames) },
            { !$0.references.isDisjoint(with: target.references) },
            { !$0.logicalIDs.isDisjoint(with: target.logicalIDs) },
            { !$0.simplifiedNames.isDisjoint(with: target.simplifiedNames) }
        ]
        if allowFuzzyMatching {
            matchers.append { line in
                line.simplifiedNames.contains { name in
                    target.simplifiedNames.contains {
                        compactLineName(name) == compactLineName($0) ||
                            lineNameTokens(name) == lineNameTokens($0) ||
                            suffixSafeContains(name, $0) ||
                            suffixSafeContains($0, name)
                    }
                }
            }
        }

        for matches in matchers {
            let colors = Set(lines.filter(matches).map(\.line.colorHex))
            if colors.count == 1 { return colors.first }
            if !colors.isEmpty { return nil }
        }
        if allowSoleLineFallback, lines.count == 1 {
            return lines[0].line.colorHex
        }
        return nil
    }

    private struct Target {
        let fullNames: Set<String>
        let simplifiedNames: Set<String>
        let references: Set<String>
        let logicalIDs: Set<String>
    }

    private static func target(for value: String) -> Target {
        let full = fullTransitLineName(value)
        let simplified = simplifiedTransitLineName(value)
        return Target(
            fullNames: Set([full]).filter { !$0.isEmpty },
            simplifiedNames: Set([simplified]).filter { !$0.isEmpty },
            references: transitLineReferences(value),
            logicalIDs: Set([full, simplified]).filter { !$0.isEmpty }
        )
    }

    private static func index(_ line: MetroLine) -> IndexedLine {
        let names = [line.name, line.nameEn].compactMap { $0 }
        return IndexedLine(
            line: line,
            fullNames: Set(names.map(fullTransitLineName)).filter { !$0.isEmpty },
            simplifiedNames: Set(names.map(simplifiedTransitLineName)).filter { !$0.isEmpty },
            references: Set(names.flatMap(transitLineReferences))
                .union(transitLineReferences(line.routeReference ?? "")),
            logicalIDs: Set([line.id, line.logicalLineID].compactMap { $0 }.map(fullTransitLineName))
        )
    }
}

func fullTransitLineName(_ value: String) -> String {
    normalizeChineseLineNumber(
        value
        .removingMatches(of: whitespaceExpression)
        .replacingOccurrences(of: "地铁", with: "")
        .replacingOccurrences(of: "轨道交通", with: "")
        .lowercased()
    )
}

func simplifiedTransitLineName(_ value: String) -> String {
    fullTransitLineName(value)
        .removingMatches(of: parentheticalExpression)
}

func transitLineReferences(_ value: String) -> Set<String> {
    let normalized = simplifiedTransitLineName(value)
    var references = Set<String>()
    if !normalized.isEmpty { references.insert(normalized) }
    if let reference = normalized.firstMatch(of: lineReferenceExpression) {
        references.insert(reference)
    }
    return references
}

func normalizedStationName(_ value: String) -> String {
    value
        .lowercased()
        .replacingOccurrences(of: "地铁站", with: "")
        .replacingOccurrences(of: "地铁", with: "")
        .replacingOccurrences(of: "站", with: "")
        .replacingOccurrences(of: "metro station", with: "")
        .replacingOccurrences(of: "subway station", with: "")
        .replacingOccurrences(of: "station", with: "")
        .replacingOccurrences(of: " ", with: "")
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
    value.removingMatches(of: lineSeparatorExpression)
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
