import ActivityKit
import Foundation

/// What the Lock Screen and the Dynamic Island show of a trip in progress. Compiled into the app,
/// which fills it, and into the Live Activity extension, which draws it.
///
/// Every string arrives already in the rider's language. The extension has no localization of its
/// own, so the app's wording and the Lock Screen's cannot drift apart.
///
/// Nothing here is a date. The system can run a countdown between two dates by itself, and a
/// ticking number is a timer; what is drawn is the app's last word on where the rider is, and it
/// is marked stale once the app has missed the moment it should have spoken again.
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
        /// The step in the plan's words, which stay true whatever has happened since.
        var detail: String?
        /// A ride's stops still ahead, the rider's own included, and the word that goes after the
        /// number ("stops", "站"): a bare "2" in the Dynamic Island counts nothing in particular.
        var stopsRemaining: Int?
        var stopsUnit: String?
        /// The same count in words, "2 stops left", and on the last hop the cue to get off; and
        /// the stop the train reaches next, while there is one before the rider's own.
        var stopsText: String?
        var nextStopText: String?
        /// "Located" or "Estimated"; nil when the rider said where they are.
        var basisText: String?
        var isEstimated: Bool
        /// When the trip is expected to end, as a clock reads ("14:51"), and the words that say it
        /// is an estimate. Nil once arrived.
        var arrivalText: String?
        var arrivalCaption: String
        /// The step as a picture. Nil once arrived: there is no leg left to draw.
        var leg: Leg?
        /// Shown in place of the basis once the content has gone stale: the app has stopped
        /// updating, and what is on screen is no longer a position.
        var staleText: String
    }

    /// One leg drawn as a strip: where it starts, the track the rider moves along, the place it
    /// ends, and the line that leaves from there.
    struct Leg: Codable, Hashable {
        /// The line the rider has just left, for the dot the leg starts from. Nil when the leg
        /// starts where the rider set out, which is drawn as the rider.
        var startColorHex: String?
        /// The track's dash in multiples of its own width, as `SegmentType.dash(width:)` gives it.
        /// Empty is solid.
        var dash: [Double]
        /// The track in equal parts and how many of them the rider is into it. On a ride the parts
        /// are its hops and each ends at a stop.
        var parts: Int
        var place: Double
        var marksStops: Bool
        /// Where the leg ends: a station, or the trip's destination.
        var endName: String?
        /// The colour of the line that station is on. Nil when the leg ends the trip.
        var endColorHex: String?
        /// The next line the rider takes from there, as its badge prints it, and its colour.
        var onwardBadge: String?
        var onwardColorHex: String?
    }

    /// Where the trip ends.
    var destination: String
}
