import Foundation

/// How long a change between two lines actually took, in the only three sizes that change what a
/// rider does about it.
///
/// Deliberately not a number of minutes. Nobody times their own transfer with a stopwatch, and a
/// rider who reports "3 minutes" is really reporting "a couple of minutes". Storing 3 would dress
/// a rough answer up as a precise one. Three buckets is the finest grain a person can answer
/// honestly from memory, and it is enough: under two minutes means do not hurry, over five means
/// leave room for it.
enum TransferPace: String, Codable, CaseIterable, Identifiable, Sendable {
    case quick
    case steady
    case long

    var id: Self { self }

    var title: String {
        switch self {
        case .quick:
            return AppLocalization.text(english: "Under 2 min", simplified: "2 分钟内", traditional: "2 分鐘內")
        case .steady:
            return AppLocalization.text(english: "2–5 min", simplified: "2–5 分钟", traditional: "2–5 分鐘")
        case .long:
            return AppLocalization.text(english: "Over 5 min", simplified: "超过 5 分钟", traditional: "超過 5 分鐘")
        }
    }

    var icon: String {
        switch self {
        case .quick: return "hare"
        case .steady: return "figure.walk"
        case .long: return "tortoise"
        }
    }

    /// The bucket a measured corridor length falls into, using **this app's** walking model
    /// (1.25 m/s, the same constant `BundledMetroRouteProvider` costs walking legs with).
    ///
    /// Deliberately not the provider's own seconds. Baidu returns a duration alongside the
    /// distance, but it is `distance ÷ 1.19 m/s` in every sample taken. A restatement of the
    /// metres, not a second observation of them. Deriving the bucket here keeps one walking model
    /// in the app instead of importing a second one that only looks like new information.
    init(distanceMetres: Int) {
        let seconds = Double(distanceMetres) / 1.25
        switch seconds {
        case ..<120: self = .quick
        case ..<300: self = .steady
        default: self = .long
        }
    }
}

/// Identifies one change: this station, from this line to that one.
///
/// Line-pair rather than station alone, because the two are not the same question. 西直门 is a
/// two-minute change between two of its lines and a long walk between another pair; a per-station
/// answer would average those into a number true of neither.
struct TransferKey: Codable, Equatable, Hashable, Sendable {
    let stationID: String
    let fromLineID: String
    let toLineID: String

    /// Stable across direction. A rider changing 2→13 and one changing 13→2 walk the same corridor,
    /// so they answer the same question and belong in the same bucket.
    var storageID: String {
        let pair = [fromLineID, toLineID].sorted()
        return "\(stationID)|\(pair[0])|\(pair[1])"
    }
}

/// One rider's answer, kept on their own device.
struct TransferNote: Codable, Equatable, Sendable {
    let key: TransferKey
    let pace: TransferPace
    let recordedAt: Date
}
