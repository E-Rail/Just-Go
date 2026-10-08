import ActivityKit
import Foundation

/// What the Lock Screen and the Dynamic Island show of a trip in progress. Compiled into the app,
/// which fills it, and into the Live Activity extension, which draws it.
///
/// Every string arrives already in the rider's language. The extension has no localization of its
/// own, so the app's wording and the Lock Screen's cannot drift apart.
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// SF Symbol for the step under way.
        var symbolName: String
        /// The leg's colour, as the journey rail and the map draw it.
        var colorHex: String
        /// A ride's line as its badge prints it ("2", "S1"); nil for any other step.
        var badge: String?
        /// "Board 2号线", "Walk to Exit C".
        var title: String
        var detail: String?
        /// A ride's stops still ahead, the rider's own included, and the word that goes after the
        /// number ("stops", "站"): a bare "2" in the Dynamic Island counts nothing in particular.
        var stopsRemaining: Int?
        var stopsUnit: String?
        /// The same count in words, with the next stop: "2 stops left · next 东单".
        var stopsText: String?
        /// "Located" or "Estimated"; nil when the rider said where they are.
        var basisText: String?
        var isEstimated: Bool
        /// The step's modelled start and end. The system animates a bar and a countdown between
        /// them by itself, so the activity keeps moving while the app sleeps.
        var stepStartedAt: Date
        var stepEndsAt: Date
        /// Shown in place of the basis once the content has gone stale: the app has stopped
        /// updating, and what is on screen is no longer a position.
        var staleText: String
    }

    /// Where the trip ends.
    var destination: String
}
