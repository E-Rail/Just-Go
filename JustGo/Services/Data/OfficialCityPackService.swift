import Foundation

// Pre-compiled once instead of recompiling on every exitTokens(in:) call — stationGuidance
// calls it per station per route, so this pattern was being rebuilt dozens of times per search.
private let exitTokenExpression = try! NSRegularExpression(pattern: "([A-Za-z0-9]+(?:[、，,/\\s][A-Za-z0-9]+)*)\\s*[出入]?口")

enum CityPackLoadStatus: Equatable {
    case available(version: String)
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
    func cityPackStatuses(for cityIDs: [String]) async -> [String: CityPackLoadStatus]
    func loadCityPack(for cityID: String) async -> CityPackLoadStatus
    func enrichStation(_ station: Station) async -> Station
    func enrichStations(_ stations: [Station]) async -> [Station]
    func stationMap(for station: Station) async -> CityPackStationMap?
    func timetableAssets(for station: Station) async -> [CityPackStationAsset]
    func serviceStatus(for station: Station) async -> CityPackServiceStatus?
    func trainTimes(for station: Station) async -> [RealTimeArrival]
    func serviceWindows(cityID: String, stationName: String) async -> [StationServiceWindow]
    func crowdControlWindows(cityID: String, stationNames: [String]) async -> [ComfortStationWindows]
    func routeCoverage(cityID: String, stationNames: [String]) async -> RouteDataCoverage
    func matchingStation(place: TransitPlace, cityID: String) async -> Station?
    /// Best-available entrance/exit (+ optional platform/interchange) guidance per station,
    /// keyed by the original station name passed in. Official when authored in the pack,
    /// otherwise text-extracted at `.estimated` confidence, otherwise `.empty`/`.unavailable`.
    func stationGuidance(cityID: String, stationNames: [String]) async -> [String: StationAccessGuidance]
}

actor OfficialCityPackService: OfficialStationDataProviding {
    private let session: URLSession
    private let metroNetworks: MetroNetworkProviding
    private var manifests: [URL: OfficialManifest] = [:]
    private var inFlightManifests: [URL: Task<OfficialManifest, Error>] = [:]
    private var packs: [String: LoadedPack] = [:]
    private var loadStatuses: [String: CityPackLoadStatus] = [:]
    // A .failed status used to be excluded from loadStatuses entirely, so every caller that
    // touches a city with no signal/no pack (enrichStation, stationMap, stationGuidance, etc.
    // all start with `_ = await loadCityPack(...)`) re-ran the full multi-URL network download
    // attempt on every single call — exactly the "underground, no signal" case this app targets.
    // Cache .failed too, but only for a cooldown window, so it fails fast on repeat touches
    // while still retrying periodically in case connectivity comes back.
    private var failedCooldownUntil: [String: Date] = [:]
    private static let failureCooldown: TimeInterval = 45
    private var inFlightLoads: [String: Task<CityPackLoadStatus, Never>] = [:]

    private func cachedStatus(for cityID: String) -> CityPackLoadStatus? {
        guard let status = loadStatuses[cityID] else { return nil }
        if let cooldownUntil = failedCooldownUntil[cityID], Date() >= cooldownUntil {
            return nil
        }
        return status
    }

    private func cacheStatus(_ status: CityPackLoadStatus, for cityID: String) {
        loadStatuses[cityID] = status
        failedCooldownUntil[cityID] = status == .failed ? Date().addingTimeInterval(Self.failureCooldown) : nil
    }

    init(session: URLSession = .shared, metroNetworks: MetroNetworkProviding) {
        self.session = session
        self.metroNetworks = metroNetworks
    }

    func cityPackStatuses(for cityIDs: [String]) async -> [String: CityPackLoadStatus] {
        var statuses: [String: CityPackLoadStatus] = [:]
        for cityID in Set(cityIDs) {
            statuses[cityID] = await cityPackStatus(for: cityID)
        }
        return statuses
    }

    private func cityPackStatus(for cityID: String) async -> CityPackLoadStatus {
        if let pack = packs[cityID] {
            return .loaded(version: pack.data.version)
        }
        if let status = cachedStatus(for: cityID) {
            return status
        }
        if let entry = bundledManifest()?.cities.first(where: { $0.cityID == cityID }) {
            return status(for: entry)
        }
        guard !Self.manifestURLs.isEmpty else { return .notConfigured }

        var foundManifest = false
        for manifestURL in Self.manifestURLs {
            do {
                let manifest = try await loadManifest(from: manifestURL)
                foundManifest = true
                guard let entry = manifest.cities.first(where: { $0.cityID == cityID }) else { continue }
                return status(for: entry)
            } catch {
                AppLog.data.warning("City pack manifest status failed for \(cityID, privacy: .public) via \(manifestURL.absoluteString, privacy: .public): \(error)")
                continue
            }
        }
        return foundManifest ? .notAvailable : .failed
    }

    private func status(for entry: OfficialManifestCity) -> CityPackLoadStatus {
        guard entry.hasDownload else {
            return entry.hasPendingData ? .sourcePending : .notAvailable
        }
        return .available(version: entry.version)
    }

    func loadCityPack(for cityID: String) async -> CityPackLoadStatus {
        if let pack = packs[cityID] {
            return .loaded(version: pack.data.version)
        }
        if let status = cachedStatus(for: cityID) {
            return status
        }
        // Coalesce concurrent requests for the same city so only one download runs at a time.
        // Actor re-entrancy at each await point would otherwise let multiple callers bypass the
        // packs/loadStatuses checks simultaneously and trigger redundant parallel downloads.
        if let existing = inFlightLoads[cityID] {
            return await existing.value
        }
        guard !Self.manifestURLs.isEmpty else { return .notConfigured }

        let task = Task { [self] in await self.performDownload(for: cityID) }
        inFlightLoads[cityID] = task
        let status = await task.value
        inFlightLoads.removeValue(forKey: cityID)
        cacheStatus(status, for: cityID)
        return status
    }

    private func performDownload(for cityID: String) async -> CityPackLoadStatus {
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
                return .loaded(version: decoded.version)
            } catch {
                AppLog.data.warning("City pack load failed for \(cityID, privacy: .public) via \(manifestURL.absoluteString, privacy: .public): \(error)")
                continue
            }
        }
        return pendingStatus ?? .failed
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
        let network = await metroNetworks.network(for: station.cityID)
        let bundledStation = network?.matchingStation(named: station.name, near: station.coordinate)
        let stationLineIDs = Set(
            station.uniqueLogicalLines.map(\.lineID) +
                (station.lines.isEmpty ? bundledStation?.lineIDs ?? [] : [])
        )
        let colorResolver = ScheduleLineColorResolver(network: network, stationLineIDs: stationLineIDs)
        return item.schedules.compactMap { schedule in
            guard let timeText = schedule.formattedTime else { return nil }
            return RealTimeArrival(
                id: UUID(),
                lineName: schedule.lineName,
                lineColorHex: colorResolver.colorHex(for: schedule.lineName),
                destination: schedule.direction,
                minutesRemaining: nil,
                timeText: timeText,
                source: .officialSchedule
            )
        }
    }

    func serviceWindows(cityID: String, stationName: String) async -> [StationServiceWindow] {
        _ = await loadCityPack(for: cityID)
        return stationRecord(cityID: cityID, stationName: stationName)?.schedules.map {
            StationServiceWindow(lineName: $0.lineName, direction: $0.direction, firstTime: $0.firstTime, lastTime: $0.lastTime)
        } ?? []
    }

    func crowdControlWindows(cityID: String, stationNames: [String]) async -> [ComfortStationWindows] {
        _ = await loadCityPack(for: cityID)
        var seen = Set<String>()
        var result: [ComfortStationWindows] = []
        for name in stationNames {
            let key = normalizedStationName(name)
            guard seen.insert(key).inserted else { continue }
            guard let windows = stationRecord(cityID: cityID, normalizedName: key)?.serviceStatus?.crowdControlWindows,
                  !windows.isEmpty else { continue }
            result.append(ComfortStationWindows(stationName: name, stationID: nil, windows: windows))
        }
        return result
    }

    func routeCoverage(cityID: String, stationNames: [String]) async -> RouteDataCoverage {
        _ = await loadCityPack(for: cityID)
        let names = Set(stationNames.map(normalizedStationName))
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
        let network = await metroNetworks.network(for: cityID)
        let station = network
            .flatMap { network in
                network.matchingStation(named: place.name, near: place.coordinate).map(network.displayStation)
            } ?? Station(
                stationID: "official-\(cityID)-\(normalizedStationName(place.name))",
                name: place.name,
                latitude: place.coordinate.latitude,
                longitude: place.coordinate.longitude,
                cityID: cityID
            )
        return enrichLoadedStation(station)
    }

    func stationGuidance(cityID: String, stationNames: [String]) async -> [String: StationAccessGuidance] {
        _ = await loadCityPack(for: cityID)
        var result: [String: StationAccessGuidance] = [:]
        for name in stationNames where result[name] == nil {
            guard let record = stationRecord(cityID: cityID, normalizedName: normalizedStationName(name)) else {
                result[name] = .empty
                continue
            }
            let platformHints = (record.platformHints ?? []).map(\.value)
            let interchangeHints = (record.interchangeHints ?? []).map(\.value)
            if let structured = record.stationAccessPoints, !structured.isEmpty {
                result[name] = StationAccessGuidance(
                    accessPoints: structured.map(\.value),
                    platformHints: platformHints,
                    interchangeHints: interchangeHints,
                    confidence: .official
                )
            } else {
                let extracted = Self.extractAccessPoints(from: record.accessibility)
                result[name] = StationAccessGuidance(
                    accessPoints: extracted,
                    platformHints: platformHints,
                    interchangeHints: interchangeHints,
                    confidence: extracted.isEmpty ? .unavailable : .estimated
                )
            }
        }
        return result
    }

    /// Best-effort exit/entrance extraction from accessibility free text (`.estimated` confidence).
    /// Surfaces letter/number tokens that precede a 口 / 出口 / 出入口 marker, e.g. "A口 C口" or
    /// "A、C口直梯" → exits A, C. Marks a point accessible when it also appears in the station's
    /// `accessibleEntrances` list. Returns [] when nothing parseable exists.
    nonisolated private static func extractAccessPoints(from accessibility: OfficialAccessibility?) -> [StationAccessPoint] {
        guard let accessibility else { return [] }
        let accessibleTokens = Set(exitTokens(in: accessibility.accessibleEntrances ?? []))
        let allText = (accessibility.accessibleEntrances ?? [])
            + (accessibility.elevatorLocations ?? [])
            + (accessibility.facilityNotes ?? [])
        var seen = Set<String>()
        var points: [StationAccessPoint] = []
        for token in exitTokens(in: allText) where seen.insert(token).inserted {
            points.append(StationAccessPoint(
                id: token,
                name: "\(token)口",
                kind: .exit,
                coordinate: nil,
                isAccessible: accessibleTokens.contains(token),
                notes: [],
                source: .inferred,
                confidence: .estimated
            ))
        }
        return points.sorted { $0.id < $1.id }
    }

    nonisolated private static func exitTokens(in strings: [String]) -> [String] {
        let separators = CharacterSet(charactersIn: "、，,/ \t")
        var result: [String] = []
        for string in strings {
            let ns = string as NSString
            for match in exitTokenExpression.matches(in: string, range: NSRange(location: 0, length: ns.length))
                where match.numberOfRanges > 1 {
                let run = ns.substring(with: match.range(at: 1))
                for part in run.components(separatedBy: separators) {
                    let token = part.uppercased()
                    if !token.isEmpty, token.count <= 3 { result.append(token) }
                }
            }
        }
        return result
    }

    private func loadManifest(from url: URL) async throws -> OfficialManifest {
        if let manifest = manifests[url] { return manifest }
        if let existing = inFlightManifests[url] {
            return try await existing.value
        }

        let task = Task { [self] in
            let data = try await download(from: url)
            return try JSONDecoder().decode(OfficialManifest.self, from: data)
        }
        inFlightManifests[url] = task

        let decoded: OfficialManifest
        do {
            decoded = try await task.value
        } catch {
            inFlightManifests.removeValue(forKey: url)
            throw error
        }
        inFlightManifests.removeValue(forKey: url)
        manifests[url] = decoded
        return decoded
    }

    private func bundledManifest() -> OfficialManifest? {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json") else { return nil }
        if let manifest = manifests[url] { return manifest }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(OfficialManifest.self, from: data) else { return nil }
        manifests[url] = decoded
        return decoded
    }

    private func download(from url: URL) async throws -> Data {
        // Cap how long a single fetch can sit with no response. URLSession's default is 60s,
        // and the pack CDNs are black-holed (stall, not refuse) on some mainland networks —
        // with several fallback URLs tried serially, a cold load could pin the city-pack
        // spinners for minutes before the .failed cooldown ever got a chance to cache.
        // This is an idle timeout, so a slow-but-flowing pack download is not cut off.
        let request = URLRequest(url: url, timeoutInterval: 15)
        let (data, response) = try await session.data(for: request)
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

    func releaseMemory() {
        packs.removeAll()
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

    var hasDownload: Bool {
        downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

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
    let stationID: String?
    let accessibility: OfficialAccessibility?
    let schedules: [OfficialSchedule]
    let stationMaps: [CityPackStationMap]
    let stationAssets: [CityPackStationAsset]
    let stationFacilities: [OfficialFacility]
    let serviceStatus: CityPackServiceStatus?
    // Optional, backward-compatible transit-guidance fields (absent in current packs).
    let stationAccessPoints: [OfficialAccessPoint]?
    let platformHints: [OfficialPlatformHint]?
    let interchangeHints: [OfficialInterchangeHint]?

    enum CodingKeys: String, CodingKey {
        case stationName, stationID, accessibility, schedules, stationMaps, stationAssets,
             stationFacilities, serviceStatus, stationAccessPoints, platformHints, interchangeHints
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stationName = try values.decode(String.self, forKey: .stationName)
        stationID = try values.decodeIfPresent(String.self, forKey: .stationID)
        accessibility = try values.decodeIfPresent(OfficialAccessibility.self, forKey: .accessibility)
        schedules = try values.decodeIfPresent([OfficialSchedule].self, forKey: .schedules) ?? []
        stationMaps = try values.decodeIfPresent([CityPackStationMap].self, forKey: .stationMaps) ?? []
        stationAssets = try values.decodeIfPresent([CityPackStationAsset].self, forKey: .stationAssets) ?? []
        stationFacilities = try values.decodeIfPresent([OfficialFacility].self, forKey: .stationFacilities) ?? []
        serviceStatus = try values.decodeIfPresent(CityPackServiceStatus.self, forKey: .serviceStatus)
        stationAccessPoints = try values.decodeIfPresent([OfficialAccessPoint].self, forKey: .stationAccessPoints)
        platformHints = try values.decodeIfPresent([OfficialPlatformHint].self, forKey: .platformHints)
        interchangeHints = try values.decodeIfPresent([OfficialInterchangeHint].self, forKey: .interchangeHints)
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
        return (explicit.isEmpty ? fallback : explicit).uniqued {
            "\($0.type.rawValue)|\($0.name)|\($0.locationText ?? "")"
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
            lastTime.map { "\(AppLocalization.localized("Last")) \($0)" }
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
            isFullyAccessible: hasElevator == true && hasWheelchairRamp == true ? true
                : hasElevator == false || hasWheelchairRamp == false ? false
                : nil,
            elevatorLocations: elevatorLocations,
            accessibleEntrances: accessibleEntrances,
            facilityNotes: facilityNotes,
            hasTactilePath: hasTactilePath
        )
    }
}

private struct OfficialAccessPoint: Decodable {
    let id: String?
    let name: String
    let kind: String?
    let latitude: Double?
    let longitude: Double?
    let isAccessible: Bool?
    let notes: [String]?
    let source: String?

    var value: StationAccessPoint {
        let coordinate = latitude.flatMap { lat in longitude.map { CodableCoordinate(latitude: lat, longitude: $0) } }
        return StationAccessPoint(
            id: id ?? name,
            name: name,
            kind: AccessPointKind(rawValue: kind ?? "") ?? .exit,
            coordinate: coordinate,
            isAccessible: isAccessible ?? false,
            notes: notes ?? [],
            source: RouteAccessPointSource(rawValue: source ?? "") ?? .specificEntrance,
            confidence: .official
        )
    }
}

private struct OfficialPlatformHint: Decodable {
    let lineName: String?
    let directionText: String?
    let boardingCarText: String?
    let doorSideText: String?
    let notes: [String]?

    var value: StationPlatformHint {
        StationPlatformHint(
            lineName: lineName,
            directionText: directionText,
            boardingCarText: boardingCarText,
            doorSideText: doorSideText,
            notes: notes ?? []
        )
    }
}

private struct OfficialInterchangeHint: Decodable {
    let fromLineName: String?
    let toLineName: String?
    let walkingMeters: Double?
    let walkingMinutes: Double?
    let notes: [String]?

    var value: StationInterchangeHint {
        StationInterchangeHint(
            fromLineName: fromLineName,
            toLineName: toLineName,
            walkingMeters: walkingMeters,
            walkingMinutes: walkingMinutes,
            notes: notes ?? []
        )
    }
}
