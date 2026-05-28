import Foundation

func formatScheduleText(first: String?, last: String?) -> String? {
    let firstText = normalizeTimeText(first)
    let lastText = normalizeTimeText(last)

    switch (firstText, lastText) {
    case let (first?, last?):
        return AppLocalization.text(
            english: "First \(first), last \(last)",
            simplified: "首班 \(first)，末班 \(last)",
            traditional: "首班 \(first)，末班 \(last)"
        )
    case let (first?, nil):
        return AppLocalization.text(
            english: "First \(first)",
            simplified: "首班 \(first)",
            traditional: "首班 \(first)"
        )
    case let (nil, last?):
        return AppLocalization.text(
            english: "Last \(last)",
            simplified: "末班 \(last)",
            traditional: "末班 \(last)"
        )
    default:
        return nil
    }
}

private func normalizeTimeText(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.count == 4, text.allSatisfy(\.isNumber) {
        let hour = text.prefix(2)
        let minute = text.suffix(2)
        return "\(hour):\(minute)"
    }
    return text
}

func normalizeTransitLineName(_ value: String) -> String {
    var text = value
        .components(separatedBy: "(").first ?? value
    text = text.replacingOccurrences(of: "（.*?）|\\(.*?\\)", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "北京", with: "")
    text = text.replacingOccurrences(of: "地铁", with: "")
    text = text.replacingOccurrences(of: "轨道交通", with: "")
    return text.lowercased()
}

func normalizeStationKey(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "地铁站", with: "")
        .lowercased()
}

extension SubwayLineData {
    var scheduleCandidateLineIDs: [String] {
        uniqueScheduleValues(
            lineID.split(separator: "|").map(String.init) +
            (amapLineIDs ?? []) +
            [lineID]
        )
    }

    var scheduleQueryNames: [String] {
        var names = [name, localizedName]
        names.append(AppLocalization.chinese(name))
        names.append(name.replacingOccurrences(of: "地铁", with: ""))
        return uniqueScheduleValues(names)
    }
}

private func uniqueScheduleValues(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
}
