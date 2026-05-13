import Foundation
import CoreLocation

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
    let accessibilityScore: Double
    let isFullyAccessible: Bool
    let warnings: [RouteWarning]
    let accessGuidance: [RouteAccessGuide]

    var formattedDuration: String {
        let minutes = Int(totalDuration / 60)
        return AppLocalization.minutes(minutes)
    }

    var formattedStops: String {
        AppLocalization.stops(totalStops)
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

enum RouteStrategy: String, Codable, CaseIterable {
    case metroFirst
    case fastest
    case leastWalking

    var amapV5StrategyValue: String {
        switch self {
        case .metroFirst:
            return "7"
        case .fastest:
            return "8"
        case .leastWalking:
            return "3"
        }
    }

    var amapV3StrategyValue: String {
        switch self {
        case .metroFirst:
            return "2"
        case .fastest:
            return "0"
        case .leastWalking:
            return "3"
        }
    }

    var localizedName: String {
        switch self {
        case .metroFirst:
            return AppLocalization.localized("Metro First")
        case .fastest:
            return AppLocalization.localized("Fastest")
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
        "\(AppLocalization.distance(walkingDistance)) • \(AppLocalization.minutes(Int(walkingDuration / 60)))"
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
    case amap
    case localStationData
    case inferred
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
    let uid: String?
    let cityCode: String?
    let adCode: String?
    let naviPOIID: String?
    let entranceCoordinate: CodableCoordinate?
    let address: String?

    var id: String {
        kind.id
    }

    var transitPlace: TransitPlace {
        TransitPlace(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
            uid: uid,
            type: kind.title,
            typeCode: nil,
            address: address,
            cityCode: cityCode,
            adCode: adCode,
            naviPOIID: naviPOIID,
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
        uid = place.uid
        cityCode = place.cityCode
        adCode = place.adCode
        naviPOIID = place.naviPOIID
        entranceCoordinate = place.entranceCoordinate.map {
            CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        address = place.address
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

    var hasOverpass: Bool {
        walkType == "18" || combinedText.contains("天桥") || combinedText.localizedCaseInsensitiveContains("overpass")
    }

    var hasUnderpass: Bool {
        walkType == "19" || combinedText.contains("地下通道") || combinedText.localizedCaseInsensitiveContains("underpass")
    }

    var hasBarrierRisk: Bool {
        hasStairs || hasOverpass || hasUnderpass
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
    }
}
