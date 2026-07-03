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

/// A rough single-journey metro fare estimate derived from total transit distance,
/// using the common mainland tiered model (¥3 ≤6km, ¥4 ≤12km, ¥5 ≤22km, ¥6 ≤32km,
/// then +¥1 per additional 20km). Presented to the user as an estimate only.
struct FareEstimate {
    let amountCNY: Int

    init(transitMeters: Double) {
        // A non-finite distance only arises from corrupted route data; fall back to the base
        // fare rather than trapping in Int(...) below.
        guard transitMeters.isFinite else { amountCNY = 3; return }
        // Exclusive-above tier boundaries (≤6km ¥3, ≤12km ¥4, …) per the published table.
        // Compare the fractional kilometre value directly — rounding to whole metres first
        // would pull a route just past a boundary (e.g. 6000.3 m) back into the cheaper tier.
        let km = max(0, transitMeters) / 1000
        switch km {
        case ...6: amountCNY = 3
        case ...12: amountCNY = 4
        case ...22: amountCNY = 5
        case ...32: amountCNY = 6
        default: amountCNY = 6 + Int(ceil((km - 32) / 20.0))
        }
    }

    /// e.g. "¥5" — pair with an "estimate" label in the UI.
    var formatted: String { "¥\(amountCNY)" }
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
    var accessGuidance: [RouteAccessGuide]
    var dataCoverage: RouteDataCoverage = .unknown
    var serviceStatus: RouteServiceStatus = .unknown
    var crowdControl: RouteCrowdControl = .empty
    var stationGuidance: [RouteStationGuidance] = []

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

    /// Rough distance-based single-journey metro fare estimate using the common
    /// mainland tiered model. Labeled as an estimate in the UI — actual fares vary
    /// by city. Nil for walking-only routes (no transit distance).
    var estimatedFare: FareEstimate? {
        let transitMeters = segments
            .filter { $0.type.isTransit }
            .reduce(0.0) { $0 + $1.distance }
        guard transitMeters > 0 else { return nil }
        return FareEstimate(transitMeters: transitMeters)
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

    var boardingGuidance: RouteStationGuidance? {
        stationGuidance.first { $0.role == .boarding }
    }

    var arrivalGuidance: RouteStationGuidance? {
        stationGuidance.first { $0.role == .arrival }
    }

    /// Total estimated walking time across every transfer this route requires, from whichever
    /// interchange hints are authored (0 when none are).
    var transferWalkingMinutes: Double {
        stationGuidance.compactMap { $0.interchange?.walkingMinutes }.reduce(0, +)
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
        case .mapKit: return AppLocalization.text(english: "Estimated from maps", simplified: "来自地图估算", traditional: "來自地圖估算")
        case .communityVerified: return AppLocalization.localized("Community verified")
        case .personal: return AppLocalization.localized("Personal report")
        case .estimated: return AppLocalization.localized("Estimated")
        case .sourcePending: return AppLocalization.localized("Source pending")
        case .unavailable: return AppLocalization.localized("Not available")
        case .unknown: return AppLocalization.text(english: "No data", simplified: "暂无数据", traditional: "暫無數據")
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

extension RouteSegment: Hashable {
    static func == (lhs: RouteSegment, rhs: RouteSegment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

extension RouteStationStop: Hashable {
    static func == (lhs: RouteStationStop, rhs: RouteStationStop) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension RouteStationStop {
    /// A lightweight `Station` built from this stop's own fields, for contexts (map markers,
    /// a resolve-failure fallback) that need a `Station` but only have route-stop data, not a
    /// full city-pack lookup.
    func asStation(cityID: String) -> Station {
        Station(
            stationID: stationID,
            name: name,
            latitude: coordinate?.latitude ?? 0,
            longitude: coordinate?.longitude ?? 0,
            cityID: cityID,
            isTransferStation: isTransfer
        )
    }
}

// MARK: - Transit guidance (entrance/exit, platform, interchange)

enum AccessPointKind: String, Codable {
    case entrance
    case exit
    case elevator
    case escalator
    case unknown
}

/// A specific station entrance/exit (or vertical-access point). Either authored in a city pack
/// (`source == .specificEntrance`/`.localStationData`, `confidence == .official`) or best-effort
/// extracted from accessibility text (`source == .inferred`, `confidence == .estimated`).
struct StationAccessPoint: Identifiable, Codable {
    let id: String
    let name: String
    let kind: AccessPointKind
    let coordinate: CodableCoordinate?
    let isAccessible: Bool
    let notes: [String]
    let source: RouteAccessPointSource
    let confidence: DataConfidence
}

/// Boarding tips for a platform (which car, which door side). Authored-only; absent in packs today.
struct StationPlatformHint: Codable {
    let lineName: String?
    let directionText: String?
    let boardingCarText: String?
    let doorSideText: String?
    let notes: [String]
}

/// Transfer-corridor hint between two lines at an interchange. Authored-only; absent today.
struct StationInterchangeHint: Codable {
    let fromLineName: String?
    let toLineName: String?
    let walkingMeters: Double?
    let walkingMinutes: Double?
    let notes: [String]
}

/// Per-route, per-station guidance attached during route enrichment (boarding/transfer/arrival).
struct RouteStationGuidance: Identifiable, Codable {
    enum Role: String, Codable {
        case boarding
        case transfer
        case arrival
    }

    let stationID: String
    let stationName: String
    let role: Role
    let exit: StationAccessPoint?
    let interchange: StationInterchangeHint?
    let confidence: DataConfidence

    var id: String { "\(stationID)-\(role.rawValue)" }
}

/// Render-ready comparison metrics for one route, computed across all alternatives.
struct RouteComparisonMetrics: Identifiable {
    let id: UUID
    let rank: Int
    let durationText: String
    let transferText: String
    let walkingText: String
    let transferEffort: String
    let exitConfidence: DataConfidence
    let bestForReason: String
}

/// Per-station access guidance returned by the city-pack service: best-available exits/entrances,
/// optional platform/interchange hints, and a confidence describing the data source.
struct StationAccessGuidance {
    let accessPoints: [StationAccessPoint]
    let platformHints: [StationPlatformHint]
    let interchangeHints: [StationInterchangeHint]
    let confidence: DataConfidence

    static let empty = StationAccessGuidance(
        accessPoints: [],
        platformHints: [],
        interchangeHints: [],
        confidence: .unavailable
    )

    /// The recommended exit/entrance to surface (prefers an explicit exit, then any point).
    var primaryAccessPoint: StationAccessPoint? {
        accessPoints.first { $0.kind == .exit } ?? accessPoints.first
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
