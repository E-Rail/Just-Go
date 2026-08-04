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
        guard !normalizedCityID.isEmpty,
              MetroStationIdentifier.cityID(of: normalizedStationID) == normalizedCityID else { return nil }
        let canonical = MetroStationIdentifier.canonical(normalizedStationID)
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

/// What question a photo answers. A picture of a named thing helps a stranger standing where the
/// contributor stood; an unlabelled snapshot of a corridor does not, and there is no way to
/// recover the intent later. Asked once, at capture, while the rider still remembers why they
/// took it.
///
/// Deliberately carries no display strings: this file is compiled standalone by
/// `Scripts/test_personal_station_media.sh`, which has no `AppLocalization`. The title and icon
/// live beside the view that draws them.
enum PersonalStationMediaSubject: String, Codable, CaseIterable, Sendable {
    case transferCorridor
    case exitSign
    case platform
    case stationMap

}

/// How far a photo has travelled toward being visible to other riders.
///
/// Only `.local` is ever written today — nothing is uploaded yet, and the UI says so rather than
/// implying a photo has been shared. The rest of the cases exist now so that turning the upload on
/// is a migration of *state* rather than of schema: an installed app's stored index already has
/// somewhere to record a server ID and a moderation outcome.
enum PersonalStationMediaShareState: String, Codable, Sendable {
    /// On this device only. Every photo starts here.
    case local
    /// The rider asked to share it; waiting for a network.
    case queued
    /// Uploaded, awaiting review.
    case submitted
    /// Reviewed and visible to other riders.
    case published
    /// Reviewed and declined. Kept on the device; the rider still has their photo.
    case rejected
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
    let subject: PersonalStationMediaSubject
    let shareState: PersonalStationMediaShareState
    /// The server's identifier once this photo has been uploaded. Nil until then.
    let remoteID: String?
}
