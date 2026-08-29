import Foundation

/// Persists the route of an in-progress Live "Go" trip so it survives the app being
/// terminated by iOS (e.g. while the user is underground with no signal). The trip is
/// saved when Live Go starts and cleared when it is dismissed normally; if the app is
/// killed mid-trip, the saved route remains and the planner offers to resume it.
enum ActiveTripStore {
    private static let key = "activeLiveTrip"

    /// Saved without the numbers an observation provider supplied.
    ///
    /// A `Route` is one `Codable` struct, so persisting it persists everything enrichment attached
    /// to it, including the fare and the missed-train taxi price that came back from Baidu. Those
    /// are the provider's content and the app's rule is that it is read on the device and kept
    /// nowhere, which `validate_runtime_data_policy.rb` enforces on the two files that *fetch* it.
    /// The check cannot see this far down the chain, so the stripping happens here, at the only
    /// place a route reaches disk.
    ///
    /// Nothing is lost: what resuming needs is the plan, not its price.
    static func save(_ route: Route) {
        UserDefaults.standard.setCodable(route.withoutObservedPricing, forKey: key)
    }

    static func load() -> Route? {
        UserDefaults.standard.codableValue(forKey: key, as: Route?.self, default: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
