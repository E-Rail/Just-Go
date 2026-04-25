import Foundation
import CoreLocation

final class StationSearchService {
    private let aMapService: AMapServiceProtocol

    init(aMapService: AMapServiceProtocol) {
        self.aMapService = aMapService
    }

    func search(keyword: String, city: String) async throws -> [Station] {
        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        return try await aMapService.searchStations(keyword: keyword, city: city)
    }

    func searchNearby(location: CLLocationCoordinate2D, radius: Double = 2000) async throws -> [Station] {
        return try await aMapService.searchStations(near: location, radius: radius)
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

    func sortStations(
        _ stations: [Station],
        by strategy: StationSortStrategy,
        userLocation: CLLocationCoordinate2D?
    ) -> [Station] {
        switch strategy {
        case .name:
            return stations.sorted { $0.name < $1.name }
        case .distance:
            guard let location = userLocation else { return stations }
            return stations.sorted { s1, s2 in
                let d1 = s1.coordinate.distance(to: location)
                let d2 = s2.coordinate.distance(to: location)
                return d1 < d2
            }
        case .accessibility:
            return stations.sorted { s1, s2 in
                let score1 = s1.accessibility?.communityRating ?? 0
                let score2 = s2.accessibility?.communityRating ?? 0
                return score1 > score2
            }
        }
    }
}

struct StationFilter {
    var accessibleOnly: Bool = false
    var elevatorOnly: Bool = false
    var transferOnly: Bool = false
    var searchText: String = ""

    static var none: StationFilter {
        StationFilter()
    }
}

enum StationSortStrategy {
    case name
    case distance
    case accessibility
}

// MARK: - CLLocationCoordinate2D Extension

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> Double {
        let from = CLLocation(latitude: latitude, longitude: longitude)
        let to = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return from.distance(from: to)
    }
}
