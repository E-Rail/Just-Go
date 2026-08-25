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
    /// Collapses the copies of one station that several packs each ship.
    ///
    /// Neighbouring cities' packs carry the intercity corridor they share, so a station on it is
    /// shipped two or three times: 174 such pairs across the bundled data. Guangzhou's 科韵路
    /// exists in three, and both the map and search would otherwise show all three.
    ///
    /// Identity is identical name **and** colocation, never distance alone: 体育西路 and 天河南 are
    /// 281 m apart and are different stations. The copy that knows the most lines survives, which
    /// is the one carrying the metro service rather than the intercity-only stub.
    ///
    /// One rule, two callers: the marker list and the search results drifted apart once already.
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

    /// This station as a trip endpoint. Three screens built this by hand from the same three
    /// fields; they agreed, but only by coincidence.
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
