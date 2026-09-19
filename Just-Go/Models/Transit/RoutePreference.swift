import Foundation

/// How the alternatives are ordered: the three searches the graph runs, plus transit-first. Only
/// orders that change what a rider sees belong here; there is no "cheapest", which would equal
/// "fastest" wherever no fare was observed.
///
/// Step-free need is not a sort: it is `AccessibilityFilter` and the per-trip chips, which change
/// which routes exist.
enum RoutePreference: String, Codable, CaseIterable, Identifiable {
    case metroFirst
    case fastest
    case fewestTransfers
    case leastWalking

    var id: Self { self }

    var title: String {
        switch self {
        case .metroFirst:
            return AppLocalization.localized("Transit First")
        case .fastest:
            return AppLocalization.localized("Fastest")
        case .fewestTransfers:
            return AppLocalization.localized("Fewest Transfers")
        case .leastWalking:
            return AppLocalization.localized("Least Walking")
        }
    }

    var icon: String {
        switch self {
        case .metroFirst:
            return "bus.fill"
        case .fastest:
            return "clock"
        case .fewestTransfers:
            return "arrow.triangle.branch"
        case .leastWalking:
            return "figure.walk"
        }
    }
}
