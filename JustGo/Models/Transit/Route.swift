import Foundation
import CoreLocation

struct AccessibilityFilter {
    var requiresWheelchairAccess: Bool
    var requiresElevator: Bool
    var avoidStairs: Bool

    static let none = AccessibilityFilter(
        requiresWheelchairAccess: false,
        requiresElevator: false,
        avoidStairs: false
    )
}

struct Route: Identifiable, Codable {
    let id: UUID
    let origin: String
    let destination: String
    let originStationID: String
    let destinationStationID: String
    let strategy: RouteStrategy
    let segments: [RouteSegment]
    let totalDuration: TimeInterval
    let walkingDistance: Double
    let totalStops: Int
    let transferCount: Int
    var isFullyAccessible: Bool
    var stepFreeAssessment: RouteStepFreeAssessment = .unknown
    var warnings: [RouteWarning]
    let accessGuidance: [RouteAccessGuide]
    var dataCoverage: RouteDataCoverage = .unknown
    var serviceStatus: RouteServiceStatus = .unknown
    var crowdControl: RouteCrowdControl = .empty

    var boardingTransitSegment: RouteSegment? {
        segments.first { $0.type.isTransit }
    }

    var formattedDuration: String {
        let minutes = Int(totalDuration / 60)
        return AppLocalization.minutes(minutes)
    }

    var formattedWalkingDistance: String {
        AppLocalization.distance(walkingDistance)
    }

    var formattedTransfers: String {
        AppLocalization.transfers(transferCount)
    }

    var stationTimelineStops: [RouteStationStop] {
        segments.reduce(into: []) { stops, segment in
            for stop in segment.stationStops where stops.last?.stationID != stop.stationID {
                stops.append(stop)
            }
        }
    }

    var originAccessGuide: RouteAccessGuide? {
        accessGuidance.first { $0.kind == .origin }
    }

    var destinationAccessGuide: RouteAccessGuide? {
        accessGuidance.first { $0.kind == .destination }
    }

    var previewRegion: MapVisibleRegion? {
        let coordinates = segments.flatMap { segment -> [CodableCoordinate] in
            if !segment.polylineCoordinates.isEmpty {
                return segment.polylineCoordinates
            }
            return segment.stationStops.compactMap(\.coordinate)
        }

        guard !coordinates.isEmpty else { return nil }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLatitude = latitudes.min(),
              let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(),
              let maxLongitude = longitudes.max() else {
            return nil
        }

        let latitudeDelta = max((maxLatitude - minLatitude) * 1.35, 0.02)
        let longitudeDelta = max((maxLongitude - minLongitude) * 1.35, 0.02)
        return MapVisibleRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }
}

enum RouteStepFreeAssessment: String, Codable, Equatable {
    case confirmed
    case likely
    case unknown
    case barrierDetected

    var supportsStepFreeTravel: Bool {
        self == .confirmed || self == .likely
    }
}

struct RouteDataCoverage: Codable, Equatable {
    let stationCount: Int
    let officialAccessibilityCount: Int
    let officialScheduleCount: Int
    let officialStationMapCount: Int
    let officialFacilityCount: Int

    static let unknown = RouteDataCoverage(
        stationCount: 0,
        officialAccessibilityCount: 0,
        officialScheduleCount: 0,
        officialStationMapCount: 0,
        officialFacilityCount: 0
    )

    var accessibilityConfidence: DataConfidence {
        confidence(available: officialAccessibilityCount)
    }

    var scheduleConfidence: DataConfidence {
        confidence(available: officialScheduleCount)
    }

    var stationMapConfidence: DataConfidence {
        confidence(available: officialStationMapCount)
    }

    var hasOfficialCoreData: Bool {
        officialAccessibilityCount > 0 || officialScheduleCount > 0 ||
            officialStationMapCount > 0 || officialFacilityCount > 0
    }

    var unknownCoreCount: Int {
        guard stationCount > 0 else { return 3 }
        return [
            officialAccessibilityCount,
            officialScheduleCount,
            officialStationMapCount
        ].filter { $0 == 0 }.count
    }

    private func confidence(available: Int) -> DataConfidence {
        guard stationCount > 0 else { return .unknown }
        if available >= stationCount { return .official }
        if available > 0 { return .sourcePending }
        return .unavailable
    }
}

enum DataConfidence: String, Codable, Equatable {
    case official
    case mapKit
    case communityVerified
    case personal
    case estimated
    case sourcePending
    case unavailable
    case unknown

    var label: String {
        switch self {
        case .official: return AppLocalization.localized("Official")
        case .mapKit: return AppLocalization.localized("Apple Maps route data")
        case .communityVerified: return AppLocalization.localized("Community verified")
        case .personal: return AppLocalization.localized("Personal report")
        case .estimated: return AppLocalization.localized("Estimated")
        case .sourcePending: return AppLocalization.localized("Source pending")
        case .unavailable: return AppLocalization.localized("Unavailable")
        case .unknown: return AppLocalization.localized("Unknown")
        }
    }
}

struct RouteConfidence: Equatable {
    let score: Int
    let level: RouteConfidenceLevel
    let explanation: String
    let positiveReasons: [String]
    let warnings: [String]
}

enum RouteConfidenceLevel: Equatable {
    case high
    case medium
    case low

    var title: String {
        switch self {
        case .high: return AppLocalization.localized("High confidence")
        case .medium: return AppLocalization.localized("Medium confidence")
        case .low: return AppLocalization.localized("Low confidence")
        }
    }

    var summary: String {
        switch self {
        case .high: return AppLocalization.localized("Likely smooth")
        case .medium: return AppLocalization.localized("Some uncertainty")
        case .low: return AppLocalization.localized("Check before going")
        }
    }
}

enum RouteStrategy: String, Codable, CaseIterable {
    case metroFirst
    case fastest
    case fewestTransfers
    case leastWalking

    var localizedName: String {
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
    let distance: Double
    let stops: Int
    let stationStops: [RouteStationStop]
    let polylineCoordinates: [CodableCoordinate]
    let walkingDirections: [WalkingStep]?
    let accessibilityNotes: [String]

    var formattedDuration: String {
        let minutes = Int(duration / 60)
        return AppLocalization.minutes(minutes)
    }
}

struct RouteAccessGuide: Identifiable, Codable {
    let id: UUID
    let kind: RouteAccessKind
    let placeName: String
    let stationName: String
    let accessPoint: RouteAccessPoint?
    let walkingDistance: Double
    let walkingDuration: TimeInterval
    let walkingSteps: [WalkingStep]
    let accessibilityNotes: [String]

    var title: String {
        switch kind {
        case .origin:
            return AppLocalization.localized("Boarding Access")
        case .destination:
            return AppLocalization.localized("Arrival Exit")
        }
    }

    var primaryInstruction: String {
        let accessName = accessPoint?.name ?? AppLocalization.localized("station entrance")
        switch kind {
        case .origin:
            return AppLocalization.text(
                english: "Walk from \(placeName) to \(accessName) at \(stationName)",
                simplified: "从\(placeName)步行至\(stationName) \(accessName)",
                traditional: "從\(placeName)步行至\(stationName) \(accessName)"
            )
        case .destination:
            return AppLocalization.text(
                english: "Leave \(stationName) through \(accessName), then walk to \(placeName)",
                simplified: "从\(stationName) \(accessName)出站后步行至\(placeName)",
                traditional: "從\(stationName) \(accessName)出站後步行至\(placeName)"
            )
        }
    }

    var formattedWalk: String {
        guard walkingDuration >= 60 else {
            return AppLocalization.distance(walkingDistance)
        }
        return "\(AppLocalization.distance(walkingDistance)) • \(AppLocalization.minutes(Int(walkingDuration / 60)))"
    }
}

enum RouteAccessKind: String, Codable {
    case origin
    case destination
}

struct RouteAccessPoint: Identifiable, Codable {
    let id: String
    let name: String
    let coordinate: CodableCoordinate?
    let isWheelchairLikely: Bool
    let hasElevatorHint: Bool
    let source: RouteAccessPointSource
}

enum RouteAccessPointSource: String, Codable {
    case mapKit
    case localStationData
    case inferred
    case specificEntrance
    case stationPOI
    case routeBoundary
}

struct RouteStationStop: Identifiable, Codable {
    let stationID: String
    let name: String
    let lineName: String?
    let lineColorHex: String?
    let coordinate: CodableCoordinate?
    let arrivalTimeText: String?
    let isTransfer: Bool

    var id: String {
        "\(stationID)-\(lineName ?? "station")-\(arrivalTimeText ?? "")"
    }
}

struct CodableCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

enum TransitPlaceSource: String, Codable {
    case inputTip
    case poiSearch
    case mapKit
    case reverseGeocode
    case currentLocation
    case quickPlace
    case localStationData
}

enum QuickPlaceKind: String, Codable, CaseIterable, Identifiable {
    case home
    case company
    case school

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .home:
            return AppLocalization.localized("Home")
        case .company:
            return AppLocalization.localized("Company")
        case .school:
            return AppLocalization.localized("School")
        }
    }

    var icon: String {
        switch self {
        case .home:
            return "house.fill"
        case .company:
            return "building.2.fill"
        case .school:
            return "graduationcap.fill"
        }
    }
}

struct QuickPlace: Identifiable, Codable {
    let kind: QuickPlaceKind
    let name: String
    let coordinate: CodableCoordinate
    let entranceCoordinate: CodableCoordinate?
    let address: String?

    var id: String {
        kind.id
    }

    var transitPlace: TransitPlace {
        TransitPlace(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
            type: kind.title,
            address: address,
            entranceCoordinate: entranceCoordinate.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            },
            source: .quickPlace
        )
    }

    init(kind: QuickPlaceKind, place: TransitPlace) {
        self.kind = kind
        name = place.name
        coordinate = CodableCoordinate(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        entranceCoordinate = place.entranceCoordinate.map {
            CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        address = place.address
    }
}

enum SegmentType: String, Codable {
    case walking
    case subway
    case transit
    case transfer

    var isTransit: Bool {
        self == .transit || self == .subway
    }
}

struct WalkingStep: Codable {
    let instruction: String
    let distance: Double
    let duration: TimeInterval
    let isAccessible: Bool
    let road: String?
    let action: String?
    let assistantAction: String?
    let walkType: String?

    var hasStairs: Bool {
        walkType == "20" || combinedText.contains("阶梯") || combinedText.contains("楼梯") || combinedText.localizedCaseInsensitiveContains("stairs")
    }

    var hasRamp: Bool {
        walkType == "21" || combinedText.contains("斜坡") || combinedText.localizedCaseInsensitiveContains("ramp")
    }

    var hasElevator: Bool {
        walkType == "9" || combinedText.contains("直梯") || combinedText.contains("电梯") || combinedText.localizedCaseInsensitiveContains("elevator")
    }

    var hasEscalator: Bool {
        walkType == "8" || combinedText.contains("扶梯") || combinedText.localizedCaseInsensitiveContains("escalator")
    }

    private var combinedText: String {
        [instruction, road, action, assistantAction]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

struct RouteWarning: Identifiable, Codable {
    let type: WarningType
    let message: String
    let affectedStationID: String?

    var id: String {
        "\(type.rawValue)-\(affectedStationID ?? "route")-\(message)"
    }

    enum WarningType: String, Codable {
        case elevatorOutage
        case escalatorOutage
        case serviceDisruption
        case crowding
        case stepFreeAccessUnconfirmed
        case stairsDetected
        case longWalk
        case lastTrainSoon
        case serviceEnded
        case serviceNotStarted
    }
}
