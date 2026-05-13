import Foundation
import CoreLocation

final class StationSearchService {
    private let aMapService: AMapService

    init(aMapService: AMapService) {
        self.aMapService = aMapService
    }

    func search(keyword: String, city: String) async throws -> [Station] {
        try await aMapService.searchStations(keyword: keyword, city: city)
    }

    func suggestions(keyword: String, city: String, limit: Int = 6) async throws -> [Station] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Array(try await search(keyword: query, city: city).prefix(limit))
    }

    func searchNearby(location: CLLocationCoordinate2D, radius: Double = 2000) async throws -> [Station] {
        try await aMapService.searchStations(near: location, radius: radius)
    }

    func stationDetails(stationID: String, city: String) async throws -> Station {
        try await aMapService.getStationDetails(stationID: stationID, city: city)
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

struct StationFilter {
    var accessibleOnly: Bool = false
    var elevatorOnly: Bool = false
    var transferOnly: Bool = false
}

// MARK: - CLLocationCoordinate2D Extension

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> Double {
        let from = CLLocation(latitude: latitude, longitude: longitude)
        let to = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return from.distance(from: to)
    }
}
