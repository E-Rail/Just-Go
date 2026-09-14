import Foundation
import CoreLocation
import MapKit

final class StationSearchService {
    /// One place lookup per query, shared by the two callers that want it: the search page's place
    /// list and `search(keyword:near:)`, which uses the places to find stations the bundled index
    /// lacks. They run concurrently, so the later one joins the in-flight task. Place search allows
    /// 100 a day for the whole account. Only the newest query is held: riders search forwards.
    @MainActor private static var placeLookup: (key: String, task: Task<[TransitPlace], Error>)?

    private let placeSearchProvider: PlaceSearchProviding
    private let officialStationData: OfficialStationDataProviding
    private let metroNetworkProvider: MetroNetworkProviding

    init(
        placeSearchProvider: PlaceSearchProviding,
        officialStationData: OfficialStationDataProviding,
        metroNetworkProvider: MetroNetworkProviding
    ) {
        self.placeSearchProvider = placeSearchProvider
        self.officialStationData = officialStationData
        self.metroNetworkProvider = metroNetworkProvider
    }

    /// Every bundled station whose name matches, nearest first, plus any Apple place that resolves
    /// to a station. No city argument: the rider's position orders the answers rather than gating
    /// them, so 人民广场 searched from Beijing lists Shanghai's, last. - Parameter includingPlaces:
    /// whether to ask the place-search provider too. `false` answers from the device alone, which
    /// is what every keystroke gets: the bundled index holds every station in every supported city,
    /// and the provider allows 100 searches a day for the whole account.
    func search(
        keyword: String,
        near coordinate: CLLocationCoordinate2D?,
        includingPlaces: Bool = true
    ) async throws -> [Station] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return await nearestStations(to: coordinate, limit: nearbyStationLimit) }
        let needle = query.lowercased()
        let bundledMatches = rankedByDistance(
            await metroNetworkProvider.allStations().filter { $0.searchKey.contains(needle) },
            from: coordinate
        )
        guard includingPlaces else { return bundledMatches }
        let places: [TransitPlace]
        do {
            places = try await sharedPlaces(matching: query, near: coordinate)
        } catch {
            guard bundledMatches.isEmpty else { return bundledMatches }
            throw error
        }
        // Resolve every place to a station concurrently, keeping input order. A place that is not a
        // station is dropped rather than dressed up as one; the search page lists places in their
        // own section.
        let mapKitMatches = await withTaskGroup(of: (Int, Station?).self) { group in
            for (index, place) in places.enumerated() {
                // Each place carries its own city: the network whose bounds it falls in. A
                // nationwide search spans several.
                let cityID = await cityID(covering: place.coordinate)
                group.addTask { [officialStationData] in
                    guard let cityID else { return (index, nil) }
                    return (index, await officialStationData.matchingStation(place: place, cityID: cityID))
                }
            }
            var indexed: [(Int, Station)] = []
            for await (index, station) in group {
                if let station { indexed.append((index, station)) }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // `oneEntryPerPlace` before `uniqued`: the first collapses one station shipped by several
        // packs (科韵路 is in Guangzhou's, Foshan's and Dongguan's), the second drops a MapKit hit
        // that repeats a bundled one.
        return (bundledMatches + mapKitMatches).oneEntryPerPlace().uniqued {
            "\($0.cityID)|\(normalizedStationName($0.name))"
        }
    }

    /// A line a rider can open, as search results it.
    struct LineResult: Identifiable, Hashable {
        let cityID: String
        let lineID: String
        let name: String
        let nameEn: String?
        let colorHex: String
        let stationCount: Int
        /// The nearest station on this line, which is what orders the results.
        let distance: CLLocationDistance?

        var id: String { "\(cityID)|\(lineID)" }
    }

    /// Lines whose name matches, nearest first, in their own section: a line is not a station.
    /// Built from the cached station list, so a line's stations are the stations that name it.
    func searchLines(keyword: String, near coordinate: CLLocationCoordinate2D?) async -> [LineResult] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 1 else { return [] }
        let needle = query.lowercased()
        let queryToken = TransitLineMatching.normalizedLineToken(query)

        var counts: [String: Int] = [:]
        var nearest: [String: CLLocationDistance] = [:]
        var lines: [String: SubwayLine] = [:]

        let origin = coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        for station in await metroNetworkProvider.allStations() {
            let stationDistance = origin.map {
                CLLocation(latitude: station.latitude, longitude: station.longitude).distance(from: $0)
            }
            for line in station.uniqueLogicalLines {
                let key = "\(line.cityID)|\(line.lineID)"
                counts[key, default: 0] += 1
                lines[key] = lines[key] ?? line
                if let stationDistance {
                    nearest[key] = min(nearest[key] ?? .greatestFiniteMagnitude, stationDistance)
                }
            }
        }

        let matches = lines.values.filter { line in
            if line.name.lowercased().contains(needle) { return true }
            if line.nameEn?.lowercased().contains(needle) == true { return true }
            // "18" finds 18号线 and 北京地铁18号线 alike. Empty tokens match nothing rather than
            // everything, which is what a bare "地铁" would otherwise do.
            return !queryToken.isEmpty && TransitLineMatching.normalizedLineToken(line.name) == queryToken
        }

        return matches.map { line in
            let key = "\(line.cityID)|\(line.lineID)"
            return LineResult(
                cityID: line.cityID,
                lineID: line.lineID,
                name: line.name,
                nameEn: line.nameEn,
                colorHex: line.colorHex,
                stationCount: counts[key] ?? 0,
                distance: nearest[key]
            )
        }
        .sorted {
            // Distance first where there is a fix; alphabetical is the fallback rather than
            // arbitrary dictionary order, which would reshuffle between launches.
            switch ($0.distance, $1.distance) {
            case let (left?, right?): return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.name < $1.name
            }
        }
    }

    /// The stations closest to the rider, whichever cities they are in. Empty without a position:
    /// arbitrary stations claiming to be "nearby" are worse than none.
    func nearestStations(to coordinate: CLLocationCoordinate2D?, limit: Int) async -> [Station] {
        guard let coordinate else { return [] }
        // Collapse after ranking and before the limit: duplicates sit together once sorted, and
        // would otherwise take two rows.
        let ranked = rankedByDistance(await metroNetworkProvider.allStations(), from: coordinate)
        return Array(Array(ranked.prefix(limit * 2)).oneEntryPerPlace().prefix(limit))
    }

    /// How many stations the no-query list offers. Enough to cover a rider standing anywhere in a
    /// metro area, far short of the 6,711 that exist.
    var nearbyStationLimit: Int { 60 }

    func stations(in cityID: String) async -> [Station] {
        guard !cityID.isEmpty else { return [] }
        return await metroNetworkProvider.stations(in: cityID)
    }

    func enrichStations(_ stations: [Station]) async -> [Station] {
        await officialStationData.enrichStations(stations)
    }

    /// Enrich an already-resolved station with official accessibility/facility data,
    /// without a keyword round-trip (avoids matching the wrong similarly-named station).
    func enrichStation(_ station: Station) async -> Station {
        await officialStationData.enrichStation(station)
    }

    /// Search anywhere (POIs, addresses, landmarks) via Apple Maps, biased to `region` when one is
    /// known and unbiased otherwise.
    func searchPlaces(keyword: String, near coordinate: CLLocationCoordinate2D?) async throws -> [TransitPlace] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Array(try await sharedPlaces(matching: query, near: coordinate).prefix(12))
    }

    /// The place answer for this query, fetched once however many callers want it.
    ///
    /// Biased to the rider over 80 km rather than filtered by city: `MKLocalSearch`'s region is a
    /// hint, so searching 人民广场 from Beijing still lists Shanghai's, last.
    @MainActor
    private func sharedPlaces(
        matching query: String,
        near coordinate: CLLocationCoordinate2D?
    ) async throws -> [TransitPlace] {
        let key = String(
            format: "%@|%.3f,%.3f",
            query.lowercased(),
            coordinate?.latitude ?? 0,
            coordinate?.longitude ?? 0
        )
        if let lookup = Self.placeLookup, lookup.key == key {
            return try await lookup.task.value
        }
        let region = coordinate.map {
            MKCoordinateRegion(center: $0, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        let provider = placeSearchProvider
        let task = Task { try await provider.searchPlaces(keyword: query, region: region, limit: 20) }
        Self.placeLookup = (key, task)
        do {
            return try await task.value
        } catch {
            // Not kept: a refusal must not answer the next tap on Search.
            if Self.placeLookup?.key == key { Self.placeLookup = nil }
            throw error
        }
    }

    /// The metro station a place corresponds to, matched by name against the bundled network
    /// covering where the place is, then the official pack. nil for a place that is not a station.
    func station(matching place: TransitPlace) async -> Station? {
        guard let cityID = await cityID(covering: place.coordinate) else { return nil }
        if let network = await metroNetworkProvider.network(for: cityID),
           let match = network.matchingStation(named: place.name, near: place.coordinate) {
            return await enrichStation(network.displayStation(match))
        }
        return await officialStationData.matchingStation(place: place, cityID: cityID)
    }

    /// The bundled network a coordinate sits in. Nearest bounding box within 25 km, the same
    /// tolerance the route provider uses to decide which packs a trip can reach.
    private func cityID(covering coordinate: CLLocationCoordinate2D) async -> String? {
        await metroNetworkProvider.networkSummaries()
            .filter { $0.bounds.distance(to: coordinate) <= 25_000 }
            .min { $0.bounds.distance(to: coordinate) < $1.bounds.distance(to: coordinate) }?
            .cityID
    }

    /// Nearest first when the rider's position is known, input order otherwise. Each distance is
    /// computed once: the comparator runs O(n log n) times and the maths is trig-heavy.
    private func rankedByDistance(_ stations: [Station], from coordinate: CLLocationCoordinate2D?) -> [Station] {
        guard let coordinate else { return stations }
        return stations
            .map { (station: $0, distance: $0.coordinate.distance(to: coordinate)) }
            .sorted { $0.distance < $1.distance }
            .map(\.station)
    }

    func filterStations(
        _ stations: [Station],
        by filter: StationFilter
    ) -> [Station] {
        stations.filter { station in
            var matches = true

            if filter.accessibleOnly {
                matches = matches && (station.accessibility?.isFullyAccessible ?? false)
            }

            if filter.elevatorOnly {
                matches = matches && (station.accessibility?.hasElevator ?? false)
            }

            if filter.transferOnly {
                matches = matches && station.isTransferStation
            }

            if let facilityType = filter.facilityType {
                matches = matches && station.facilities.contains { $0.type == facilityType }
            }

            return matches
        }
    }
}

struct StationFilter {
    var accessibleOnly: Bool = false
    var elevatorOnly: Bool = false
    var transferOnly: Bool = false
    var facilityType: StationFacilityType? = nil

    /// Whether anything is being narrowed. Used to keep the filter row on screen when a filter has
    /// emptied the list, which is exactly the moment the rider needs it back to undo the filter.
    var isActive: Bool {
        accessibleOnly || elevatorOnly || transferOnly || facilityType != nil
    }
}
