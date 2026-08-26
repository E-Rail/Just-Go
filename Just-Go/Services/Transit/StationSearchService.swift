import Foundation
import CoreLocation
import MapKit

final class StationSearchService {
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

    /// Every bundled station whose name matches, nearest first, plus anything Apple knows about
    /// that resolves to a station.
    ///
    /// There is no city argument because there is no selected city: the rider's own position
    /// orders the answers instead of gating them. Searching 人民广场 from Beijing therefore lists
    /// Shanghai's: last, but listed, which is what "distance-ranked" means and what a city filter
    /// could never do.
    /// - Parameter includingPlaces: whether to ask the place-search provider as well as the
    ///   bundled network. `false` answers entirely from data already on the device, which is what
    ///   every keystroke gets: the provider's free allowance is **100 searches a day for the whole
    ///   account**, about five riders, and this used to spend one on every typing pause. The
    ///   bundled index is the reason that costs nothing to give up — it holds every station in
    ///   every supported city and is what a rider searching a station name is looking for anyway.
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
        let region = coordinate.map {
            MKCoordinateRegion(center: $0, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        let places: [TransitPlace]
        do {
            places = try await placeSearchProvider.searchPlaces(keyword: query, region: region, limit: 20)
        } catch {
            guard bundledMatches.isEmpty else { return bundledMatches }
            throw error
        }
        // Resolve all places to stations concurrently, preserving input order by index.
        //
        // A place that does NOT resolve to a station is dropped. It used to be wrapped in a
        // synthesised `Station` and returned anyway, which is how a noodle shop ended up listed
        // under "Stations" with line dots and a distance. The app asserting something it had no
        // basis for. The search page already lists Apple's places in their own section, so
        // nothing is lost by refusing to relabel them.
        let mapKitMatches = await withTaskGroup(of: (Int, Station?).self) { group in
            for (index, place) in places.enumerated() {
                // Each place carries its own city now. The network whose bounds it falls in.
                // A nationwide search returns places in several, so one shared cityID would have
                // matched most of them against the wrong pack.
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
        // packs (科韵路 is in Guangzhou's, Foshan's and Dongguan's, and a nationwide search now
        // reaches all three), the second drops a MapKit hit that repeats a bundled one.
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

    /// Lines whose name matches, nearest first.
    ///
    /// Typing "18号线" used to match nothing at all. `Station.searchKey` is station names only, so
    /// the query fell through to Apple Maps and landed on "No Results" for a line that ships in the
    /// app. Lines are now findable, and kept in their own section rather than mixed into the
    /// stations: a line is not a station, and the last time this app relabelled one thing as
    /// another a noodle shop appeared under "Stations" with line dots and a distance.
    ///
    /// Built from the station list that is already cached rather than by decoding the packs again,
    /// so a line's stations are the stations that name it, and the count comes free.
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

    /// The stations closest to the rider, whichever cities they happen to be in. Empty when the
    /// device has no position: there is no centroid left to guess from, and a list of arbitrary
    /// stations claiming to be "nearby" would be a worse answer than none.
    func nearestStations(to coordinate: CLLocationCoordinate2D?, limit: Int) async -> [Station] {
        guard let coordinate else { return [] }
        // Collapse after ranking but before the limit: the duplicates sit next to each other once
        // sorted, so taking the limit first would spend rows on the same station twice.
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

    /// Search anywhere (POIs, addresses, landmarks) via Apple Maps. Not just metro stations.
    /// Biased to `region` (the visible map area, or the rider) when one is known; unbiased
    /// otherwise, which is honest about having nowhere to bias it to.
    func searchPlaces(keyword: String, region: MKCoordinateRegion?) async throws -> [TransitPlace] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try await placeSearchProvider.searchPlaces(keyword: query, region: region, limit: 12)
    }

    /// The programmed metro station a place corresponds to, if any. Matched by name against the
    /// bundled network covering that place, then the official city pack. Returns nil for
    /// non-station places (e.g. a shop), so only true stations resolve to a station.
    ///
    /// The pack is chosen by where the place *is*, not by what the app was set to: a Foshan
    /// station tapped while the map sat over Guangzhou used to be matched against Guangzhou's
    /// network and so resolved to nothing.
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
