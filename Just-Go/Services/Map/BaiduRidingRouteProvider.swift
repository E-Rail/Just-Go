import CoreLocation
import Foundation

/// What the rider is actually riding for the first or last mile.
///
/// The electric bike is here because it is what a great many people in Chinese cities ride to the
/// station, and it routes differently enough to matter: on one measured pair a bicycle took 9,094 m
/// and 53 minutes where an e-bike took 8,289 m and 31 minutes.
enum AccessBicycle: String, Codable, CaseIterable, Sendable {
    case bicycle
    case electric

    /// Baidu's `riding_type`: 0 普通自行车, 1 电动车.
    var ridingType: String {
        switch self {
        case .bicycle: return "0"
        case .electric: return "1"
        }
    }

    /// The rider's own choice, from Settings. Read here rather than passed down through six call
    /// sites because nothing between the setting and the request has an opinion about it.
    static var preferred: AccessBicycle {
        UserDefaults.standard.bool(forKey: storageKey) ? .electric : .bicycle
    }

    static let storageKey = "usesElectricBike"
}

/// A cycling leg from a router that actually has one.
///
/// `MKDirectionsTransportType` offers `.automobile`, `.walking`, `.transit` and `.any`, with no
/// cycling type at all, so until now a bike leg was the pedestrian route re-timed and said so. That
/// was honest but wrong by a lot. On one measured pair the walking route ran 5,224 m while the
/// cycling route ran 9,094 m, because a bike cannot use the footbridges, underpasses and pedestrian
/// cut-throughs that make the walk short. The re-timed leg was not an imprecise version of the bike
/// journey, it was a different journey.
actor BaiduRidingRouteProvider {
    private let client: BaiduMapsClient
    /// Session-scoped, in memory only, for the same licensing reason as every other Baidu result
    /// in this app. See `BaiduTripObservationService` for the full note.
    private var cache: [String: RidingRoute] = [:]

    init(client: BaiduMapsClient) {
        self.client = client
    }

    struct RidingRoute: Sendable, Equatable {
        let distance: Double
        let duration: TimeInterval
        let coordinates: [CodableCoordinate]
        /// Roads on this route that bikes may not use, as the router reports them.
        let restriction: String?
    }

    func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        vehicle: AccessBicycle
    ) async -> RidingRoute? {
        let cacheKey = String(
            format: "%@:%.5f,%.5f>%.5f,%.5f",
            vehicle.rawValue,
            origin.latitude, origin.longitude, destination.latitude, destination.longitude
        )
        if let cached = cache[cacheKey] { return cached }

        let response: BaiduRidingResponse
        do {
            response = try await client.get(
                BaiduRidingResponse.self,
                path: "/direction/v2/riding",
                parameters: [
                    (name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
                    (name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
                    (name: "riding_type", value: vehicle.ridingType),
                    // 不走逆行和楼梯. A route down a staircase is not a route a bike can take, and
                    // asking the router to avoid them beats detecting them afterwards.
                    (name: "road_prefer", value: "3"),
                    (name: "coord_type", value: "gcj02"),
                    (name: "ret_coordtype", value: "gcj02")
                ]
            )
        } catch {
            AppLog.routing.info("Baidu riding route unavailable: \(error)")
            return nil
        }

        guard let route = response.result?.routes?.first,
              let distance = route.distance, distance > 0,
              let duration = route.duration, duration > 0 else { return nil }

        let coordinates = (route.steps ?? []).flatMap { step in
            Self.coordinates(fromPath: step.path)
        }
        let restriction = route.restrictionsInfo?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = RidingRoute(
            distance: Double(distance),
            duration: TimeInterval(duration),
            coordinates: coordinates,
            restriction: (restriction?.isEmpty ?? true) ? nil : restriction
        )
        cache[cacheKey] = result
        return result
    }

    /// Steps carry their shape as `lng,lat;lng,lat;…`. Longitude comes first here, the opposite of
    /// the `origin`/`destination` parameters on the same endpoint.
    static func coordinates(fromPath path: String?) -> [CodableCoordinate] {
        guard let path, !path.isEmpty else { return [] }
        return path.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: ",")
            guard parts.count >= 2,
                  let longitude = Double(parts[0]),
                  let latitude = Double(parts[1]) else { return nil }
            return CodableCoordinate(latitude: latitude, longitude: longitude)
        }
    }
}

/// Routes the access legs, using the best source available for each mode.
///
/// Walking and driving stay with MapKit, which routes both properly. Cycling goes to Baidu where a
/// key exists, and falls back to MapKit's re-timed walking leg where it does not, so an app with no
/// key behaves exactly as it did before this existed.
final class CompositeAccessRouteProvider: WalkingRouteProviding {
    private let mapKit: MapKitWalkingRouteProvider
    private let riding: BaiduRidingRouteProvider?
    private let vehicle: @Sendable () -> AccessBicycle

    init(
        mapKit: MapKitWalkingRouteProvider = MapKitWalkingRouteProvider(),
        riding: BaiduRidingRouteProvider?,
        vehicle: @escaping @Sendable () -> AccessBicycle = { AccessBicycle.preferred }
    ) {
        self.mapKit = mapKit
        self.riding = riding
        self.vehicle = vehicle
    }

    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        await mapKit.walkingSegment(from: from, to: to, fromName: fromName, toName: toName)
    }

    func accessSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String,
        mode: AccessLegMode
    ) async -> RouteSegment? {
        guard mode == .cycling, let riding else {
            return await mapKit.accessSegment(
                from: from, to: to, fromName: fromName, toName: toName, mode: mode
            )
        }
        let chosen = vehicle()
        guard let route = await riding.route(from: from, to: to, vehicle: chosen) else {
            // The router declined. A leg that exists beats a mode that is missing, and the MapKit
            // fallback still labels itself as the walking shape.
            return await mapKit.accessSegment(
                from: from, to: to, fromName: fromName, toName: toName, mode: mode
            )
        }
        return Self.segment(for: route, from: fromName, to: toName, vehicle: chosen)
    }

    static func segment(
        for route: BaiduRidingRouteProvider.RidingRoute,
        from fromName: String,
        to toName: String,
        vehicle: AccessBicycle
    ) -> RouteSegment {
        var notes: [String] = []
        if let restriction = route.restriction {
            notes.append(restriction)
        }
        if vehicle == .electric {
            notes.append(AppLocalization.text(
                english: "Timed for an electric bike.",
                simplified: "按电动车速度计算。",
                traditional: "按電動車速度計算。"
            ))
        }
        return RouteSegment(
            id: UUID(),
            type: .cycling,
            lineName: nil,
            lineColorHex: nil,
            fromStationName: fromName,
            toStationName: toName,
            fromStationID: nil,
            toStationID: nil,
            duration: route.duration,
            distance: route.distance,
            stops: 0,
            stationStops: [],
            polylineCoordinates: route.coordinates,
            // A cycling route has no pedestrian steps, and inventing some would put walking
            // instructions on a bike leg. The stairs check that read them is no longer needed
            // either: `road_prefer=3` asks the router to avoid staircases in the first place.
            walkingDirections: nil,
            accessibilityNotes: notes
        )
    }
}

// MARK: - Wire responses

struct BaiduRidingResponse: BaiduResponseEnvelope {
    let status: Int
    let message: String?
    let result: Result?

    struct Result: Decodable, Sendable {
        let routes: [Route]?
    }

    struct Route: Decodable, Sendable {
        let distance: Int?
        let duration: Int?
        let steps: [Step]?
        let restrictionsInfo: String?

        enum CodingKeys: String, CodingKey {
            case distance, duration, steps
            case restrictionsInfo = "restrictions_info"
        }
    }

    struct Step: Decodable, Sendable {
        let path: String?
    }
}
