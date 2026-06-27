import Foundation

/// Persists the route of an in-progress Live "Go" trip so it survives the app being
/// terminated by iOS (e.g. while the user is underground with no signal). The trip is
/// saved when Live Go starts and cleared when it is dismissed normally; if the app is
/// killed mid-trip, the saved route remains and the planner offers to resume it.
enum ActiveTripStore {
    private static let key = "activeLiveTrip"

    static func save(_ route: Route) {
        UserDefaults.standard.setCodable(route, forKey: key)
    }

    static func load() -> Route? {
        UserDefaults.standard.codableValue(forKey: key, as: Route?.self, default: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
