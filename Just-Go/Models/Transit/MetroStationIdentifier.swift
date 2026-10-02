import Foundation

/// The `network-<city>-<station>` identifier every screen indexes a bundled station by. One parser:
/// an ID read by a slightly different rule does not error, it silently finds no data.
enum MetroStationIdentifier {
    private static let prefix = "network-"

    static func qualified(cityID: String, stationID: String) -> String {
        "\(prefix)\(cityID)-\(stationID)"
    }

    /// Which pack an identifier names, or nil when it is not in the synthesised form.
    static func cityID(of identifier: String) -> String? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let rest = identifier.dropFirst(prefix.count)
        guard let separator = rest.firstIndex(of: "-") else { return nil }
        return String(rest[rest.startIndex..<separator])
    }

    /// The bare station ID the packs and the station-information directory are keyed by. Anything
    /// not in the synthesised form is already canonical and comes back unchanged.
    static func canonical(_ identifier: String) -> String {
        guard identifier.hasPrefix(prefix),
              let separator = identifier.dropFirst(prefix.count).firstIndex(of: "-") else {
            return identifier
        }
        return String(identifier[identifier.index(after: separator)...])
    }

    /// Whether a record found by *name* may stand for this station. Names repeat across a network:
    /// 顺义 on 15号线 and on 通密线 are 1.1 km apart, and Wuhan's 光谷大道 tram stop is 4.7 km from the
    /// metro station. A record bound to another network station describes that station, and its
    /// doors are worse than none. A place or a provider's stop is not a network station, and a
    /// record with no station ID is bound to nothing, so those still match by name.
    static func nameMatch(forStationID stationID: String?, mayUseRecordOf recordStationID: String?) -> Bool {
        guard let stationID, cityID(of: stationID) != nil,
              let recordStationID, !recordStationID.isEmpty else { return true }
        return canonical(recordStationID) == canonical(stationID)
    }
}
