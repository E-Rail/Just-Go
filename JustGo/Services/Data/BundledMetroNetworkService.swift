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
    let networkIdentity: String?
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

struct MetroNetwork: Codable, Equatable, Identifiable {
    let cityID: String
    let version: String
    let bounds: MetroBounds
    let geometrySource: String
    let geometryKind: String
    let attribution: String
    let licenseURL: String
    let sourceSnapshot: String
    let coordinateSystem: String
    let sourceURLs: [String]
    let lines: [MetroLine]
    let stations: [MetroStation]

    var id: String { cityID }

    var displayStations: [Station] {
        let linesByID = displayLinesByID
        return stations.map { displayStation($0, linesByID: linesByID) }
    }

    func matchingStation(named name: String, near coordinate: CLLocationCoordinate2D) -> MetroStation? {
        let key = normalizedStationName(name)
        return stations
            .filter { normalizedStationName($0.name) == key || normalizedStationName($0.nameEn ?? "") == key }
            .min {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude).distance(to: coordinate) <
                    CLLocationCoordinate2D(latitude: $1.latitude, longitude: $1.longitude).distance(to: coordinate)
            }
    }

    func displayStation(_ item: MetroStation) -> Station {
        displayStation(item, linesByID: displayLinesByID)
    }

    private var displayLinesByID: [String: SubwayLine] {
        Dictionary(uniqueKeysWithValues: lines.map { line in
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
        })
    }

    private func displayStation(_ item: MetroStation, linesByID: [String: SubwayLine]) -> Station {
        let station = Station(
            stationID: "network-\(cityID)-\(item.id)",
            name: item.name,
            nameEn: item.nameEn,
            latitude: item.latitude,
            longitude: item.longitude,
            cityID: cityID,
            isTransferStation: Set(item.lineIDs).count > 1
        )
        station.lines = item.lineIDs.compactMap { linesByID[$0] }
        return station
    }
}

protocol MetroNetworkProviding {
    func network(for cityID: String) async -> MetroNetwork?
    func networks() async -> [MetroNetwork]
    func stations(in cityID: String) async -> [Station]
}

extension MetroNetworkProviding {
    func stations(in cityID: String) async -> [Station] {
        await network(for: cityID)?.displayStations ?? []
    }

    func networks() async -> [MetroNetwork] {
        []
    }
}

actor BundledMetroNetworkService: MetroNetworkProviding {
    private static let supportedCityIDs = ["1100", "3100", "4401", "4403", "5101", "3301"]
    private var networks: [String: MetroNetwork] = [:]
    private var stationsByCity: [String: [Station]] = [:]
    private var missingCityIDs: Set<String> = []

    func network(for cityID: String) async -> MetroNetwork? {
        if let network = networks[cityID] {
            return network
        }
        guard !missingCityIDs.contains(cityID) else { return nil }
        guard let url = Bundle.main.url(
            forResource: cityID,
            withExtension: "json",
            subdirectory: "MetroNetworks"
        ) else {
            missingCityIDs.insert(cityID)
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let network = try JSONDecoder().decode(MetroNetwork.self, from: data)
            guard network.cityID == cityID, network.geometryKind == "physicalTrack" else {
                AppLog.data.error("Bundled metro network \(cityID, privacy: .public) failed validation (cityID or geometryKind mismatch)")
                missingCityIDs.insert(cityID)
                return nil
            }
            networks[cityID] = network
            return network
        } catch {
            AppLog.data.error("Failed to load bundled metro network \(cityID, privacy: .public): \(error)")
            missingCityIDs.insert(cityID)
            return nil
        }
    }

    func networks() async -> [MetroNetwork] {
        var result: [MetroNetwork] = []
        for cityID in Self.supportedCityIDs {
            if let network = await network(for: cityID) {
                result.append(network)
            }
        }
        return result
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
}
