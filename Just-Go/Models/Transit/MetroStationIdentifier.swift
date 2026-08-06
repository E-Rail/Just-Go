import Foundation

/// The `network-<city>-<station>` identifier every screen indexes a bundled station by.
///
/// Minted where the packs are decoded and taken apart in four other files — two of which carried
/// byte-identical copies of the same parser, and a third a subtly stricter one. It is one format,
/// and a station whose ID is read by a slightly different rule does not error: it silently finds no
/// data, which is this app's hardest class of bug to see.
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
}
