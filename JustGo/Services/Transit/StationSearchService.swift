import Foundation
import CoreLocation
import MapKit

final class StationSearchService {
    private let placeSearchProvider: PlaceSearchProviding
    private let officialStationData: OfficialStationDataProviding
    private let metroNetworkProvider: MetroNetworkProviding
    private let cityService: CityService

    init(
        placeSearchProvider: PlaceSearchProviding,
        officialStationData: OfficialStationDataProviding,
        metroNetworkProvider: MetroNetworkProviding,
        cityService: CityService
    ) {
        self.placeSearchProvider = placeSearchProvider
        self.officialStationData = officialStationData
        self.metroNetworkProvider = metroNetworkProvider
        self.cityService = cityService
    }

    func search(keyword: String, city: String) async throws -> [Station] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return await stations(in: city) }
        let bundledMatches = await stations(in: city).filter {
            stationSearchText($0).localizedCaseInsensitiveContains(query)
        }
        let region = cityService.getCity(byID: city).map {
            MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
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
        // under "Stations" with line dots and a distance — the app asserting something it had no
        // basis for. The search page already lists Apple's places in their own section, so
        // nothing is lost by refusing to relabel them.
        let mapKitMatches = await withTaskGroup(of: (Int, Station?).self) { group in
            for (index, place) in places.enumerated() {
                group.addTask { [officialStationData] in
                    (index, await officialStationData.matchingStation(place: place, cityID: city))
                }
            }
            var indexed: [(Int, Station)] = []
            for await (index, station) in group {
                if let station { indexed.append((index, station)) }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return (bundledMatches + mapKitMatches).uniqued {
            "\($0.cityID)|\(normalizedStationName($0.name))"
        }
    }

    func stations(in cityID: String) async -> [Station] {
        guard !cityID.isEmpty else { return [] }
        return await metroNetworkProvider.stations(in: cityID)
    }

    func enrichStations(_ stations: [Station]) async -> [Station] {
        await officialStationData.enrichStations(stations)
    }

    func suggestions(keyword: String, city: String, limit: Int = 6) async throws -> [Station] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Array(try await search(keyword: query, city: city).prefix(limit))
    }

    /// Enrich an already-resolved station with official accessibility/facility data,
    /// without a keyword round-trip (avoids matching the wrong similarly-named station).
    func enrichStation(_ station: Station) async -> Station {
        await officialStationData.enrichStation(station)
    }

    /// Search anywhere (POIs, addresses, landmarks) via Apple Maps — not just metro
    /// stations. Biased to `region` (the visible map area) when provided, else the city.
    func searchPlaces(keyword: String, city: String, region: MKCoordinateRegion?) async throws -> [TransitPlace] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let searchRegion = region ?? cityService.getCity(byID: city).map {
            MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        return try await placeSearchProvider.searchPlaces(keyword: query, region: searchRegion, limit: 12)
    }

    /// The programmed metro station a place corresponds to, if any — matched by name
    /// against the bundled network first, then the official city pack. Returns nil for
    /// non-station places (e.g. a shop), so only true stations resolve to a station.
    func station(matching place: TransitPlace, city: String) async -> Station? {
        if let network = await metroNetworkProvider.network(for: city),
           let match = network.matchingStation(named: place.name, near: place.coordinate) {
            return await enrichStation(network.displayStation(match))
        }
        return await officialStationData.matchingStation(place: place, cityID: city)
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

private func stationSearchText(_ station: Station) -> String {
    [station.name, station.nameEn, station.namePinyin]
        .compactMap { $0 }
        .joined(separator: " ")
}

struct StationFilter {
    var accessibleOnly: Bool = false
    var elevatorOnly: Bool = false
    var transferOnly: Bool = false
    var facilityType: StationFacilityType? = nil
}
