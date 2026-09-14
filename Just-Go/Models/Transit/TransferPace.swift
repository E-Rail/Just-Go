import Foundation

/// How long a change between two lines is likely to take, in the three sizes that change what a
/// rider does: under two minutes means do not hurry, over five means leave room. Derived only from
/// a measured corridor, and deliberately not minutes: the metres were observed, the seconds were
/// not.
enum TransferPace: Sendable {
    case quick
    case steady
    case long

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

    /// The bucket a measured corridor length falls into at **this app's** 1.25 m/s, the constant
    /// `BundledMetroRouteProvider` walks legs at. Not the provider's own seconds, which are
    /// `distance ÷ 1.19 m/s` in every sample: a restatement of the metres, not a second
    /// observation.
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
/// figure would average those into a number true of neither.
///
/// The fields hold display names, not identifiers, because `TripStep` and `RouteSegment` carry
/// names; `TransferGeometry.matches` compares them through `TransitLineMatching`.
struct TransferKey: Equatable, Hashable, Sendable {
    let stationID: String
    let fromLineID: String
    let toLineID: String
}
