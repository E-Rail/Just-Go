import Foundation

/// Persists the route of an in-progress Live Go trip so it survives iOS terminating the app
/// (underground, with no signal). Saved when guidance starts, cleared when it ends normally; a
/// route still here at launch is offered for resuming.
enum ActiveTripStore {
    private static let key = "activeLiveTrip"

    /// Saved without the prices an observation provider supplied. Baidu's content is read on the
    /// device and kept nowhere; `validate_runtime_data_policy.rb` enforces that on the files that
    /// fetch it but cannot see this far down the chain, so the stripping happens here, where a
    /// route reaches disk. Resuming needs the plan, not its price.
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
