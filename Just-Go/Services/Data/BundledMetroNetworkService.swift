import CoreLocation
import Foundation

struct MetroCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct MetroBounds: Codable, Equatable {
    let minLatitude: Double
    let minLongitude: Double
    let maxLatitude: Double
    let maxLongitude: Double

    func intersects(_ region: MapVisibleRegion) -> Bool {
        let halfLatitude = region.latitudeDelta / 2
        let halfLongitude = region.longitudeDelta / 2
        return minLatitude <= region.center.latitude + halfLatitude &&
            maxLatitude >= region.center.latitude - halfLatitude &&
            minLongitude <= region.center.longitude + halfLongitude &&
            maxLongitude >= region.center.longitude - halfLongitude
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let nearest = CLLocationCoordinate2D(
            latitude: min(max(coordinate.latitude, minLatitude), maxLatitude),
            longitude: min(max(coordinate.longitude, minLongitude), maxLongitude)
        )
        return coordinate.distance(to: nearest)
    }
}

struct MetroLine: Codable, Equatable, Identifiable {
    let id: String
    let logicalLineID: String?
    let routeReference: String?
    let name: String
    let nameEn: String?
    let colorHex: String
    let stationIDs: [String]
    let servicePatterns: [[String]]
    /// Express and short-turn trains on this line, if the operator runs any. Shown, never routed
    /// on: a variant skips stops the line serves, so in the graph it would be a non-stop edge
    /// Dijkstra always takes, and no OpenStreetMap relation says when these trains run. Separate
    /// from `servicePatterns`, the only thing the graph reads, and optional so older packs decode.
    let serviceVariants: [MetroServiceVariant]?
    let paths: [[MetroCoordinate]]
    /// `premium` where the line charges its own tariff above the metro's (機場快綫, 首都机场线,
    /// 磁浮线). Declared in the importer where checked; nil is the network's ordinary fare.
    let fare: Fare?

    enum Fare: String, Codable {
        case premium
    }
}

/// One kind of train on a line that is not the ordinary all-stops service.
struct MetroServiceVariant: Codable, Equatable, Identifiable {
    /// The operator's own word for it: 大站车 / 大站快车 / 直达车 / 直达快车 / 快车 / 区间车.
    let kind: String
    let name: String
    let sourceRelationID: String
    let stationIDs: [String]

    var id: String { sourceRelationID }
}

/// Two named stations riders treat as one interchange. The graph charges a transfer only where
/// lines meet at one node, so without this 广安门内 ↔ 牛街 could not be planned. Declared per pair in the
/// importer, never inferred from distance: 南礼士路 and 复兴门 are 372 m apart and are not an interchange,
/// 太平桥 and 复兴门 at 625 m are.
///
/// The same station at both ends is one name whose lines meet through the street (大钟寺 12/13): not
/// an edge, but the walk every change of line there makes.
struct MetroInterchange: Codable, Equatable {
    /// What the walk is: `inStation`, connected inside the building (Guangzhou's metro/intercity
    /// concourses); `outOfStation`, out to the street (Beijing's 广安门内/牛街).
    enum Kind: String, Codable {
        case inStation
        case outOfStation
    }

    /// What the fare does, where it has been checked. Separate from `kind` because it does not
    /// follow from the walk: Beijing bills 广安门内 → 牛街 as one trip across 496 m of street (虚拟换乘),
    /// while Guangzhou's metro and intercity halves share a concourse and need two tickets. nil is
    /// unknown, said as unknown.
    enum Fare: String, Codable {
        /// Tap out, walk, tap in: the two halves bill as a single trip.
        case continuous
    }

    let fromStationID: String
    let toStationID: String
    let kind: Kind
    let walkingDistanceMeters: Double
    let fare: Fare?
}

struct MetroStation: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let nameEn: String?
    let latitude: Double
    let longitude: Double
    let lineIDs: [String]
    /// The city the station is in, from OpenStreetMap's boundaries rather than the pack: Guangzhou's
    /// pack carries 广佛线 into Foshan. Optional so packs from before the field decode.
    let city: String?
    let cityEn: String?

    var localizedCity: String? {
        AppLocalization.isChinese ? city.map(AppLocalization.chinese) : cityEn ?? city
    }
}

/// Just enough of a network file to match a coordinate to a city by bounds, without allocating
/// every other city's stations, lines and polylines.
struct MetroNetworkSummary: Decodable {
    let cityID: String
    let bounds: MetroBounds
    let geometryKind: String
}

/// A network file's stations and lines, without `lines[].paths`. The polylines are 69% of the
/// bundled bytes and exist only to be drawn, so leaving them out makes one nationwide station list
/// affordable: 53 packs, 6,711 stations, ranked by distance.
struct MetroNetworkStationIndex: Decodable {
    struct Line: Decodable {
        let id: String
        let name: String
        let nameEn: String?
        let colorHex: String
    }

    let cityID: String
    let geometryKind: String
    let bounds: MetroBounds
    let lines: [Line]
    let stations: [MetroStation]
    let interchanges: [MetroInterchange]

    var displayStations: [Station] {
        let linesByID = Dictionary(
            lines.map { ($0.id, SubwayLine(lineID: $0.id, name: $0.name, nameEn: $0.nameEn, colorHex: $0.colorHex, cityID: cityID)) },
            uniquingKeysWith: { first, _ in first }
        )
        return stations.map { makeDisplayStation($0, cityID: cityID, linesByID: linesByID) }
    }
}

/// The one place a `MetroStation` becomes a `Station`, shared by the full network and the
/// station-only index so the map and search cannot disagree about a station's ID or lines.
private func makeDisplayStation(
    _ item: MetroStation,
    cityID: String,
    linesByID: [String: SubwayLine]
) -> Station {
    let displayLines = item.lineIDs.compactMap { linesByID[$0] }
    let station = Station(
        stationID: MetroStationIdentifier.qualified(cityID: cityID, stationID: item.id),
        name: item.name,
        nameEn: item.nameEn,
        latitude: item.latitude,
        longitude: item.longitude,
        cityID: cityID,
        isTransferStation: Set(displayLines.map(\.lineID)).count > 1
    )
    station.lines = displayLines
    station.city = item.localizedCity
    return station
}

struct MetroNetwork: Codable, Equatable, Identifiable {
    let cityID: String
    let version: String
    let bounds: MetroBounds
    let geometryKind: String
    let lines: [MetroLine]
    let stations: [MetroStation]
    let interchanges: [MetroInterchange]

    var id: String { cityID }

    var displayStations: [Station] {
        let linesByID = displayLinesByID
        return stations.map { displayStation($0, linesByID: linesByID) }
    }

    func matchingStation(named name: String, near coordinate: CLLocationCoordinate2D) -> MetroStation? {
        let key = normalizedStationName(name)
        let candidates = Self.normalizedIndex(for: self)[key] ?? []
        return candidates.min {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude).distance(to: coordinate) <
                CLLocationCoordinate2D(latitude: $1.latitude, longitude: $1.longitude).distance(to: coordinate)
        }
    }

    func displayStation(_ item: MetroStation) -> Station {
        displayStation(item, linesByID: displayLinesByID)
    }

    private var displayLinesByID: [String: SubwayLine] {
        // Tolerate a duplicated line id in a data pack (keep the first) instead of trapping.
        Dictionary(
            lines.map { line in
                (
                    line.id,
                    SubwayLine(
                        lineID: line.id,
                        name: line.name,
                        nameEn: line.nameEn,
                        colorHex: line.colorHex,
                        cityID: cityID
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func displayStation(_ item: MetroStation, linesByID: [String: SubwayLine]) -> Station {
        makeDisplayStation(item, cityID: cityID, linesByID: linesByID)
    }

    // Normalized name → stations, built once per (city, version) and cached, so `matchingStation`
    // does not re-normalize every name on every call. `NSCache` is thread-safe.
    private static let normalizedIndexCache: NSCache<NSString, NormalizedStationIndexBox> = {
        let cache = NSCache<NSString, NormalizedStationIndexBox>()
        cache.countLimit = 16
        return cache
    }()

    static func clearNormalizedIndexCache() {
        normalizedIndexCache.removeAllObjects()
    }

    private static func normalizedIndex(for network: MetroNetwork) -> [String: [MetroStation]] {
        let key = "\(network.cityID):\(network.version)" as NSString
        if let cached = normalizedIndexCache.object(forKey: key) {
            return cached.value
        }
        var index: [String: [MetroStation]] = [:]
        for station in network.stations {
            let primary = normalizedStationName(station.name)
            index[primary, default: []].append(station)
            if let nameEn = station.nameEn, !nameEn.isEmpty {
                let secondary = normalizedStationName(nameEn)
                if secondary != primary {
                    index[secondary, default: []].append(station)
                }
            }
        }
        normalizedIndexCache.setObject(NormalizedStationIndexBox(index), forKey: key)
        return index
    }
}

private final class NormalizedStationIndexBox {
    let value: [String: [MetroStation]]
    init(_ value: [String: [MetroStation]]) { self.value = value }
}

protocol MetroNetworkProviding: Sendable {
    func network(for cityID: String) async -> MetroNetwork?
    func networkSummaries() async -> [MetroNetworkSummary]
    func stations(in cityID: String) async -> [Station]
    /// Every bundled station, everywhere. Search ranks these by distance from the rider.
    func allStations() async -> [Station]
}

extension MetroNetworkProviding {
    func stations(in cityID: String) async -> [Station] {
        await network(for: cityID)?.displayStations ?? []
    }

    func networkSummaries() async -> [MetroNetworkSummary] {
        []
    }

    func allStations() async -> [Station] {
        []
    }
}

actor BundledMetroNetworkService: MetroNetworkProviding {
    /// Every network the bundle carries, read off the `MetroNetworks` folder, so adding a city is a
    /// data change.
    private static let supportedCityIDs = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "MetroNetworks") ?? [])
        .map { $0.deletingPathExtension().lastPathComponent }
    private var networks: [String: MetroNetwork] = [:]
    private var stationsByCity: [String: [Station]] = [:]
    private var summaries: [String: MetroNetworkSummary] = [:]
    private var missingCityIDs: Set<String> = []
    private var allStationsCache: [Station]?
    /// Decodes already running, by city. An actor suspends at every `await`, so callers that miss
    /// the cache together (at launch: the map, the station index and quick-tag repair) would each
    /// parse the same files.
    private var inFlightNetworks: [String: Task<MetroNetwork?, Never>] = [:]

    func network(for cityID: String) async -> MetroNetwork? {
        if let network = networks[cityID] {
            return network
        }
        guard !missingCityIDs.contains(cityID) else { return nil }
        if let existing = inFlightNetworks[cityID] { return await existing.value }
        let task = Task { await decodeNetwork(for: cityID) }
        inFlightNetworks[cityID] = task
        let network = await task.value
        inFlightNetworks[cityID] = nil
        return network
    }

    private func decodeNetwork(for cityID: String) async -> MetroNetwork? {
        guard let url = bundledNetworkURL(for: cityID) else {
            missingCityIDs.insert(cityID)
            return nil
        }
        do {
            // Decoded off the actor's thread, so the file read and parse do not pin the actor and
            // several cities load in parallel.
            let network = try await Self.decode(MetroNetwork.self, at: url)
            guard network.cityID == cityID, network.geometryKind == "physicalTrack" else {
                AppLog.data.error("Bundled metro network \(cityID, privacy: .public) failed validation (cityID or geometryKind mismatch)")
                missingCityIDs.insert(cityID)
                return nil
            }
            networks[cityID] = network
            summaries[cityID] = MetroNetworkSummary(
                cityID: network.cityID,
                bounds: network.bounds,
                geometryKind: network.geometryKind
            )
            return network
        } catch {
            AppLog.data.error("Failed to load bundled metro network \(cityID, privacy: .public): \(error)")
            missingCityIDs.insert(cityID)
            return nil
        }
    }

    func stations(in cityID: String) async -> [Station] {
        if let stations = stationsByCity[cityID] {
            return stations
        }
        guard let network = await network(for: cityID) else { return [] }
        let stations = network.displayStations
        stationsByCity[cityID] = stations
        return stations
    }

    /// Every bundled station, built once and kept, from the station-only projection of each pack. A
    /// city already fully loaded contributes its cached `Station` objects instead.
    func allStations() async -> [Station] {
        if let allStationsCache { return allStationsCache }
        var stations: [Station] = []
        var pendingURLs: [(cityID: String, url: URL)] = []
        for cityID in Self.supportedCityIDs {
            if let cached = stationsByCity[cityID] {
                stations += cached
            } else if !missingCityIDs.contains(cityID), let url = bundledNetworkURL(for: cityID) {
                pendingURLs.append((cityID, url))
            }
        }

        // Only the decode fans out. `Station` is a reference type and not Sendable, so the objects
        // are built here on the actor from the value-typed indexes the group returns.
        let indexes = await withTaskGroup(of: MetroNetworkStationIndex?.self) { group in
            for pending in pendingURLs {
                group.addTask { try? await Self.decode(MetroNetworkStationIndex.self, at: pending.url) }
            }
            var decoded: [MetroNetworkStationIndex] = []
            for await index in group {
                if let index { decoded.append(index) }
            }
            return decoded
        }

        for index in indexes where index.geometryKind == "physicalTrack" {
            let cityStations = index.displayStations
            stationsByCity[index.cityID] = cityStations
            stations += cityStations
            // The file is open and its bounds decoded: record them, so "which packs are in view"
            // needs no second pass.
            summaries[index.cityID] = MetroNetworkSummary(
                cityID: index.cityID,
                bounds: index.bounds,
                geometryKind: index.geometryKind
            )
        }
        // Sorted so the list is stable across launches whichever decode finished first; the caller
        // applies the ranking.
        stations.sort { $0.stationID < $1.stationID }
        allStationsCache = stations
        return stations
    }

    /// Bounds only, for every city: enough to find the matching network without decoding and
    /// caching all 53 full networks.
    func networkSummaries() async -> [MetroNetworkSummary] {
        await fanOut { await self.networkSummary(for: $0) }
    }

    /// Fans `work` out over every supported city concurrently and collects the non-nil results.
    private func fanOut<T: Sendable>(_ work: @escaping (String) async -> T?) async -> [T] {
        await withTaskGroup(of: T?.self) { group in
            for cityID in Self.supportedCityIDs {
                group.addTask { await work(cityID) }
            }
            var result: [T] = []
            for await item in group {
                if let item { result.append(item) }
            }
            return result
        }
    }

    private func networkSummary(for cityID: String) async -> MetroNetworkSummary? {
        if let summary = summaries[cityID] {
            return summary
        }
        // A full network already cached has the same bounds; do not read the file again.
        if let network = networks[cityID] {
            let summary = MetroNetworkSummary(cityID: network.cityID, bounds: network.bounds, geometryKind: network.geometryKind)
            summaries[cityID] = summary
            return summary
        }
        guard !missingCityIDs.contains(cityID) else { return nil }
        guard let url = bundledNetworkURL(for: cityID) else {
            missingCityIDs.insert(cityID)
            return nil
        }
        do {
            let summary = try await Self.decode(MetroNetworkSummary.self, at: url)
            guard summary.cityID == cityID, summary.geometryKind == "physicalTrack" else {
                missingCityIDs.insert(cityID)
                return nil
            }
            summaries[cityID] = summary
            return summary
        } catch {
            AppLog.data.error("Failed to load bundled metro network summary \(cityID, privacy: .public): \(error)")
            missingCityIDs.insert(cityID)
            return nil
        }
    }

    private func bundledNetworkURL(for cityID: String) -> URL? {
        Bundle.main.url(forResource: cityID, withExtension: "json", subdirectory: "MetroNetworks")
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) async throws -> T {
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        }.value
    }

    func releaseMemory() {
        networks.removeAll()
        stationsByCity.removeAll()
        allStationsCache = nil
        MetroNetwork.clearNormalizedIndexCache()
    }
}
