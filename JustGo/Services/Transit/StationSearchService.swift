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
        let mapKitMatches = await places.asyncMap { place in
            if let official = await self.officialStationData.matchingStation(place: place, cityID: city) {
                return official
            }
            return Station(
                stationID: place.id,
                name: place.name,
                latitude: place.coordinate.latitude,
                longitude: place.coordinate.longitude,
                cityID: city
            )
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

    func searchNearby(location: CLLocationCoordinate2D) async throws -> [Station] {
        let searchRadius = 10_000.0
        let networks = await metroNetworkProvider.networks().filter {
            $0.bounds.distance(to: location) <= searchRadius
        }
        var bundledStations: [Station] = []
        for network in networks {
            bundledStations.append(contentsOf: await metroNetworkProvider.stations(in: network.cityID))
        }
        let stations = bundledStations
            .map { ($0, location.distance(to: $0.coordinate)) }
            .filter { $0.1 <= searchRadius }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
            .map(\.0)
        return await officialStationData.enrichStations(stations)
    }

    func stationDetails(stationID: String, city: String) async throws -> Station {
        guard let station = try await search(keyword: stationID, city: city).first else {
            throw RoutePlanningError.stationNotFound
        }
        return await officialStationData.enrichStation(station)
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

            return matches
        }
    }
}

private func stationSearchText(_ station: Station) -> String {
    [station.name, station.nameEn, station.namePinyin]
        .compactMap { $0 }
        .joined(separator: " ")
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self {
            result.append(await transform(element))
        }
        return result
    }
}

struct StationFilter {
    var accessibleOnly: Bool = false
    var elevatorOnly: Bool = false
    var transferOnly: Bool = false
}
