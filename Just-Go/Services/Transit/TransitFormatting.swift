import Foundation

private let scheduleUnknownLineColorHex = "#8E8E93"
private let lineSeparatorExpression = try! NSRegularExpression(pattern: "[/／、+＋&＆]")

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

extension SubwayLine {
    var logicalLineIdentity: String {
        "\(cityID.lowercased())|\(lineID.lowercased())"
    }
}

extension Array where Element == Station {
    /// Collapses the copies of one station that several packs ship (neighbouring packs carry their
    /// shared intercity corridor; 科韵路 is in three). Identity is identical name **and** colocation,
    /// never distance alone: 体育西路 and 天河南 are 281 m apart and different. The copy knowing the most
    /// lines survives. One rule for the map's markers and the search results.
    func oneEntryPerPlace() -> [Station] {
        var kept: [Station] = []
        kept.reserveCapacity(count)
        var indicesByName: [String: [Int]] = [:]
        for station in self {
            let key = normalizedStationName(station.name)
            let match = indicesByName[key, default: []].first {
                kept[$0].coordinate.distance(to: station.coordinate) <= 250
            }
            if let match {
                if station.lines.count > kept[match].lines.count { kept[match] = station }
            } else {
                indicesByName[key, default: []].append(kept.count)
                kept.append(station)
            }
        }
        return kept
    }
}

extension Station {
    var uniqueLogicalLines: [SubwayLine] {
        lines.uniqued(by: \.logicalLineIdentity)
    }

    /// This station as a trip endpoint.
    var asTransitPlace: TransitPlace {
        TransitPlace(name: localizedName, coordinate: coordinate, source: .mapKit)
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

/// How a rider is told which train a service row describes, the same on the route sheet and the
/// station sheet. Where the direction marker and the terminus differ, the terminus wins: it is what
/// the train is labelled with and what decides whether it reaches the rider's stop (at 国贸 all three
/// northbound 10号线 services read 双井 and end at 车道沟, 成寿寺 and 巴沟).
func serviceDirectionLabel(direction: String?, destination: String?) -> String? {
    let marker = direction?.trimmingCharacters(in: .whitespacesAndNewlines)
    let terminus = destination?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let terminus, !terminus.isEmpty { return terminus }
    guard let marker, !marker.isEmpty else { return nil }
    return marker
}

/// The same labels, made distinguishable. On a ring both directions can end at the same terminus
/// (国贸 on 10号线: 车道沟 / 成寿寺 / 巴沟 / 巴沟 / 车道沟). Where a label repeats, the direction marker, the next
/// station that way and what the platform sign shows, separates them.
func distinguishedServiceLabels<Service: ServiceDirectionNaming>(_ services: [Service]) -> [String?] {
    let labels = services.map { serviceDirectionLabel(direction: $0.directionMarker, destination: $0.serviceDestination) }
    var counts: [String: Int] = [:]
    for label in labels.compactMap({ $0 }) { counts[label, default: 0] += 1 }

    return zip(labels, services).map { label, service in
        guard let label, counts[label, default: 0] > 1 else { return label }
        guard let marker = service.directionMarker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !marker.isEmpty, marker != label else { return label }
        return AppLocalization.text(
            english: "\(label) via \(marker)",
            simplified: "\(label)（经\(marker)）",
            traditional: "\(label)（經\(marker)）"
        )
    }
}

/// A service row that can name where it is going. The resolver's `StationServiceWindow` and the
/// wire's `OfficialStationServiceInformation` both carry this, and the two sheets must not disagree
/// about a service's name.
protocol ServiceDirectionNaming {
    var directionMarker: String? { get }
    var serviceDestination: String? { get }
}

extension StationServiceWindow: ServiceDirectionNaming {
    var directionMarker: String? { direction }
    var serviceDestination: String? { destination }
}

extension OfficialStationServiceInformation: ServiceDirectionNaming {
    var directionMarker: String? { direction }
    var serviceDestination: String? { destination }
}

/// The source's own words for which service day its times describe, shown only when it is not
/// today's (Hangzhou's `工作日时刻表` on a weekend). It checks only whether the note says "weekday" and
/// whether today is one; otherwise it stays quiet.
func serviceDayCaveat(_ note: String?, on date: Date) -> String? {
    guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
    guard note.contains("工作日") else { return nil }
    // ChinaClock weekday: 1 = Sunday … 7 = Saturday.
    let weekday = ChinaClock.weekday(of: date)
    guard weekday == 1 || weekday == 7 else { return nil }
    return AppLocalization.text(
        english: "Weekday timetable — the operator publishes no weekend times",
        simplified: "工作日时刻表 —— 运营方未公布周末时间",
        traditional: "工作日時刻表 —— 營運方未公布週末時間"
    )
}
