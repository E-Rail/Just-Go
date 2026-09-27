import Foundation

/// Comparing the names two sources give one line or station. Kept free of the transit model so
/// `Scripts/test_service_hours_resolver.sh` can build it with `ChinaClock` and the resolver alone:
/// whether a rider's last train has gone rests on it.

private let chineseLineNumberExpression = try! NSRegularExpression(pattern: "[零〇一二三四五六七八九十百]+(?=号线)")

// Compiled once; `NSRegularExpression` is immutable and thread-safe.
private let whitespaceExpression = try! NSRegularExpression(pattern: "\\s+")
private let parentheticalExpression = try! NSRegularExpression(pattern: "（.*?）|\\(.*?\\)")
private let lineReferenceExpression = try! NSRegularExpression(pattern: "[a-z]?\\d+(?=号?线|$)")

extension String {
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

private let traditionalToSimplified = StringTransform("Hant-Hans")

/// A name as search compares it: lowercased, with Traditional characters folded to Simplified, so
/// 南京复兴 finds 南京復興, 西直門 finds 西直门, and 后湖大道 finds the 後湖大道 OSM ships for Wuhan.
/// Fold both sides and never show the result: the fold is lossy (乾 → 干, 垵 → 埯), so only a
/// comparison of two folded strings means anything.
func searchFoldedName(_ value: String) -> String {
    let lowered = value.lowercased()
    // An English name has nothing to fold, and skipping ICU keeps its cost off half the index.
    guard !lowered.allSatisfy(\.isASCII) else { return lowered }
    return lowered.applyingTransform(traditionalToSimplified, reverse: false) ?? lowered
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
