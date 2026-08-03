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
    let paths: [[MetroCoordinate]]
}

struct MetroStation: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let nameEn: String?
    let latitude: Double
    let longitude: Double
    let lineIDs: [String]
}

/// Just enough of a network file to run the bounds-distance city match — decoding this instead
/// of the full `MetroNetwork` skips allocating every candidate city's station/line/polyline
/// arrays (the bulk of the file) for the ~50 cities that don't end up matching a given search.
struct MetroNetworkSummary: Decodable {
    let cityID: String
    let bounds: MetroBounds
    let geometryKind: String
}

/// A network file's stations and the lines they belong to, without `lines[].paths`.
///
/// The polylines are 69% of the bundled bytes (3.25 MB of 4.73 MB) and exist only to be drawn.
/// Leaving them undecoded is what makes one nationwide station list affordable: all 53 packs,
/// 6,711 stations, held at once so search can rank by distance instead of by which city the
/// rider had been made to pick.
struct MetroNetworkStationIndex: Decodable {
    struct Line: Decodable {
        let id: String
        let name: String
        let nameEn: String?
        let colorHex: String
    }

    let cityID: String
    let geometryKind: String
    let lines: [Line]
    let stations: [MetroStation]

    var displayStations: [Station] {
        let linesByID = Dictionary(
            lines.map { ($0.id, SubwayLine(lineID: $0.id, name: $0.name, nameEn: $0.nameEn, colorHex: $0.colorHex, cityID: cityID)) },
            uniquingKeysWith: { first, _ in first }
        )
        return stations.map { makeDisplayStation($0, cityID: cityID, linesByID: linesByID) }
    }
}

/// The one place a `MetroStation` becomes a rider-facing `Station`. Shared by the full network
/// and the station-only index above so the two can never disagree about an ID or a line list —
/// the map draws one and search lists the other, and a station that differs between them reads
/// as two different places.
private func makeDisplayStation(
    _ item: MetroStation,
    cityID: String,
    linesByID: [String: SubwayLine]
) -> Station {
    let displayLines = item.lineIDs.compactMap { linesByID[$0] }
    let station = Station(
        stationID: "network-\(cityID)-\(item.id)",
        name: item.name,
        nameEn: item.nameEn,
        latitude: item.latitude,
        longitude: item.longitude,
        cityID: cityID,
        isTransferStation: Set(displayLines.map(\.lineID)).count > 1
    )
    station.lines = displayLines
    return station
}

struct MetroNetwork: Codable, Equatable, Identifiable {
    let cityID: String
    let version: String
    let bounds: MetroBounds
    let geometryKind: String
    let lines: [MetroLine]
    let stations: [MetroStation]

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

    // Normalized-name → stations index, built once per (cityID, version) and cached, so
    // repeated `matchingStation` lookups become O(1) instead of re-normalizing every station
    // name (7 string replacements each) on every call. NSCache is thread-safe.
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
    /// Every bundled station, everywhere. Search ranks these by distance from the rider; there
    /// is no selected city to scope them to any more.
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
    private static let supportedCityIDs = ["1100", "3100", "4401", "4403", "5101", "3301", "1200", "5000", "4201", "3201", "6101", "3205", "4101", "4301", "2101", "3702", "2102", "3302", "3202", "5301", "3601", "3501", "3502", "3401", "1301", "5201", "2301", "2201", "4501", "6201", "6501", "1501", "1401", "4419", "4406", "3303", "3306", "3203", "3204", "3701", "4103", "3402", "3206", "3310", "3307", "4110", "3411", "8100", "8200", "7101", "7102", "7106", "7104"]
    private var networks: [String: MetroNetwork] = [:]
    private var stationsByCity: [String: [Station]] = [:]
    private var summaries: [String: MetroNetworkSummary] = [:]
    private var missingCityIDs: Set<String> = []
    private var allStationsCache: [Station]?

    func network(for cityID: String) async -> MetroNetwork? {
        if let network = networks[cityID] {
            return network
        }
        guard !missingCityIDs.contains(cityID) else { return nil }
        guard let url = bundledNetworkURL(for: cityID) else {
            missingCityIDs.insert(cityID)
            return nil
        }
        do {
            // Decode off the actor's cooperative-pool thread so the blocking file read +
            // JSON parse doesn't pin the actor (lets concurrent city loads run in parallel).
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

    /// Every bundled station, built once and kept.
    ///
    /// Decodes the station-only projection of each pack rather than the full network: the
    /// polylines it skips are 69% of the bytes and are drawn from the viewport-loaded networks
    /// anyway. A city already fully loaded contributes its cached `Station` objects instead of
    /// being read a second time.
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

        // Only the decode fans out. `Station` is a reference type and deliberately not Sendable,
        // so the objects are built here on the actor from the value-typed indexes the group
        // returns, rather than being passed across task boundaries.
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
        }
        // Sorted so the list is stable across launches regardless of which city's decode
        // finished first — the ranking that matters is applied by the caller, per rider.
        stations.sort { $0.stationID < $1.stationID }
        allStationsCache = stations
        return stations
    }

    /// Cheap bounds-only pass over every supported city, for callers (route search) that need
    /// to find the nearest matching network without paying to decode-and-permanently-cache all
    /// 53 cities' full station/line/polyline data just to compare bounding boxes.
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
        // A full network already cached (e.g. the user's current city) has the same bounds —
        // reuse it instead of re-reading and re-parsing the file a second time.
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
