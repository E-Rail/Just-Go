import Foundation

/// How the alternatives are ordered.
///
/// Four, matching the three the graph actually searches plus the default. There were ten, over a
/// list that holds at most three routes — the provider runs `.fastest`, `.fewestTransfers` and
/// `.leastWalking` and deduplicates identical edge sequences, so on a short or single-line trip the
/// rider gets one route and ten ways to sort it.
///
/// The six that went were not merely redundant, they could not answer. `officialDataOnly` scored a
/// constant zero on bundled data, because `dataCoverage` is `.unknown` with three zero counts
/// unless an official pack replied. `stepFreeSupport` sorted on a score that starts at 1.0 and only
/// drops for warnings, with no tie-break, so with no warnings it was a no-op. `luggageFriendly` and
/// `elderlyFriendly` were near-monotone in each other and both passed `.default` preferences to the
/// accessibility scorer, ignoring whatever the rider had actually set. `leastConfusing` worked but
/// was `fewestTransfers` with walking mixed in.
///
/// `cheapest` went for a different reason: it is identical to `fastest` whenever no fare was
/// observed, which is every city outside Baidu's coverage and every trip whose gates went
/// unmatched. A chip that silently means something else most of the time is worse than no chip.
/// Cost is still named where it can be checked — `RouteResultsView.bestForReason` calls a route
/// cheapest only when another route was priced and priced higher.
///
/// Step-free need is unaffected: it is honoured through `AccessibilityFilter` and the per-trip
/// chips, which change which routes exist, not merely their order.
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
}
