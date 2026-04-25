#if canImport(ActivityKit)
import ActivityKit
import Foundation

struct TransitActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var currentStation: String
        var nextStation: String
        var lineName: String
        var lineColor: String
        var arrivingIn: Int
        var stopsRemaining: Int
        var status: TransitStatus
    }

    var originStation: String
    var destinationStation: String
    var totalStops: Int
}

enum TransitStatus: String, Codable {
    case traveling
    case arriving
    case transferring
    case delayed
}
#endif
