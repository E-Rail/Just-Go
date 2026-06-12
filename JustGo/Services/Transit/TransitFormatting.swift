import Foundation

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
    value
        .replacingOccurrences(of: "（.*?）|\\(.*?\\)", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "地铁", with: "")
        .replacingOccurrences(of: "轨道交通", with: "")
        .lowercased()
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

private func normalizedTime(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.count == 4, text.allSatisfy(\.isNumber) {
        return "\(text.prefix(2)):\(text.suffix(2))"
    }
    return text
}
