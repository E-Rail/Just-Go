import Foundation

enum CityPackLoadStatus: Equatable {
    case loaded(version: String)
    case notConfigured
    case sourcePending
    case notAvailable
    case failed
}

struct CityPackStationMap: Codable, Equatable {
    let title: String?
    let assetURL: String
    let assetType: String
    let sourceURL: String?

    var resolvedURL: URL? { URL(string: assetURL) }
    var isImage: Bool { ["image", "png", "jpg", "jpeg", "webp"].contains(assetType.lowercased()) }

    func resolving(relativeTo baseURL: URL?) -> CityPackStationMap {
        guard URL(string: assetURL)?.scheme == nil,
              let baseURL,
              let url = URL(string: assetURL, relativeTo: baseURL)?.absoluteURL else { return self }
        return CityPackStationMap(title: title, assetURL: url.absoluteString, assetType: assetType, sourceURL: sourceURL)
    }
}

struct CityPackStationAsset: Codable, Equatable {
    let category: String
    let title: String?
    let assetURL: String
    let assetType: String
    let sourceURL: String?

    var resolvedURL: URL? { URL(string: assetURL) }
    var isImage: Bool { ["image", "png", "jpg", "jpeg", "webp"].contains(assetType.lowercased()) }

    func resolving(relativeTo baseURL: URL?) -> CityPackStationAsset {
        guard URL(string: assetURL)?.scheme == nil,
              let baseURL,
              let url = URL(string: assetURL, relativeTo: baseURL)?.absoluteURL else { return self }
        return CityPackStationAsset(category: category, title: title, assetURL: url.absoluteString, assetType: assetType, sourceURL: sourceURL)
    }
}

struct CityPackServiceStatus: Codable, Equatable {
    let accIDs: [String]
    let crowdControlWindows: [String]
    let statusColor: String?
    let statusUpdatedAt: String?

    var hasDisplayableStatus: Bool {
        !crowdControlWindows.isEmpty || statusColor?.isEmpty == false
    }
}

protocol OfficialStationDataProviding {
    func loadCityPack(for cityID: String) async -> CityPackLoadStatus
    func enrichStation(_ station: Station) async -> Station
    func enrichStations(_ stations: [Station]) async -> [Station]
    func stationMap(for station: Station) async -> CityPackStationMap?
    func timetableAssets(for station: Station) async -> [CityPackStationAsset]
    func serviceStatus(for station: Station) async -> CityPackServiceStatus?
    func trainTimes(for station: Station) async -> [RealTimeArrival]
    func routeCoverage(cityID: String, stationNames: [String]) async -> RouteDataCoverage
    func matchingStation(place: TransitPlace, cityID: String) async -> Station?
}

actor OfficialCityPackService: OfficialStationDataProviding {
    private let session: URLSession
    private var manifests: [URL: OfficialManifest] = [:]
    private var packs: [String: LoadedPack] = [:]
    private var loadStatuses: [String: CityPackLoadStatus] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func loadCityPack(for cityID: String) async -> CityPackLoadStatus {
        if let pack = packs[cityID] {
            return .loaded(version: pack.data.version)
        }
        if let status = loadStatuses[cityID] {
            return status
        }
        guard !Self.manifestURLs.isEmpty else { return .notConfigured }

        var pendingStatus: CityPackLoadStatus?
        for manifestURL in Self.manifestURLs {
            do {
                let manifest = try await loadManifest(from: manifestURL)
                guard let entry = manifest.cities.first(where: { $0.cityID == cityID }) else { continue }
                guard let downloadURL = resolvedURL(entry.downloadURL, relativeTo: manifestURL) else {
                    pendingStatus = entry.hasPendingData ? .sourcePending : .notAvailable
                    continue
                }
                let data = try await download(from: downloadURL)
                let decoded = try JSONDecoder().decode(OfficialPack.self, from: data)
                guard decoded.cityID == cityID, decoded.version == entry.version else { continue }
                packs[cityID] = LoadedPack(data: decoded, assetBaseURL: downloadURL.deletingLastPathComponent())
                let status = CityPackLoadStatus.loaded(version: decoded.version)
                loadStatuses[cityID] = status
                return status
            } catch {
                continue
            }
        }
        let status = pendingStatus ?? .failed
        loadStatuses[cityID] = status
        return status
    }

    func enrichStation(_ station: Station) async -> Station {
        _ = await loadCityPack(for: station.cityID)
        return enrichLoadedStation(station)
    }

    func enrichStations(_ stations: [Station]) async -> [Station] {
        for cityID in Set(stations.map(\.cityID)).filter({ !$0.isEmpty }) {
            _ = await loadCityPack(for: cityID)
        }
        return stations.map(enrichLoadedStation)
    }

    private func enrichLoadedStation(_ station: Station) -> Station {
        guard let item = stationRecord(cityID: station.cityID, stationName: station.name) else { return station }
        if let data = item.accessibility?.data {
            station.accessibility = StationAccessibility(stationID: station.stationID, data: data)
        }
        station.facilities = item.facilities(for: station.stationID)
        return station
    }

    func stationMap(for station: Station) async -> CityPackStationMap? {
        _ = await loadCityPack(for: station.cityID)
        guard let loaded = packs[station.cityID] else { return nil }
        return stationRecord(cityID: station.cityID, stationName: station.name)?
            .stationMaps.first?.resolving(relativeTo: loaded.assetBaseURL)
    }

    func timetableAssets(for station: Station) async -> [CityPackStationAsset] {
        _ = await loadCityPack(for: station.cityID)
        guard let loaded = packs[station.cityID] else { return [] }
        return stationRecord(cityID: station.cityID, stationName: station.name)?
            .stationAssets
            .filter { $0.category == "timetable_image" }
            .map { $0.resolving(relativeTo: loaded.assetBaseURL) } ?? []
    }

    func serviceStatus(for station: Station) async -> CityPackServiceStatus? {
        _ = await loadCityPack(for: station.cityID)
        return stationRecord(cityID: station.cityID, stationName: station.name)?.serviceStatus
    }

    func trainTimes(for station: Station) async -> [RealTimeArrival] {
        _ = await loadCityPack(for: station.cityID)
        guard let item = stationRecord(cityID: station.cityID, stationName: station.name) else { return [] }
        return item.schedules.compactMap { schedule in
            guard let timeText = schedule.formattedTime else { return nil }
            return RealTimeArrival(
                id: UUID(),
                lineName: schedule.lineName,
                lineColorHex: "#007AFF",
                destination: schedule.direction,
                arrivalTime: nil,
                minutesRemaining: nil,
                timeText: timeText,
                isAccessible: item.accessibility?.data.isFullyAccessible == true,
                platformNumber: nil,
                source: .officialSchedule
            )
        }
    }

    func routeCoverage(cityID: String, stationNames: [String]) async -> RouteDataCoverage {
        _ = await loadCityPack(for: cityID)
        let names = Array(Set(stationNames.map(normalizedStationName)))
        let stations = names.compactMap { stationRecord(cityID: cityID, normalizedName: $0) }
        return RouteDataCoverage(
            stationCount: names.count,
            officialAccessibilityCount: stations.filter { $0.accessibility != nil }.count,
            officialScheduleCount: stations.filter { !$0.schedules.isEmpty }.count,
            officialStationMapCount: stations.filter { !$0.stationMaps.isEmpty }.count,
            officialFacilityCount: stations.filter { !$0.stationFacilities.isEmpty || !($0.accessibility?.facilityNotes ?? []).isEmpty }.count
        )
    }

    func matchingStation(place: TransitPlace, cityID: String) async -> Station? {
        _ = await loadCityPack(for: cityID)
        guard stationRecord(cityID: cityID, stationName: place.name) != nil else { return nil }
        let station = Station(
            stationID: "official-\(cityID)-\(normalizedStationName(place.name))",
            name: place.name,
            latitude: place.coordinate.latitude,
            longitude: place.coordinate.longitude,
            cityID: cityID
        )
        return await enrichStation(station)
    }

    private func loadManifest(from url: URL) async throws -> OfficialManifest {
        if let manifest = manifests[url] { return manifest }
        let data = try await download(from: url)
        let decoded = try JSONDecoder().decode(OfficialManifest.self, from: data)
        manifests[url] = decoded
        return decoded
    }

    private func download(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RoutePlanningError.networkError }
        return data
    }

    private func stationRecord(cityID: String, stationName: String) -> OfficialStation? {
        stationRecord(cityID: cityID, normalizedName: normalizedStationName(stationName))
    }

    private func stationRecord(cityID: String, normalizedName: String) -> OfficialStation? {
        packs[cityID]?.stationsByName[normalizedName]
    }

    private func resolvedURL(_ value: String?, relativeTo base: URL) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme != nil { return url }
        return URL(string: value, relativeTo: base)?.absoluteURL
    }

    private static var manifestURLs: [URL] {
        let configuredValues = [
            Bundle.main.object(forInfoDictionaryKey: "CityPackManifestURL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CityPackBaseURL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CityPackFallbackBaseURL") as? String
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("$(") }
        let values = configuredValues + [
            "https://cdn.jsdelivr.net/gh/E-Rail/JustGo@main/DataPacks",
            "https://raw.githubusercontent.com/E-Rail/JustGo/main/DataPacks"
        ]
        var seen = Set<String>()
        return values.compactMap { value in
            guard let url = URL(string: value) else { return nil }
            let manifestURL = value.hasSuffix("manifest.json") ? url : url.appendingPathComponent("manifest.json")
            return seen.insert(manifestURL.absoluteString).inserted ? manifestURL : nil
        }
    }
}

private struct LoadedPack {
    let data: OfficialPack
    let assetBaseURL: URL
    let stationsByName: [String: OfficialStation]

    init(data: OfficialPack, assetBaseURL: URL) {
        self.data = data
        self.assetBaseURL = assetBaseURL
        self.stationsByName = Dictionary(
            data.stations.map { (normalizedStationName($0.stationName), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

private struct OfficialManifest: Decodable {
    let cities: [OfficialManifestCity]
}

private struct OfficialManifestCity: Decodable {
    let cityID: String
    let version: String
    let downloadURL: String?
    let capabilities: OfficialCapabilities

    var hasPendingData: Bool {
        capabilities.accessibility == "source_pending" ||
            capabilities.schedules == "source_pending" ||
            capabilities.stationMaps == "source_pending"
    }
}

private struct OfficialCapabilities: Decodable {
    let accessibility: String
    let schedules: String
    let stationMaps: String
}

private struct OfficialPack: Decodable {
    let cityID: String
    let version: String
    let stations: [OfficialStation]
}

private struct OfficialStation: Decodable {
    let stationName: String
    let accessibility: OfficialAccessibility?
    let schedules: [OfficialSchedule]
    let stationMaps: [CityPackStationMap]
    let stationAssets: [CityPackStationAsset]
    let stationFacilities: [OfficialFacility]
    let serviceStatus: CityPackServiceStatus?

    enum CodingKeys: String, CodingKey {
        case stationName, accessibility, schedules, stationMaps, stationAssets, stationFacilities, serviceStatus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stationName = try values.decode(String.self, forKey: .stationName)
        accessibility = try values.decodeIfPresent(OfficialAccessibility.self, forKey: .accessibility)
        schedules = try values.decodeIfPresent([OfficialSchedule].self, forKey: .schedules) ?? []
        stationMaps = try values.decodeIfPresent([CityPackStationMap].self, forKey: .stationMaps) ?? []
        stationAssets = try values.decodeIfPresent([CityPackStationAsset].self, forKey: .stationAssets) ?? []
        stationFacilities = try values.decodeIfPresent([OfficialFacility].self, forKey: .stationFacilities) ?? []
        serviceStatus = try values.decodeIfPresent(CityPackServiceStatus.self, forKey: .serviceStatus)
    }

    func facilities(for stationID: String) -> [StationFacility] {
        let explicit = stationFacilities.map { $0.value(stationID: stationID) }
        let fallback = (accessibility?.facilityNotes ?? []).map {
            StationFacility(
                id: "\(stationID)-\($0)",
                stationID: stationID,
                type: StationFacilityType.inferred(from: $0),
                name: $0
            )
        }
        var seen = Set<String>()
        return (explicit.isEmpty ? fallback : explicit).filter {
            seen.insert("\($0.type.rawValue)|\($0.name)|\($0.locationText ?? "")").inserted
        }
    }
}

private struct OfficialFacility: Decodable {
    let id: String?
    let type: String?
    let name: String
    let locationText: String?

    func value(stationID: String) -> StationFacility {
        StationFacility(
            id: id ?? "\(stationID)-\(name)",
            stationID: stationID,
            type: StationFacilityType(rawValue: type ?? "") ?? .inferred(from: "\(name) \(locationText ?? "")"),
            name: name,
            locationText: locationText
        )
    }
}

private struct OfficialSchedule: Decodable {
    let lineName: String
    let direction: String
    let firstTime: String?
    let lastTime: String?

    var formattedTime: String? {
        let values = [
            firstTime.map { "\(AppLocalization.localized("First")) \($0)" },
            lastTime.map { "\(AppLocalization.localized("last")) \($0)" }
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

private struct OfficialAccessibility: Decodable {
    let source: String?
    let hasElevator: Bool?
    let hasEscalator: Bool?
    let hasWheelchairRamp: Bool?
    let hasTactilePath: Bool?
    let hasAccessibleRestroom: Bool?
    let elevatorLocations: [String]?
    let accessibleEntrances: [String]?
    let facilityNotes: [String]?

    var data: AccessibilityData {
        AccessibilityData(
            source: source ?? "official_city_pack",
            hasElevator: hasElevator,
            hasEscalator: hasEscalator,
            hasWheelchairRamp: hasWheelchairRamp,
            hasAccessibleRestroom: hasAccessibleRestroom,
            isFullyAccessible: hasElevator == true || hasWheelchairRamp == true ? true : nil,
            elevatorLocations: elevatorLocations,
            accessibleEntrances: accessibleEntrances,
            facilityNotes: facilityNotes,
            hasTactilePath: hasTactilePath,
            hasColorCoding: true,
            hasPictograms: true
        )
    }
}

private func normalizedStationName(_ value: String) -> String {
    value
        .replacingOccurrences(of: "地铁站", with: "")
        .replacingOccurrences(of: "站", with: "")
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
}
