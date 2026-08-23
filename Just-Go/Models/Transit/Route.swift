import Foundation
import CoreLocation

struct AccessibilityFilter {
    var requiresWheelchairAccess: Bool
    var requiresElevator: Bool
    var avoidStairs: Bool
    /// How far the rider is willing to walk to reach a station, from Accessibility Settings.
    /// Carried on the filter because the route assembler needs it and only ever receives this.
    /// It is what decides whether the first mile is walked, cycled or driven.
    var maxWalkingDistance: Double = 500

    static let none = AccessibilityFilter(
        requiresWheelchairAccess: false,
        requiresElevator: false,
        avoidStairs: false
    )

    /// Whether the rider needs the entrance itself to be step-free. All three settings imply it:
    /// a wheelchair cannot use a stepped entrance, "needs a lift" is the same requirement stated
    /// by the equipment, and avoiding stairs is exactly what a step-free entrance is for.
    var requiresStepFreeEntrance: Bool {
        requiresWheelchairAccess || requiresElevator || avoidStairs
    }
}

struct Route: Identifiable, Codable {
    let id: UUID
    let origin: String
    let destination: String
    let originStationID: String
    let destinationStationID: String
    let strategy: RouteStrategy
    // Mutable for the same reason `warnings` and `accessGuidance` are: enrichment re-walks the
    // first and last legs once it knows which door the rider should use, and the distance that
    // summarises them has to follow.
    var segments: [RouteSegment]
    let totalDuration: TimeInterval
    var walkingDistance: Double
    let totalStops: Int
    let transferCount: Int
    var isFullyAccessible: Bool
    var stepFreeAssessment: RouteStepFreeAssessment = .unknown
    var warnings: [RouteWarning]
    var accessGuidance: [RouteAccessGuide]
    var dataCoverage: RouteDataCoverage = .unknown
    var serviceStatus: RouteServiceStatus = .unknown
    var stationGuidance: [RouteStationGuidance] = []
    /// What this journey costs, when a fare was observed for the same pair of gates. `nil` means
    /// nobody priced it and the screens say nothing, which is the answer for every city outside
    /// Baidu's coverage and for every route whose boarding and alighting stations went unmatched.
    var fare: RouteFare?
    /// What a taxi over the same ground costs at the hour this trip departs.
    ///
    /// Carried only when the trip is against the clock, meaning the last train is close or already
    /// gone. The app already knew that much and said nothing about what it would cost to be wrong,
    /// which for a rider on a late shift is the part that decides whether they run for the train.
    var missedTrainTaxiYuan: Double?

    var boardingTransitSegment: RouteSegment? {
        segments.first { $0.type.isTransit }
    }

    /// `totalDuration` is `let` and stays that way. A route's headline number should not be
    /// quietly mutable, so re-costing rebuilds the value instead.
    func replacingSegments(_ newSegments: [RouteSegment], totalDuration newTotal: TimeInterval) -> Route {
        Route(
            id: id,
            origin: origin,
            destination: destination,
            originStationID: originStationID,
            destinationStationID: destinationStationID,
            strategy: strategy,
            segments: newSegments,
            totalDuration: newTotal,
            walkingDistance: walkingDistance,
            totalStops: totalStops,
            transferCount: transferCount,
            isFullyAccessible: isFullyAccessible,
            stepFreeAssessment: stepFreeAssessment,
            warnings: warnings,
            accessGuidance: accessGuidance,
            dataCoverage: dataCoverage,
            serviceStatus: serviceStatus,
            stationGuidance: stationGuidance,
            fare: fare,
            missedTrainTaxiYuan: missedTrainTaxiYuan
        )
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
        MapVisibleRegion(
            fitting: segments.flatMap(\.drawableCoordinates).map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
        )
    }
}

/// What a journey costs to ride, in yuan.
///
/// `RouteDetailView` used to carry a comment stating that a fare would never appear here, because
/// the only way to produce one would have been to infer it from a stop count. That reasoning still
/// holds and this is not that: the amount is read from a routing provider that priced the same two
/// gates, and it is discarded outright unless the boarding and alighting stations match the ones
/// this route uses. The standard did not move, the available evidence did.
struct RouteFare: Codable, Equatable {
    /// A bus journey between the same two points, costing less than the fare above.
    ///
    /// Just-Go plans rail and only rail. But a ¥2 flat bus fare against a ¥6 metro fare is a real
    /// choice for a rider counting money, and a route screen that knew about it and stayed quiet
    /// would be keeping a secret rather than keeping scope.
    struct BusAlternative: Codable, Equatable {
        let yuan: Double
        let duration: TimeInterval
    }

    let yuan: Double
    let cheaperBus: BusAlternative?

    var formatted: String { Self.formatted(yuan) }

    /// Whole yuan wherever the fare is whole, which is every mainland tariff checked. The decimal
    /// branch exists so a city that charges half-yuan is rendered rather than rounded into a
    /// number nobody is charged.
    static func formatted(_ yuan: Double) -> String {
        let rounded = (yuan * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "¥\(Int(rounded))"
            : "¥\(String(format: "%.1f", rounded))"
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
    let officialFacilityCount: Int

    static let unknown = RouteDataCoverage(
        stationCount: 0,
        officialAccessibilityCount: 0,
        officialScheduleCount: 0,
        officialFacilityCount: 0
    )

    var accessibilityConfidence: DataConfidence {
        confidence(available: officialAccessibilityCount)
    }

    var scheduleConfidence: DataConfidence {
        confidence(available: officialScheduleCount)
    }

    var hasOfficialCoreData: Bool {
        officialAccessibilityCount > 0 || officialScheduleCount > 0 || officialFacilityCount > 0
    }

    /// How many of the things a rider can actually act on are missing. Station layout used to be
    /// a third entry here, and `officialStationMapCount` is hardcoded to zero on purpose. Browser
    /// links are catalog coverage, not route evidence, so every route in every city was docked
    /// for it, permanently and unearnably. A score nobody can move is not a score.
    var unknownCoreCount: Int {
        guard stationCount > 0 else { return 2 }
        return [
            officialAccessibilityCount,
            officialScheduleCount
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

struct TransitLegContext: Codable, Equatable {
    let lineID: String
    let lineName: String
    let boardingStationID: String
    let alightingStationID: String
    let directionNextStationID: String?
    let directionNextStationName: String?
    let arrivalPreviousStationID: String?
    let arrivalPreviousStationName: String?
    let directionTerminalStationID: String?
    let directionTerminalStationName: String?
}

struct TransferContext: Codable, Equatable {
    let cityID: String
    let stationID: String
    let stationName: String
    let incoming: TransitLegContext
    let outgoing: TransitLegContext
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
    var transitContext: TransitLegContext? = nil
    var transferContext: TransferContext? = nil
    /// The line the rider was just riding, for `.transfer` segments only. `LineName` on a
    /// transfer segment is the *outgoing* line (correct for "Transfer to X" display text), so
    /// resolving a real indoor path needs this separate field for where they're coming from.
    /// Optional with a default so old persisted trips (`ActiveTripStore`) decode unchanged.
    var incomingLineName: String? = nil
    var incomingLineColorHex: String? = nil

    var formattedDuration: String {
        let minutes = Int(duration / 60)
        return AppLocalization.minutes(minutes)
    }

    /// Which pack this leg starts in: the same rule as `RouteStationStop.packCityID`, for the
    /// transfer sheet, which is handed a segment rather than a stop.
    var packCityID: String? {
        fromStationID.flatMap(MetroStationIdentifier.cityID(of:))
    }

    /// What this leg draws on a map, from the one rule every map uses.
    ///
    /// Three screens each carried their own copy of it. The trip map, the live-guidance map and
    /// `previewRegion`, which is how the trip map and the region it framed could disagree about
    /// where a route went. An in-station change has no shape and correctly draws nothing.
    var drawableCoordinates: [CodableCoordinate] {
        polylineCoordinates.count >= 2 ? polylineCoordinates : stationStops.compactMap(\.coordinate)
    }

    /// Which access mode this leg is, for callers that must rebuild it without changing it.
    /// A transit or transfer leg is not an access leg at all; walking is the honest default for
    /// them because it is what a rebuilt leg between two points on foot would be.
    var accessLegMode: AccessLegMode {
        switch type {
        case .cycling: return .cycling
        case .driving: return .driving
        case .walking, .subway, .transfer: return .walking
        }
    }

    /// The same leg, re-labelled for a different mode. Used only where a mode borrows another's
    /// geometry: cycling has no routing source of its own, so it rides the walking shape and
    /// keeps the walking steps, which is exactly what lets the stairs check still see them.
    func retyped(
        as type: SegmentType,
        duration: TimeInterval,
        accessibilityNotes: [String]
    ) -> RouteSegment {
        RouteSegment(
            id: id,
            type: type,
            lineName: lineName,
            lineColorHex: lineColorHex,
            fromStationName: fromStationName,
            toStationName: toStationName,
            fromStationID: fromStationID,
            toStationID: toStationID,
            duration: duration,
            distance: distance,
            stops: stops,
            stationStops: stationStops,
            polylineCoordinates: polylineCoordinates,
            walkingDirections: walkingDirections,
            accessibilityNotes: accessibilityNotes,
            transitContext: transitContext,
            transferContext: transferContext,
            incomingLineName: incomingLineName,
            incomingLineColorHex: incomingLineColorHex
        )
    }

    /// A transfer leg re-costed from a measured corridor length.
    ///
    /// Separate from `retyped` because the meaning is different: this does not change what the leg
    /// *is*, it replaces a modelled guess with an observed distance. The duration is derived here
    /// at the app's own 1.25 m/s rather than taken from whoever supplied the metres. See
    /// `TransferPace.init(distanceMetres:)` for why a provider's seconds are not a second source.
    func measuringTransfer(distance measuredDistance: Double) -> RouteSegment {
        RouteSegment(
            id: id,
            type: type,
            lineName: lineName,
            lineColorHex: lineColorHex,
            fromStationName: fromStationName,
            toStationName: toStationName,
            fromStationID: fromStationID,
            toStationID: toStationID,
            duration: measuredDistance / 1.25,
            distance: measuredDistance,
            stops: stops,
            stationStops: stationStops,
            polylineCoordinates: polylineCoordinates,
            walkingDirections: walkingDirections,
            accessibilityNotes: accessibilityNotes,
            transitContext: transitContext,
            transferContext: transferContext,
            incomingLineName: incomingLineName,
            incomingLineColorHex: incomingLineColorHex
        )
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

    /// The door named the way a rider would look for it on a sign.
    ///
    /// Surveyed entrances arrive as anything from a bare "D" to "五道口 B 出口" depending on the
    /// source, and "Walk to D" on its own names nothing findable. Shared so the detail screen and
    /// the navigator cannot label the same door two different ways.
    var displayName: String {
        guard !name.lowercased().contains("exit"), !name.contains("出口"), !name.contains("入口") else {
            return name
        }
        return AppLocalization.text(
            english: "Exit \(name)",
            simplified: "\(name) 出口",
            traditional: "\(name) 出口"
        )
    }

    /// The door to name, or nil when none was resolved. `.StationPOI` is the station itself, so
    /// there is no specific entrance and nothing honest to print.
    var namedDoor: String? {
        source == .stationPOI ? nil : displayName
    }
}

enum RouteAccessPointSource: String, Codable {
    case mapKit
    case localStationData
    case inferred
    case specificEntrance
    case stationPOI
}

struct RouteStationStop: Identifiable, Codable {
    let stationID: String
    let name: String
    let lineName: String?
    let lineColorHex: String?
    let coordinate: CodableCoordinate?
    let arrivalTimeText: String?
    let isTransfer: Bool
    var lineID: String? = nil

    var id: String {
        "\(stationID)-\(lineName ?? "station")-\(arrivalTimeText ?? "")"
    }

    /// Which pack this stop belongs to, read off its own identifier.
    ///
    /// A trip spans packs now, so `Route.networkCityID` is the *origin's* city and nothing more.
    /// Handing it to every stop meant a Dongguan station was asked of Guangzhou's pack, which does
    /// not fail: it finds nothing and reports "unavailable", the one wrong answer this app is
    /// built not to give.
    var packCityID: String? {
        MetroStationIdentifier.cityID(of: stationID)
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

/// The eight-point compass sector an entrance sits in, measured from its station.
///
/// OpenStreetMap surveys thousands of entrances as a position and nothing else. No name, no exit
/// letter, because the sign carries none or nobody recorded it. Those doors are still worth walking
/// to, so they ship with an empty name and are described by where they are. The direction is
/// derived from the surveyed coordinate, so it states a fact rather than inventing a sign.
enum StationAccessBearing: CaseIterable {
    case north, northeast, east, southeast, south, southwest, west, northwest

    /// Sectors are 45° wide and centred on their compass point, so due north spans 337.5°–22.5°.
    /// Returns `nil` for a door essentially on top of the station centre, where naming a direction
    /// would be noise rather than guidance.
    static func between(station: CodableCoordinate, point: CodableCoordinate) -> StationAccessBearing? {
        let meanLatitude = (station.latitude + point.latitude) / 2 * .pi / 180
        let northing = (point.latitude - station.latitude) * .pi / 180 * 6_371_000
        let easting = (point.longitude - station.longitude) * .pi / 180 * 6_371_000 * cos(meanLatitude)
        guard northing * northing + easting * easting > 100 else { return nil }

        var degrees = atan2(easting, northing) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return allCases[Int((degrees + 22.5) / 45) % allCases.count]
    }

    var entranceName: String {
        switch self {
        case .north:
            return AppLocalization.text(english: "North entrance", simplified: "北侧出入口", traditional: "北側出入口")
        case .northeast:
            return AppLocalization.text(english: "Northeast entrance", simplified: "东北侧出入口", traditional: "東北側出入口")
        case .east:
            return AppLocalization.text(english: "East entrance", simplified: "东侧出入口", traditional: "東側出入口")
        case .southeast:
            return AppLocalization.text(english: "Southeast entrance", simplified: "东南侧出入口", traditional: "東南側出入口")
        case .south:
            return AppLocalization.text(english: "South entrance", simplified: "南侧出入口", traditional: "南側出入口")
        case .southwest:
            return AppLocalization.text(english: "Southwest entrance", simplified: "西南侧出入口", traditional: "西南側出入口")
        case .west:
            return AppLocalization.text(english: "West entrance", simplified: "西侧出入口", traditional: "西側出入口")
        case .northwest:
            return AppLocalization.text(english: "Northwest entrance", simplified: "西北侧出入口", traditional: "西北側出入口")
        }
    }
}

/// One row in an entrance list: either a single named entrance, or every unlabeled entrance that
/// shares a compass direction, counted.
struct StationAccessPointGroup: Identifiable {
    let id: String
    let name: String
    let count: Int
    /// True when any entrance in the group is recorded as step-free.
    let isAccessible: Bool

    /// Entrances imported from OpenStreetMap are named by the letter on the sign. "C", "A1",
    /// because that is all the survey records. On a map pin that is exactly right, but a list of
    /// bare letters does not read as anything, so a row says "Exit C". Names that are already
    /// sentences ("民權西路站出口1") or directions ("West entrance") are left alone.
    var listName: String {
        guard !name.isEmpty,
              name.count <= 3,
              name.range(of: #"^[A-Za-z]?\d{0,2}[A-Za-z]?$"#, options: .regularExpression) != nil else {
            return name
        }
        return AppLocalization.text(
            english: "Exit \(name)",
            simplified: "\(name) 出入口",
            traditional: "\(name) 出入口"
        )
    }
}

extension Collection where Element == StationAccessPoint {
    /// How to list these entrances, wherever they are listed.
    ///
    /// Named entrances get a row each: the name is what a rider matches against the sign overhead.
    /// Unlabeled ones have no sign to match, so they are grouped by direction and counted: 玉泉路
    /// has four doors on its west side, and four rows all reading "West entrance" tells a rider
    /// strictly less than one row reading "West entrance ×4".
    func presentationGroups(relativeTo station: CodableCoordinate?) -> [StationAccessPointGroup] {
        var groups: [StationAccessPointGroup] = []
        var indexByName: [String: Int] = [:]

        for point in self {
            let name = point.displayName(relativeTo: station)
            guard point.isUnlabeled, let index = indexByName[name] else {
                if point.isUnlabeled { indexByName[name] = groups.count }
                groups.append(StationAccessPointGroup(
                    id: point.id,
                    name: name,
                    count: 1,
                    isAccessible: point.isAccessible
                ))
                continue
            }
            let existing = groups[index]
            groups[index] = StationAccessPointGroup(
                id: existing.id,
                name: existing.name,
                count: existing.count + 1,
                isAccessible: existing.isAccessible || point.isAccessible
            )
        }
        return groups
    }
}

extension StationAccessPoint {
    /// A surveyed door with no sign letter and no name of its own.
    var isUnlabeled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What to call this entrance out loud. Named entrances keep their name; unlabeled ones are
    /// described by their direction from the station, which is why the station's own position has
    /// to be passed in. Without one there is nothing to measure against, so it falls back to a
    /// plain "station entrance": never to the empty string the pack actually carries.
    func displayName(relativeTo station: CodableCoordinate?) -> String {
        guard isUnlabeled else { return name }
        guard let station, let coordinate,
              let bearing = StationAccessBearing.between(station: station, point: coordinate) else {
            return AppLocalization.text(english: "Station entrance", simplified: "车站出入口", traditional: "車站出入口")
        }
        return bearing.entranceName
    }

    /// The same point with its direction resolved into `name`, for the places downstream that only
    /// ever see the access point and no longer have the station to measure from. Route guidance,
    /// the trip timeline, the arrival notification.
    func labeled(relativeTo station: CodableCoordinate?) -> StationAccessPoint {
        guard isUnlabeled else { return self }
        return StationAccessPoint(
            id: id,
            name: displayName(relativeTo: station),
            kind: kind,
            coordinate: coordinate,
            isAccessible: isAccessible,
            notes: notes,
            source: source,
            confidence: confidence
        )
    }
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
    let confidence: DataConfidence

    var id: String { "\(stationID)-\(role.rawValue)" }
}

/// Render-ready comparison metrics for one route, computed across all alternatives.
/// What one route row actually renders. Held to exactly that: it previously also carried `rank`,
/// `transferText`, `walkingText`, `transferEffort` and `exitConfidence`, none of which any view
/// read: `summaryLine` had absorbed the last two and the row had stopped drawing the rest.
struct RouteComparisonMetrics: Identifiable {
    let id: UUID
    let durationText: String
    let bestForReason: String
    let arrivalText: String
    let summaryLine: String
}

/// Per-station access guidance returned by the city-pack service: best-available exits/entrances
/// and a confidence describing the data source.
///
/// It also used to carry platform hints ("board the third car") and interchange-corridor hints
/// ("2号线 → 8号线 · 约180米"). Both were authored-only fields that no pack has ever contained, and
/// `validate_indoor_maps.rb` exists to keep it that way, so every screen built on them rendered a
/// heading, an `unknown` confidence chip and nothing else.
struct StationAccessGuidance {
    let accessPoints: [StationAccessPoint]
    let confidence: DataConfidence

    static let empty = StationAccessGuidance(
        accessPoints: [],
        confidence: .unavailable
    )

    /// The entrance to send a rider to, given where they are walking to or from and whether they
    /// need step-free access.
    ///
    /// This replaced a `primaryAccessPoint` that returned `accessPoints.first`. Nothing about that
    /// was tied to the rider: the order is the pack's, which for OpenStreetMap entrances is node
    /// id. Exits at a large interchange sit several hundred metres and one busy road apart, so the
    /// arbitrary first exit routinely sent people out of the wrong side of the station. Deleted
    /// rather than deprecated: leaving it in place is an invitation to reintroduce the bug.
    /// The `limit` most promising entrances, nearest-in-a-straight-line first, plus whether the
    /// rider's step-free requirement went unmet.
    ///
    /// Straight-line order is a *shortlist*, not an answer. At 西直门 the nearest door by air is a
    /// 698 m walk because the railway runs between it and the street, while a slightly further one
    /// is a fraction of that. Callers that can afford to measure real walking distance re-rank these;
    /// callers that cannot take the first and are no worse off than before.
    func rankedAccessPoints(
        near target: CodableCoordinate?,
        requiresStepFree: Bool,
        limit: Int
    ) -> (points: [StationAccessPoint], stepFreeUnavailable: Bool) {
        let exits = accessPoints.filter { $0.kind == .exit }
        let candidates = exits.isEmpty ? accessPoints : exits
        guard !candidates.isEmpty else { return ([], false) }

        // Only OSM's `wheelchair=yes`/`designated` sets `isAccessible`, so an untagged entrance is
        // "nobody surveyed this", not "there are steps". When nothing here is tagged step-free the
        // rider still gets the nearest exit, with the shortfall reported rather than papered over.
        let stepFree = candidates.filter(\.isAccessible)
        let unavailable = requiresStepFree && stepFree.isEmpty
        let preferred = requiresStepFree && !stepFree.isEmpty ? stepFree : candidates

        guard let target else {
            return (Array(preferred.prefix(limit)), unavailable)
        }
        let ordered = preferred
            .compactMap { point -> (point: StationAccessPoint, metres: Double)? in
                guard let coordinate = point.coordinate else { return nil }
                return (point, target.metres(to: coordinate))
            }
            .sorted { $0.metres < $1.metres }
            .map(\.point)
        return (Array((ordered.isEmpty ? preferred : ordered).prefix(limit)), unavailable)
    }
}

struct CodableCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Flat-earth distance in metres. Exact enough at the scale this is used for. Comparing
    /// entrances of one station against one nearby destination, never more than a few kilometres.
    func metres(to other: CodableCoordinate) -> Double {
        let meanLatitude = (latitude + other.latitude) / 2 * .pi / 180
        let northing = (other.latitude - latitude) * .pi / 180 * 6_371_000
        let easting = (other.longitude - longitude) * .pi / 180 * 6_371_000 * cos(meanLatitude)
        return (northing * northing + easting * easting).squareRoot()
    }
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

enum SegmentType: String, Codable {
    case walking
    case cycling
    case driving
    case subway
    case transfer

    /// True for the segments a rider actually rides, as opposed to walking to/between them.
    var isTransit: Bool {
        self == .subway
    }

    /// The first and last mile: how the rider gets between their own doorstep and a station.
    /// A transfer is between two stations, so it is not one of these.
    var isAccessLeg: Bool {
        self == .walking || self == .cycling || self == .driving
    }

    /// Only walking counts as walking. A route summary that folded a 6 km drive into
    /// "walking distance" would be lying in the one number riders check hardest.
    var isOnFoot: Bool {
        self == .walking
    }

    /// The symbol for this leg, in one place.
    ///
    /// There were two copies of this and they disagreed: the journey chain drew `figure.walk` for
    /// everything that was not a ride, so a 9 km drive and a 6 km cycle both showed a walking
    /// figure. A leg's icon is the only thing distinguishing the three access modes at a glance.
    /// Getting it wrong there undoes the whole point of choosing between them.
    ///
    /// `.subway` is drawn as a `LineBadge` wherever a line is known; this is its fallback.
    var symbolName: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        case .transfer: return "arrow.triangle.swap"
        case .subway: return "tram.fill"
        }
    }
}

/// How a rider covers the first or last mile, chosen by how far it is.
///
/// One rule in one place, because the choice has to be identical wherever a leg is built or
/// rebuilt: the route assembler makes these legs and the exit chooser remakes them against a
/// specific door, and two copies of a distance ladder would disagree about which mode a leg is
/// the moment either was edited.
enum AccessLegMode {
    case walking
    case cycling
    case driving

    /// The icon for this mode, from the same table the segments use. One place, always.
    var symbolName: String {
        switch self {
        case .walking: return SegmentType.walking.symbolName
        case .cycling: return SegmentType.cycling.symbolName
        case .driving: return SegmentType.driving.symbolName
        }
    }

    /// Beyond a walk, a bike; beyond a bike, a car.
    ///
    /// The lower bound is the rider's own limit from Accessibility Settings rather than a constant
    ///. Someone who has said they will not walk more than 300 m has already answered this
    /// question, and asking them to walk 900 m to a station ignores the only thing they told us.
    /// The upper bound is fixed at 8 km: past that a bike stops being plausible as a leg of a
    /// metro trip, whatever the rider's walking limit is.
    static func forDistance(_ metres: Double, walkingLimit: Double) -> AccessLegMode {
        if metres <= max(walkingLimit, 0) { return .walking }
        if metres <= 8_000 { return .cycling }
        return .driving
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

    /// Every case here has a producer. `elevatorOutage`, `escalatorOutage`, `serviceDisruption`
    /// and `crowding` were removed because none did: nothing in the app has ever constructed them,
    /// and no source exists to. Live outage and crowding feeds are not available to this app, so
    /// keeping the cases meant carrying a UI branch that could only ever render a claim we had no
    /// data for. Add a case back when, and only when. Something can produce it.
    enum WarningType: String, Codable {
        case stepFreeAccessUnconfirmed
        case stairsDetected
        case longWalk
        case lastTrainSoon
        case serviceEnded
        case serviceNotStarted
        /// The rider is being told to board or alight somewhere that does not take passengers.
        case stationNotServingPassengers
    }
}
