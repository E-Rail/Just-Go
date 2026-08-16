import Foundation

enum RoutePreference: String, Codable, CaseIterable, Identifiable {
    case metroFirst
    case fastest
    case cheapest
    case leastWalking
    case fewestTransfers
    case leastConfusing
    case luggageFriendly
    case elderlyFriendly
    case officialDataOnly
    case stepFreeSupport

    var id: Self { self }

    var title: String {
        switch self {
        case .metroFirst:
            return AppLocalization.localized("Transit First")
        case .fastest:
            return AppLocalization.localized("Fastest")
        case .cheapest:
            return AppLocalization.text(english: "Cheapest", simplified: "最便宜", traditional: "最便宜")
        case .leastWalking:
            return AppLocalization.localized("Least Walking")
        case .fewestTransfers: return AppLocalization.localized("Fewest Transfers")
        case .leastConfusing: return AppLocalization.localized("Least Confusing")
        case .luggageFriendly: return AppLocalization.localized("Luggage Friendly")
        case .elderlyFriendly: return AppLocalization.localized("Elderly Friendly")
        case .officialDataOnly: return AppLocalization.localized("Official Data Only")
        case .stepFreeSupport: return AppLocalization.localized("Step-Free Support")
        }
    }

    var icon: String {
        switch self {
        case .metroFirst:
            return "bus.fill"
        case .fastest:
            return "clock"
        case .cheapest:
            return "yensign"
        case .leastWalking:
            return "figure.walk"
        case .fewestTransfers: return "arrow.triangle.branch"
        case .leastConfusing: return "signpost.right.fill"
        case .luggageFriendly: return "suitcase.fill"
        case .elderlyFriendly: return "figure.walk.motion"
        case .officialDataOnly: return "checkmark.seal.fill"
        case .stepFreeSupport: return "accessibility"
        }
    }

    init(routeStrategy: RouteStrategy) {
        switch routeStrategy {
        case .metroFirst:
            self = .metroFirst
        case .fastest:
            self = .fastest
        case .fewestTransfers:
            self = .fewestTransfers
        case .leastWalking:
            self = .leastWalking
        }
    }

    /// The chips shown above the results: the questions a rider actually decides between at the
    /// moment of choosing a route. Everything else is a standing preference rather than a per-trip
    /// one, and stays reachable under "More" instead of being deleted. "Least Walking" in
    /// particular is a real need, it just belongs to whoever set step-free needs in Profile rather
    /// than to a row everyone has to read past.
    ///
    /// Cost earns a chip on the same test. For someone making this trip twice a day, ¥3 against ¥6
    /// is ¥264 a month, which is a per-trip decision in the most literal sense.
    static let primary: [RoutePreference] = [.fastest, .cheapest, .fewestTransfers]

    var isPrimary: Bool {
        Self.primary.contains(self)
    }
}
