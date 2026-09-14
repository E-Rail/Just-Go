import Foundation
import CoreLocation

struct AccessibilityFilter {
    var requiresWheelchairAccess: Bool
    var requiresElevator: Bool
    var avoidStairs: Bool
    /// How far the rider is willing to walk to reach a station, from Accessibility Settings: it
    /// decides whether the first mile is walked, cycled or driven. No default, so a caller that
    /// forgets it (a mid-trip reroute, say) does not compile rather than silently planning at
    /// someone else's limit.
    var maxWalkingDistance: Double

    static let none = AccessibilityFilter(
        requiresWheelchairAccess: false,
        requiresElevator: false,
        avoidStairs: false,
        maxWalkingDistance: AccessibilityPreference.default.maxWalkingDistance
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
    let strategy: RoutePreference
    // Mutable like `warnings` and `accessGuidance`: enrichment re-walks the first and last legs to
    // the chosen door, and the distance has to follow.
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
    /// What a taxi over the same ground costs at the hour this trip departs. Carried only when the
    /// last train is close or gone, when that cost decides whether the rider runs for the train.
    var missedTrainTaxiYuan: Double?

    /// The two ends of the whole journey on the ground: where the first drawn leg starts and the
    /// last one ends, which is the rider's doorstep or dropped pin rather than a station record.
    /// `nil` when nothing was drawn.
    var groundOrigin: CodableCoordinate? {
        segments.lazy.compactMap(\.drawableCoordinates.first).first
    }

    var groundDestination: CodableCoordinate? {
        segments.reversed().lazy.compactMap(\.drawableCoordinates.last).first
    }

    /// The stops this route calls at, as station pins for a route map.
    var mapStations: [Station] {
        stationTimelineStops.compactMap { stop in
            guard let coordinate = stop.coordinate else { return nil }
            return Station(
                stationID: stop.stationID,
                name: stop.name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                cityID: stop.packCityID ?? networkCityID ?? "",
                // Interchanges get the larger symbol and win label collisions against the stops
                // between them: on a route map they are where the rider has to act.
                isTransferStation: stop.isTransfer
            )
        }
    }

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

    /// A copy carrying none of the money an observation provider quoted.
    ///
    /// `fare` and `missedTrainTaxiYuan` are the only two values on a route that are verbatim
    /// provider content rather than something the app derived: both are prices Baidu computed and
    /// returned. Everything else enrichment touches — the service verdict, the warnings it words
    /// itself, the changes it re-costs at the app's own walking pace — is the app's own reading.
    ///
    /// `ActiveTripStore.save` is the reason this exists; see the note there.
    var withoutObservedPricing: Route {
        var stripped = self
        stripped.fare = nil
        stripped.missedTrainTaxiYuan = nil
        return stripped
    }
}

/// What a journey costs to ride, in yuan. Read from a routing provider that priced the same two
/// gates and discarded unless the boarding and alighting stations match this route's; never
/// inferred from a stop count.
struct RouteFare: Codable, Equatable {
    /// A cheaper bus between the same two points. Just-Go plans rail only, but a ¥2 bus against a
    /// ¥6 metro fare is a real choice for a rider counting money.
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

    /// How many of the things a rider can act on are missing. Station layout is not counted:
    /// browser links are catalog coverage, not route evidence.
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

struct TransitLegContext: Codable, Equatable {
    let lineID: String
    let lineName: String
    let boardingStationID: String
    let directionNextStationID: String?
    let directionNextStationName: String?
    let arrivalPreviousStationName: String?
    let directionTerminalStationName: String?
    /// Every station this train calls at from the boarding station to the end of its run, in
    /// travel order.
    ///
    /// It exists to attribute a first/last-train window to *this* rider. An operator publishes one
    /// window per service, and a service is named by where it terminates: 花园桥 on 6号线 eastbound
    /// has a full run to 潞阳 whose last train is 22:45 and a short-turn to 草房 whose last train is
    /// 23:56. Which of those two the rider can still use is decided entirely by whether their own
    /// alighting station is before or after 草房, so the answer needs the order of the stations
    /// ahead of them and nothing less.
    ///
    /// Optional, and `nil` rather than empty when the branch is ambiguous, for the same reason
    /// `directionTerminalStationName` is: guessing which arm of a branch the rider is on would put
    /// another branch's timetable against their trip.
    let onwardStationNames: [String]?
}

struct TransferContext: Codable, Equatable {
    let cityID: String
    let stationID: String
    let stationName: String
}

struct RouteSegment: Identifiable, Codable {
    // `var` where a copy below changes it; everything else about a leg is fixed once built.
    private(set) var id: UUID
    private(set) var type: SegmentType
    let lineName: String?
    let lineColorHex: String?
    private(set) var fromStationName: String?
    private(set) var toStationName: String?
    let fromStationID: String?
    let toStationID: String?
    private(set) var duration: TimeInterval
    private(set) var distance: Double
    let stops: Int
    let stationStops: [RouteStationStop]
    let polylineCoordinates: [CodableCoordinate]
    let walkingDirections: [WalkingStep]?
    private(set) var accessibilityNotes: [String]
    var transitContext: TransitLegContext? = nil
    var transferContext: TransferContext? = nil
    /// The line the rider was just riding, for `.transfer` segments only (`lineName` is the
    /// outgoing line). Optional with a default so trips saved in `ActiveTripStore` still decode.
    var incomingLineName: String? = nil
    /// The platform-to-platform walk a routing provider measured for this change, in metres.
    /// `distance` cannot stand in: every transfer has one, modelled or measured, and only this says
    /// which. Optional with a default so saved trips still decode.
    var measuredCorridorMetres: Int? = nil

    var formattedDuration: String {
        let minutes = Int(duration / 60)
        return AppLocalization.minutes(minutes)
    }

    /// Which pack this leg starts in: the same rule as `RouteStationStop.packCityID`, for the
    /// transfer sheet, which is handed a segment rather than a stop.
    var packCityID: String? {
        fromStationID.flatMap(MetroStationIdentifier.cityID(of:))
    }

    /// What this leg draws on a map: its polyline, or the line through its stops. The one rule
    /// every map and `previewRegion` use. An in-station change draws nothing.
    var drawableCoordinates: [CodableCoordinate] {
        polylineCoordinates.count >= 2 ? polylineCoordinates : stationStops.compactMap(\.coordinate)
    }

    var colorHex: String { type.colorHex(line: lineColorHex) }

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

    /// The same leg under different end names, with an identity of its own.
    ///
    /// A memoized leg is keyed on its two coordinates, so one answer can serve calls that name the
    /// ends differently ("Current Location" versus a dropped pin). The id is fresh because two
    /// routes in one results list would otherwise carry segments that compare equal.
    func relabelled(from newFromName: String?, to newToName: String?) -> RouteSegment {
        guard fromStationName != newFromName || toStationName != newToName else { return self }
        var copy = self
        copy.id = UUID()
        copy.fromStationName = newFromName
        copy.toStationName = newToName
        return copy
    }

    /// The same leg, re-labelled for a different mode. Used only where a mode borrows another's
    /// geometry: cycling has no routing source of its own, so it rides the walking shape and
    /// keeps the walking steps, which is exactly what lets the stairs check still see them.
    func retyped(
        as type: SegmentType,
        duration: TimeInterval,
        accessibilityNotes: [String]
    ) -> RouteSegment {
        var copy = self
        copy.type = type
        copy.duration = duration
        copy.accessibilityNotes = accessibilityNotes
        return copy
    }

    /// What a change costs beyond the walking, in seconds: platform to platform, the wait, the
    /// crowd at the gate.
    static let changeoverAllowance: TimeInterval = 300

    /// A transfer leg re-costed from a measured corridor length: a modelled guess replaced by an
    /// observed distance, walked at the app's own 1.25 m/s (see
    /// `TransferPace.init(distanceMetres:)` for why not the provider's seconds).
    ///
    /// The measurement replaces the walk, not the changeover allowance: every change, modelled or
    /// measured, carries the same fixed 300 s, or measured routes would claim to arrive minutes
    /// early.
    func measuringTransfer(distance measuredDistance: Double) -> RouteSegment {
        var copy = self
        copy.distance = measuredDistance
        copy.duration = measuredDistance / 1.25 + RouteSegment.changeoverAllowance
        copy.measuredCorridorMetres = Int(measuredDistance.rounded())
        return copy
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

/// One rule for naming a station door, shared by every type that holds one, so two screens cannot
/// label the same door differently.
protocol NamedStationDoor {
    var name: String { get }
    var source: RouteAccessPointSource { get }
}

extension NamedStationDoor {
    /// The door named the way a rider would look for it on a sign.
    ///
    /// Surveyed entrances arrive as anything from a bare "D" to "五道口 B 出口" depending on the
    /// source, and "Walk to D" on its own names nothing findable.
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

    /// The door to name, or nil when none was resolved. `.stationPOI` is the station itself, so
    /// there is no specific entrance and nothing honest to print.
    var namedDoor: String? {
        source == .stationPOI ? nil : displayName
    }
}

struct RouteAccessPoint: Identifiable, Codable, NamedStationDoor {
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

    /// Which pack this stop belongs to, read off its own identifier. A trip can span packs, so
    /// `Route.networkCityID` names only the origin's city, and asking the wrong pack finds nothing
    /// and reports "unavailable".
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
struct StationAccessPoint: Identifiable, Codable, NamedStationDoor {
    let id: String
    let name: String
    let kind: AccessPointKind
    let coordinate: CodableCoordinate?
    let isAccessible: Bool
    /// What the survey says, which `isAccessible` (asserted step-free, part of the published
    /// Universal City Data contract) cannot: a door recorded as not step-free and a door nobody
    /// looked at are both `false` there. Defaults to `.unknown` so older packs decode as silence
    /// rather than a claim.
    var stepFree: StepFreeClaim = .unknown
    let notes: [String]
    let source: RouteAccessPointSource
    let confidence: DataConfidence
}

/// Three states, because the sources have three. Never collapse this back to a Bool.
enum StepFreeClaim: String, Codable, Equatable, Sendable {
    /// Surveyed and step-free.
    case yes
    /// Surveyed and **not** step-free. A real finding, not an absence.
    case no
    /// Nobody has looked. The majority of every OSM-sourced pack, and never a negative claim.
    case unknown

    /// `yes` beats `no` beats `unknown` when two doors merge into one row: a station with one
    /// step-free entrance has step-free access, and a surveyed negative still outranks silence.
    static func merging(_ lhs: StepFreeClaim, _ rhs: StepFreeClaim) -> StepFreeClaim {
        if lhs == .yes || rhs == .yes { return .yes }
        if lhs == .no || rhs == .no { return .no }
        return .unknown
    }
}

/// The eight-point compass sector an entrance sits in, measured from its station. OpenStreetMap
/// surveys thousands of entrances with a position and no name; they are described by where they
/// are, which states a fact rather than inventing a sign.
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
    /// The strongest claim in the group: step-free if any door is, otherwise a surveyed negative
    /// if any door carries one, otherwise silence.
    var stepFree: StepFreeClaim = .unknown

    /// Entrances from OpenStreetMap are named by the letter on the sign ("C", "A1"). Right on a map
    /// pin, but a list row says "Exit C". Names that are already sentences ("民權西路站出口1") or
    /// directions are left alone.
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
                    isAccessible: point.isAccessible,
                    stepFree: point.stepFree
                ))
                continue
            }
            let existing = groups[index]
            groups[index] = StationAccessPointGroup(
                id: existing.id,
                name: existing.name,
                count: existing.count + 1,
                isAccessible: existing.isAccessible || point.isAccessible,
                stepFree: StepFreeClaim.merging(existing.stepFree, point.stepFree)
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

/// What one route row renders, computed across all alternatives.
struct RouteComparisonMetrics: Identifiable {
    let id: UUID
    let durationText: String
    let bestForReason: String
    let arrivalText: String
    let summaryLine: String
}

/// Per-station access guidance from the city-pack service: best-available exits and entrances, and
/// a confidence for the source.
struct StationAccessGuidance {
    let accessPoints: [StationAccessPoint]
    let confidence: DataConfidence

    static let empty = StationAccessGuidance(
        accessPoints: [],
        confidence: .unavailable
    )

    /// The `limit` most promising entrances, nearest in a straight line first, and whether the
    /// rider's step-free requirement went unmet. Never the pack's first entrance: that order is
    /// node ID, and at a large interchange the wrong door is several hundred metres and a road
    /// away.
    ///
    /// Straight-line order is a shortlist, not an answer: at 西直门 the nearest door by air is a 698 m
    /// walk because the railway is in the way. Callers that can measure real walking distance
    /// re-rank these.
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

    /// The symbol for this leg, in one place: it is the only thing telling the three access modes
    /// apart at a glance. `.subway` is drawn as a `LineBadge` wherever a line is known; this is its
    /// fallback.
    var symbolName: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        case .transfer: return "arrow.triangle.swap"
        case .subway: return "tram.fill"
        }
    }

    /// The colour this leg is drawn in wherever it is drawn: the result card, the trip rail,
    /// guidance and both maps. A ride takes its line's colour, and grey when the line has none.
    ///
    /// A walk and a change share one grey, since both are the rider moving themselves. A drive is
    /// not grey: solid grey at map width reads as one of the roads underneath it.
    func colorHex(line lineColorHex: String?) -> String {
        switch self {
        case .walking, .transfer: return "#8E8E93"
        case .cycling: return "#34C759"
        case .driving: return "#5856D6"
        case .subway: return lineColorHex ?? "#8E8E93"
        }
    }

    /// The dash for a round-capped stroke `width` wide, in the same proportions on every surface.
    /// Empty is solid: round dots on foot, a long dash by bike, a short one for a change, and solid
    /// for anything that carries the rider.
    func dash(width: CGFloat) -> [CGFloat] {
        let unit = width / 7
        switch self {
        case .walking: return [0.1, 11 * unit]
        case .cycling: return [7 * unit, 6 * unit]
        case .transfer: return [2 * unit, 6 * unit]
        case .driving, .subway: return []
        }
    }
}

/// How a rider covers the first or last mile, chosen by distance. One rule, because the route
/// assembler builds these legs and the exit chooser rebuilds them, and two distance ladders would
/// disagree.
enum AccessLegMode {
    case walking
    case cycling
    case driving

    var segmentType: SegmentType {
        switch self {
        case .walking: return .walking
        case .cycling: return .cycling
        case .driving: return .driving
        }
    }

    var symbolName: String { segmentType.symbolName }

    /// Beyond a walk, a bike; beyond a bike, a car. The lower bound is the rider's own walking
    /// limit from Accessibility Settings. The upper bound is 8 km, past which a bike is not a
    /// plausible leg of a metro trip.
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

    /// Every case has a producer. There are no outage or crowding cases because no feed for them
    /// exists; add a case only with something that produces it.
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
