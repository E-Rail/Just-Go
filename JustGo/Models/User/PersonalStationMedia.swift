import Foundation

/// Stable identity for media attached to a station. Personal media is visual-only and
/// deliberately carries no routing, accessibility, or indoor-navigation semantics.
struct PersonalStationMediaKey: Codable, Hashable, Sendable {
    let cityID: String
    let canonicalStationID: String

    init(cityID: String, canonicalStationID: String) {
        self.cityID = Self.normalized(cityID)
        self.canonicalStationID = Self.normalized(canonicalStationID)
    }

    /// Converts the app's display-network identifier back to the stable station identifier.
    /// Provider fallback IDs are intentionally rejected because they are not canonical.
    init?(cityID: String, stationID: String) {
        let normalizedCityID = Self.normalized(cityID)
        let normalizedStationID = Self.normalized(stationID)
        let networkPrefix = "network-\(normalizedCityID)-"

        guard !normalizedCityID.isEmpty, normalizedStationID.hasPrefix(networkPrefix) else { return nil }
        let canonical = String(normalizedStationID.dropFirst(networkPrefix.count))
        guard !canonical.isEmpty else { return nil }
        self.cityID = normalizedCityID
        self.canonicalStationID = canonical
    }

    var isValid: Bool {
        !cityID.isEmpty &&
            !canonicalStationID.isEmpty &&
            cityID.utf8.count <= 512 &&
            canonicalStationID.utf8.count <= 512
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

/// An immutable view of one sanitized JPEG in the app's private media directory.
struct PersonalStationMediaItem: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let stationKey: PersonalStationMediaKey
    let fileURL: URL
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
}
