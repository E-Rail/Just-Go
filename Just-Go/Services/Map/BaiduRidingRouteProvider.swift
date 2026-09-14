import CoreLocation
import Foundation

/// What the rider rides for the first or last mile. E-bikes route differently enough to matter: on
/// one measured pair a bicycle took 9,094 m and 53 minutes where an e-bike took 8,289 m and 31.
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

    /// The rider's choice from Settings, read here because nothing between the setting and the
    /// request has an opinion about it.
    static var preferred: AccessBicycle {
        UserDefaults.standard.bool(forKey: storageKey) ? .electric : .bicycle
    }

    static let storageKey = "usesElectricBike"
}

/// A cycling leg from a router that has one. MapKit has no cycling transport type, and a re-timed
/// walking route is a different journey: on one measured pair the walk ran 5,224 m and the ride
/// 9,094 m, because a bike cannot use footbridges, underpasses and pedestrian cut-throughs.
actor BaiduRidingRouteProvider {
    private let client: BaiduMapsClient
    /// Session-scoped and in memory only, for the licensing reason in
    /// `BaiduTripObservationService`. Capped, newest use last: Live Go re-plans from wherever the
    /// rider stands, adding an entry each time.
    private var cache: [String: RidingRoute] = [:]
    private var cacheOrder: [String] = []
    private static let maximumCachedRoutes = 32

    init(client: BaiduMapsClient) {
        self.client = client
    }

    func releaseMemory() {
        cache.removeAll()
        cacheOrder.removeAll()
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
                    // 不走逆行和楼梯: avoid contraflow and stairs. A route down a staircase is not a bike
                    // route.
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
        cacheOrder.removeAll { $0 == cacheKey }
        cacheOrder.append(cacheKey)
        while cacheOrder.count > Self.maximumCachedRoutes {
            let evicted = cacheOrder.removeFirst()
            cache[evicted] = nil
        }
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

/// One answer per leg, shared by every caller: the graph's walks to the station for each candidate
/// path, enrichment's walk to the chosen door, and every re-plan. Alternatives mostly share their
/// first and last stations, and Apple throttles directions per minute, degrading a throttled leg to
/// "Walking distance is estimated".
///
/// Ten minutes, because a route between two fixed points does not change faster; bounded, so a day
/// of planning cannot grow it without limit.
actor MemoizingAccessRouteProvider: WalkingRouteProviding {
    private struct Entry {
        let segment: RouteSegment?
        let at: ContinuousClock.Instant
    }

    private let provider: WalkingRouteProviding
    private let lifetime: Duration
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<RouteSegment?, Never>] = [:]

    init(provider: WalkingRouteProviding, lifetime: Duration = .seconds(600), capacity: Int = 128) {
        self.provider = provider
        self.lifetime = lifetime
        self.capacity = capacity
    }

    func walkingSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String
    ) async -> RouteSegment? {
        await memoized(from: from, to: to, fromName: fromName, toName: toName, mode: .walking) { provider in
            await provider.walkingSegment(from: from, to: to, fromName: fromName, toName: toName)
        }
    }

    func accessSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String,
        mode: AccessLegMode
    ) async -> RouteSegment? {
        await memoized(from: from, to: to, fromName: fromName, toName: toName, mode: mode) { provider in
            await provider.accessSegment(from: from, to: to, fromName: fromName, toName: toName, mode: mode)
        }
    }

    func releaseMemory() {
        entries.removeAll()
        order.removeAll()
    }

    private func memoized(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        fromName: String,
        toName: String,
        mode: AccessLegMode,
        fetch: @escaping @Sendable (WalkingRouteProviding) async -> RouteSegment?
    ) async -> RouteSegment? {
        // ~1 m precision: finer than real coordinates differ, coarser than float noise. The mode
        // belongs in the key; the names do not, so a cached leg is relabelled for whoever asked.
        let key = String(
            format: "%.5f,%.5f>%.5f,%.5f|%@",
            from.latitude, from.longitude, to.latitude, to.longitude,
            String(describing: mode)
        )
        if let entry = entries[key], entry.at.duration(to: .now) < lifetime {
            return entry.segment?.relabelled(from: fromName, to: toName)
        }
        if let existing = inFlight[key] {
            return await existing.value?.relabelled(from: fromName, to: toName)
        }
        let provider = provider
        let task = Task { await fetch(provider) }
        inFlight[key] = task
        let segment = await task.value
        inFlight[key] = nil
        store(segment, for: key)
        return segment
    }

    private func store(_ segment: RouteSegment?, for key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(segment: segment, at: .now)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }
}

/// Routes access legs with the best source for each mode: MapKit for walking and driving, Baidu for
/// cycling where a key exists, MapKit's re-timed walking leg where it does not.
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
            // The router declined: a leg that exists beats a missing mode, and the fallback labels
            // itself as the walking shape.
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
            // instructions on a bike leg; `road_prefer=3` already avoids staircases.
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
