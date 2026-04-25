import Foundation

struct Route: Identifiable, Codable {
    let id: UUID
    let origin: String
    let destination: String
    let originStationID: String
    let destinationStationID: String
    let segments: [RouteSegment]
    let totalDuration: TimeInterval
    let totalStops: Int
    let transferCount: Int
    let accessibilityScore: Double
    let isFullyAccessible: Bool
    let warnings: [RouteWarning]

    var formattedDuration: String {
        let minutes = Int(totalDuration / 60)
        return "\(minutes) min"
    }

    var formattedStops: String {
        "\(totalStops) stops"
    }

    var formattedTransfers: String {
        if transferCount == 0 { return "Direct" }
        return "\(transferCount) transfer\(transferCount > 1 ? "s" : "")"
    }
}

struct RouteSegment: Identifiable, Codable {
    let id: UUID
    let type: SegmentType
    let lineName: String?
    let lineColorHex: String?
    let fromStationName: String?
    let toStationName: String?
    let fromStationID: String?
    let toStationID: String?
    let duration: TimeInterval
    let stops: Int
    let walkingDirections: [WalkingStep]?
    let accessibilityNotes: [String]

    var formattedDuration: String {
        let minutes = Int(duration / 60)
        return "\(minutes) min"
    }
}

enum SegmentType: String, Codable {
    case walking
    case subway
    case transfer
}

struct WalkingStep: Codable {
    let instruction: String
    let distance: Double
    let duration: TimeInterval
    let isAccessible: Bool
}

struct RouteWarning: Codable {
    let type: WarningType
    let message: String
    let affectedStationID: String?

    enum WarningType: String, Codable {
        case elevatorOutage
        case escalatorOutage
        case serviceDisruption
        case crowding
    }
}
