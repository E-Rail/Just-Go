import Foundation
import CoreLocation

protocol AMapServiceProtocol {
    func searchStations(keyword: String, city: String) async throws -> [Station]
    func searchStations(near location: CLLocationCoordinate2D, radius: Double) async throws -> [Station]
    func planTransitRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        city: String,
        accessibilityFilter: AccessibilityFilter?
    ) async throws -> [Route]
    func getRealTimeArrivals(lineID: String, stationID: String) async throws -> [RealTimeArrival]
}

struct AccessibilityFilter {
    var requiresWheelchairAccess: Bool
    var requiresElevator: Bool
    var avoidStairs: Bool
    var minAccessibilityScore: Double

    static var none: AccessibilityFilter {
        AccessibilityFilter(
            requiresWheelchairAccess: false,
            requiresElevator: false,
            avoidStairs: false,
            minAccessibilityScore: 0
        )
    }
}

final class AMapService: AMapServiceProtocol {
    private let localDataStore = SubwayDataStore()

    func searchStations(keyword: String, city: String) async throws -> [Station] {
        let stations = localDataStore.stations(in: city)
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !query.isEmpty else {
            return stations
        }

        return stations.filter { station in
            station.name.lowercased().contains(query) ||
            station.nameEn?.lowercased().contains(query) == true ||
            station.namePinyin?.lowercased().contains(query) == true
        }
    }

    func searchStations(near location: CLLocationCoordinate2D, radius: Double) async throws -> [Station] {
        localDataStore.allStations()
            .map { station in
                (station, station.coordinate.distance(to: location))
            }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    func planTransitRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        city: String,
        accessibilityFilter: AccessibilityFilter?
    ) async throws -> [Route] {
        let routes = localDataStore.planRoute(
            from: origin,
            to: destination,
            city: city,
            filter: accessibilityFilter ?? .none
        )

        guard !routes.isEmpty else {
            throw RoutePlanningError.noRouteFound
        }

        return routes
    }

    func getRealTimeArrivals(lineID: String, stationID: String) async throws -> [RealTimeArrival] {
        localDataStore.arrivals(lineID: lineID, stationID: stationID)
    }
}

private final class SubwayDataStore {
    private var systemsByCityID: [String: CitySubwaySystem] = [:]
    private var cityNameToID: [String: String] = [:]
    private var stationsByCityID: [String: [Station]] = [:]

    init(bundle: Bundle = .main) {
        loadCities(bundle: bundle)
        loadSystems(bundle: bundle)
#if SWIFT_PACKAGE
        loadCities(bundle: .module)
        loadSystems(bundle: .module)
#endif
        buildStations()
    }

    func allStations() -> [Station] {
        stationsByCityID.values.flatMap { $0 }
    }

    func stations(in city: String) -> [Station] {
        guard let cityID = resolveCityID(city) else { return [] }
        return stationsByCityID[cityID] ?? []
    }

    func planRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        city: String,
        filter: AccessibilityFilter
    ) -> [Route] {
        guard let cityID = resolveCityID(city),
              let system = systemsByCityID[cityID],
              let originStation = nearestStation(to: origin, cityID: cityID),
              let destinationStation = nearestStation(to: destination, cityID: cityID),
              originStation.stationID != destinationStation.stationID else {
            return []
        }

        var routes: [Route] = []

        for line in system.lines {
            guard let originIndex = line.stationIDs.firstIndex(of: originStation.stationID),
                  let destinationIndex = line.stationIDs.firstIndex(of: destinationStation.stationID) else {
                continue
            }

            let stopCount = abs(destinationIndex - originIndex)
            let duration = TimeInterval(max(stopCount, 1) * 180)
            let isAccessible = isStationUsable(originStation, filter: filter) && isStationUsable(destinationStation, filter: filter)
            if (filter.requiresWheelchairAccess || filter.requiresElevator) && !isAccessible {
                continue
            }

            let segment = RouteSegment(
                id: UUID(),
                type: .subway,
                lineName: line.nameEn ?? line.name,
                lineColorHex: line.colorHex,
                fromStationName: originStation.name,
                toStationName: destinationStation.name,
                fromStationID: originStation.stationID,
                toStationID: destinationStation.stationID,
                duration: duration,
                stops: stopCount,
                walkingDirections: nil,
                accessibilityNotes: accessibilityNotes(for: [originStation, destinationStation], filter: filter)
            )

            routes.append(Route(
                id: UUID(),
                origin: originStation.name,
                destination: destinationStation.name,
                originStationID: originStation.stationID,
                destinationStationID: destinationStation.stationID,
                segments: [segment],
                totalDuration: duration,
                totalStops: stopCount,
                transferCount: 0,
                accessibilityScore: isAccessible ? 1.0 : 0.55,
                isFullyAccessible: isAccessible,
                warnings: warnings(for: [originStation, destinationStation])
            ))
        }

        return routes.sorted { $0.totalDuration < $1.totalDuration }
    }

    func arrivals(lineID: String, stationID: String) -> [RealTimeArrival] {
        guard let system = systemsByCityID.values.first(where: { city in
            city.lines.contains { $0.lineID == lineID }
        }),
              let line = system.lines.first(where: { $0.lineID == lineID }) else {
            return []
        }

        let stationLookup = Dictionary(uniqueKeysWithValues: system.stations.map { ($0.stationID, $0) })
        let terminalNames = [line.stationIDs.first, line.stationIDs.last]
            .compactMap { id in id.flatMap { stationLookup[$0]?.name } }

        return terminalNames.enumerated().map { index, destination in
            let minutes = 3 + (index * 4)
            return RealTimeArrival(
                id: UUID(),
                lineName: line.nameEn ?? line.name,
                lineColorHex: line.colorHex,
                destination: destination,
                arrivalTime: Calendar.current.date(byAdding: .minute, value: minutes, to: .now) ?? .now,
                minutesRemaining: minutes,
                isAccessible: stationLookup[stationID]?.accessibility?.isFullyAccessible ?? false,
                platformNumber: "\(index + 1)"
            )
        }
    }

    private func loadCities(bundle: Bundle) {
        guard let url = resourceURL("cities", bundle: bundle),
              let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(CitiesResponse.self, from: data) else {
            return
        }

        for city in response.cities {
            cityNameToID[city.id.lowercased()] = city.id
            cityNameToID[city.name.lowercased()] = city.id
            cityNameToID[city.nameEn.lowercased()] = city.id
            cityNameToID[city.namePinyin.lowercased()] = city.id
        }
    }

    private func loadSystems(bundle: Bundle) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileName in ["beijing", "shanghai"] {
            guard let url = resourceURL(fileName, bundle: bundle),
                  let data = try? Data(contentsOf: url),
                  let system = try? decoder.decode(CitySubwaySystem.self, from: data) else {
                continue
            }

            systemsByCityID[system.cityID] = system
        }
    }

    private func buildStations() {
        for (cityID, system) in systemsByCityID {
            let lines = system.lines.map { lineData in
                SubwayLine(
                    lineID: lineData.lineID,
                    name: lineData.name,
                    nameEn: lineData.nameEn,
                    colorHex: lineData.colorHex,
                    cityID: cityID
                )
            }
            let lineLookup = Dictionary(uniqueKeysWithValues: zip(system.lines.map(\.lineID), lines))

            stationsByCityID[cityID] = system.stations.map { data in
                let station = Station(
                    stationID: data.stationID,
                    name: data.name,
                    nameEn: data.nameEn,
                    namePinyin: data.namePinyin,
                    latitude: data.latitude,
                    longitude: data.longitude,
                    cityID: cityID,
                    isTransferStation: data.isTransferStation,
                    floorCount: data.floorCount
                )
                station.lines = data.lineIDs.compactMap { lineLookup[$0] }
                station.exits = (data.exits ?? []).map { exit in
                    StationExit(
                        exitID: exit.exitID,
                        stationID: data.stationID,
                        name: exit.name,
                        nameEn: exit.nameEn,
                        hasElevator: exit.hasElevator,
                        hasEscalator: exit.hasEscalator,
                        hasWheelchairRamp: exit.hasWheelchairRamp,
                        isAccessible: exit.isAccessible,
                        nearbyLandmarks: exit.nearbyLandmarks ?? []
                    )
                }
                station.accessibility = data.accessibility.map { accessibility in
                    StationAccessibility(
                        stationID: data.stationID,
                        hasElevator: accessibility.hasElevator ?? false,
                        hasEscalator: accessibility.hasEscalator ?? false,
                        hasWheelchairRamp: accessibility.hasWheelchairRamp ?? false,
                        isFullyAccessible: accessibility.isFullyAccessible ?? false,
                        elevatorLocations: accessibility.elevatorLocations ?? [],
                        accessibleEntrances: accessibility.accessibleEntrances ?? [],
                        wheelchairBoardingAssistance: accessibility.wheelchairBoardingAssistance ?? false,
                        hasTactilePath: accessibility.hasTactilePath ?? false,
                        hasBrailleSigns: accessibility.hasBrailleSigns ?? false,
                        hasAudioAnnouncement: accessibility.hasAudioAnnouncement ?? false,
                        tactilePathCoverage: accessibility.tactilePathCoverage ?? 0,
                        hasVisualAnnouncement: accessibility.hasVisualAnnouncement ?? false,
                        hasHearingLoop: accessibility.hasHearingLoop ?? false,
                        hasSignLanguageDisplay: accessibility.hasSignLanguageDisplay ?? false,
                        hasSimplifiedSignage: accessibility.hasSimplifiedSignage ?? false,
                        hasColorCoding: accessibility.hasColorCoding ?? false,
                        hasPictograms: accessibility.hasPictograms ?? false,
                        communityRating: accessibility.isFullyAccessible == true ? 4.6 : 3.2,
                        reportCount: accessibility.isFullyAccessible == true ? 18 : 5
                    )
                }
                return station
            }
        }
    }

    private func resolveCityID(_ city: String) -> String? {
        let key = city.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let id = cityNameToID[key] {
            return id
        }
        if systemsByCityID[key] != nil {
            return key
        }
        return systemsByCityID["1100"] == nil ? systemsByCityID.keys.sorted().first : "1100"
    }

    private func nearestStation(to coordinate: CLLocationCoordinate2D, cityID: String) -> Station? {
        stationsByCityID[cityID]?
            .min { first, second in
                first.coordinate.distance(to: coordinate) < second.coordinate.distance(to: coordinate)
            }
    }

    private func isStationUsable(_ station: Station, filter: AccessibilityFilter) -> Bool {
        guard let accessibility = station.accessibility else {
            return !(filter.requiresWheelchairAccess || filter.requiresElevator)
        }

        if filter.requiresWheelchairAccess && !accessibility.isFullyAccessible {
            return false
        }
        if filter.requiresElevator && !accessibility.hasElevator {
            return false
        }
        return true
    }

    private func accessibilityNotes(for stations: [Station], filter: AccessibilityFilter) -> [String] {
        if filter.requiresElevator || filter.requiresWheelchairAccess {
            return stations.map { station in
                if station.accessibility?.isFullyAccessible == true {
                    return "\(station.name): accessible"
                }
                return "\(station.name): limited accessibility"
            }
        }
        return []
    }

    private func warnings(for stations: [Station]) -> [RouteWarning] {
        stations.compactMap { station in
            guard station.accessibility?.isFullyAccessible == false else { return nil }
            return RouteWarning(
                type: .serviceDisruption,
                message: "\(station.name) has limited accessibility information",
                affectedStationID: station.stationID
            )
        }
    }

    private func resourceURL(_ name: String, bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "json", subdirectory: "SubwayData") ??
        bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources/SubwayData") ??
        bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources") ??
        bundle.url(forResource: name, withExtension: "json")
    }
}

private struct CitiesResponse: Codable {
    let version: String
    let cities: [City]
}

// MARK: - AMap Response Models (for when SDK is integrated)

struct AMapTransitRouteResponse {
    let transits: [AMapTransit]?
    let count: Int
}

struct AMapTransit {
    let duration: TimeInterval
    let segments: [AMapTransitSegment]
    let walkingDistance: Double
}

struct AMapTransitSegment {
    let walking: AMapWalking?
    let bus: AMapBus?
}

struct AMapWalking {
    let distance: Double
    let duration: TimeInterval
    let steps: [AMapWalkingStep]
}

struct AMapWalkingStep {
    let instruction: String
    let road: String
    let distance: Double
    let duration: TimeInterval
}

struct AMapBus {
    let name: String
    let type: String
    let buslines: [AMapBusLine]
}

struct AMapBusLine {
    let name: String
    let departureStop: AMapBusStop
    let arrivalStop: AMapBusStop
    let viaNum: Int
    let duration: TimeInterval
}

struct AMapBusStop {
    let name: String
    let id: String
}
