import Foundation
import CoreLocation
import CryptoKit

private func fetchJSON<T: Decodable>(
    _ type: T.Type,
    endpoint: String,
    queryItems: [URLQueryItem],
    urlSession: URLSession
) async throws -> T {
    guard var components = URLComponents(string: endpoint) else {
        throw RoutePlanningError.networkError
    }
    components.queryItems = queryItems

    guard let url = components.url else {
        throw RoutePlanningError.networkError
    }
    let (data, response) = try await urlSession.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw RoutePlanningError.networkError
    }

    return try JSONDecoder().decode(T.self, from: data)
}

private func amapQueryItems(_ items: [URLQueryItem]) -> [URLQueryItem] {
    [URLQueryItem(name: "key", value: AMapConfiguration.apiKey)] +
    items +
    [URLQueryItem(name: "output", value: "JSON")]
}

struct AMapResponseDiagnostic: Codable, Equatable {
    let endpoint: String
    let city: String?
    let queryType: String
    let status: String
    let info: String?
    let infocode: String?
    let itemCount: Int

    var developerSummary: String {
        [
            "endpoint=\(endpoint)",
            city.map { "city=\($0)" },
            "query=\(queryType)",
            "status=\(status)",
            info.map { "info=\($0)" },
            infocode.map { "infocode=\($0)" },
            "items=\(itemCount)"
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var userMessage: String {
        switch infocode {
        case "10001":
            return AppLocalization.localized("AMap key is invalid or expired")
        case "10002":
            return AppLocalization.localized("AMap service is unavailable for this key")
        case "10003", "10004", "10010", "10014", "10015", "10019", "10020", "10021", "10029":
            return AppLocalization.localized("AMap request limit reached")
        case "10005":
            return AppLocalization.localized("AMap key IP whitelist blocked this request")
        case "10007":
            return AppLocalization.localized("AMap key signature check failed")
        case "10009":
            return AppLocalization.localized("AMap key is not a Web Service key")
        case "10012":
            return AppLocalization.localized("AMap Bus Inquiry API is not enabled for this key")
        default:
            if status == "1" {
                return AppLocalization.localized("AMap returned no schedule for this line")
            }
            return AppLocalization.localized("AMap schedule lookup failed")
        }
    }
}

struct AccessibilityFilter {
    var requiresWheelchairAccess: Bool
    var requiresElevator: Bool
    var avoidStairs: Bool

    static var none: AccessibilityFilter {
        AccessibilityFilter(
            requiresWheelchairAccess: false,
            requiresElevator: false,
            avoidStairs: false
        )
    }
}

private enum AMapUsage {
    static let routeSearchEnabled = true
    static let geometryEnabled = true
    static let stationInfoEnabled = false
}

final class AMapService {
    private let localDataStore = SubwayDataStore()
    private let cityPackStore = CityPackStore()
    private let urlSession: URLSession
    private let lineOverlayDiskCache = LineOverlayDiskCache()
    private var lineOverlayCache: [String: [SubwayLineMapOverlay]] = [:]
    private var cityPackEnrichedCityIDs: Set<String> = []

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func searchStations(keyword: String, city: String) async throws -> [Station] {
        var stations = try await subwaySystem(for: city).stations
        let queryVariants = AppLocalization.searchVariants(for: keyword)

        guard !queryVariants.isEmpty else {
            return stations
        }

        if AMapUsage.routeSearchEnabled, AMapConfiguration.apiKey.isEmpty == false {
            let places = try await searchPlaces(keyword: keyword, city: city, limit: 20)
            let placeIDs = Set(places.compactMap(\.uid))
            let placeNames = places.flatMap { AppLocalization.searchVariants(for: $0.name) }
            stations = stations.filter { station in
                placeIDs.contains(station.stationID) ||
                station.poiIDs.contains { placeIDs.contains($0) } ||
                matches(station: station, queryVariants: queryVariants.union(placeNames))
            }
            if !stations.isEmpty {
                return stations
            }
        }

        return try await subwaySystem(for: city).stations.filter { station in
            matches(station: station, queryVariants: queryVariants)
        }
    }

    func searchStations(near location: CLLocationCoordinate2D, radius: Double) async throws -> [Station] {
        let nearbyStations = try await localDataStore.stations(near: location)
        let stations: [Station]
        if let nearbyStations {
            stations = nearbyStations
        } else {
            stations = try await subwaySystem(for: nil).stations
        }
        return stations
            .map { station in
                (station, station.coordinate.distance(to: location))
            }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    func getStationDetails(stationID: String, city: String) async throws -> Station {
        guard let station = try await subwaySystem(for: city).stations.first(where: { $0.stationID == stationID }) else {
            throw RoutePlanningError.stationNotFound
        }

        return station
    }

    func getStationExits(station: Station) async throws -> [StationExit] {
        guard AMapUsage.stationInfoEnabled else {
            return station.exits
        }

        guard AMapConfiguration.apiKey.isEmpty == false else {
            throw RoutePlanningError.amapAPIKeyMissing
        }

        let poiIDs = Array(station.poiIDs.filter(\.isLikelyAMapPOIID).prefix(10))
        var pois: [AMapPlacePOI] = []

        if !poiIDs.isEmpty {
            pois.append(contentsOf: try await amapPlaceDetails(ids: poiIDs))
        }

        pois.append(contentsOf: try await amapStationPOIsAround(station: station, keyword: station.name))
        pois.append(contentsOf: try await amapStationPOIsAround(station: station, keyword: "地铁出入口"))

        var exits = amapStationExits(from: pois, station: station)
        if exits.isEmpty {
            for keyword in station.amapEntranceSearchKeywords {
                pois.append(contentsOf: try await amapStationPOIs(keyword: keyword, city: station.cityID))
            }
            exits = amapStationExits(from: pois, station: station)
        }

        return exits
    }

    func planTransitRoute(
        from origin: TransitPlace,
        to destination: TransitPlace,
        city: String,
        accessibilityFilter: AccessibilityFilter?
    ) async throws -> [Route] {
        guard AMapUsage.routeSearchEnabled, AMapConfiguration.apiKey.isEmpty == false else {
            throw RoutePlanningError.amapAPIKeyMissing
        }

        let resolvedOrigin = try await resolvePlace(origin, city: city)
        let resolvedDestination = try await resolvePlace(destination, city: city)
        let filter = accessibilityFilter ?? .none

        if let v5Routes = try? await amapTransitRoutesV5(
            from: resolvedOrigin,
            to: resolvedDestination,
            city: city,
            filter: filter
        ), !v5Routes.isEmpty {
            return v5Routes
        }

        let fallbackRoutes = try await amapTransitRoutes(
            from: resolvedOrigin.routeCoordinate,
            to: resolvedDestination.routeCoordinate,
            originName: resolvedOrigin.name,
            destinationName: resolvedDestination.name,
            city: city,
            filter: filter
        )
        if !fallbackRoutes.isEmpty {
            return fallbackRoutes
        }

        throw RoutePlanningError.noRouteFound
    }

    func getTrainTimes(lineID: String, stationID: String) async throws -> [RealTimeArrival] {
        if let context = localDataStore.lineContext(lineID: lineID, stationID: stationID) {
            _ = try? await cityPackStore.ensurePack(cityID: context.system.cityID, urlSession: urlSession)
            let cityPackArrivals = await cityPackStore.officialArrivals(context: context)
            if !cityPackArrivals.isEmpty {
                return cityPackArrivals
            }
        }

        let fallbackCityID = localDataStore.lineContext(lineID: lineID, stationID: stationID)?.system.cityID
        let system = try await subwaySystem(for: fallbackCityID)
        let arrivals = localDataStore.arrivals(lineID: lineID, stationID: stationID, systemOverride: system)
        if !arrivals.isEmpty {
            return arrivals
        }

        throw RoutePlanningError.trainScheduleUnavailable
    }

    func loadCityPack(for cityID: String) async -> CityPackLoadStatus {
        do {
            return try await cityPackStore.ensurePack(cityID: cityID, urlSession: urlSession)
        } catch {
            return .failed
        }
    }

    func enrichStationFromCityPack(_ station: Station) async -> Station {
        guard let cityPackStation = await cityPackStore.station(cityID: station.cityID, stationName: station.name) else {
            return station
        }

        if let accessibilityData = cityPackStation.accessibilityData {
            let existingAccessibilityData: AccessibilityData? = station.accessibility?.accessibilityData
            let mergedData = existingAccessibilityData.merged(with: accessibilityData) ?? accessibilityData
            station.accessibility = StationAccessibility(stationID: station.stationID, data: mergedData)
        }
        station.facilities = cityPackStation.stationFacilities(for: station)

        return station
    }

    func stationMapFromCityPack(for station: Station) async -> CityPackStationMap? {
        await cityPackStore.stationMap(cityID: station.cityID, stationName: station.name)
    }

    func timetableAssetsFromCityPack(for station: Station) async -> [CityPackStationAsset] {
        await cityPackStore.stationAssets(cityID: station.cityID, stationName: station.name, category: "timetable_image")
    }

    func stationServiceStatusFromCityPack(for station: Station) async -> CityPackServiceStatus? {
        await cityPackStore.serviceStatus(cityID: station.cityID, stationName: station.name)
    }

    func getRealTimeArrivals(lineID: String, stationID: String) async throws -> [RealTimeArrival] {
        try await getTrainTimes(lineID: lineID, stationID: stationID)
    }

    func getSubwayLines(city: String) async throws -> [SubwayLineMapOverlay] {
        let system = try await subwaySystem(for: city)
        if let cached = lineOverlayCache[system.cityID] {
            return cached
        }

        if let persisted = try? lineOverlayDiskCache.load(cityID: system.cityID),
           !persisted.isEmpty {
            lineOverlayCache[system.cityID] = persisted
            return persisted
        }

        if AMapUsage.geometryEnabled,
           AMapConfiguration.apiKey.isEmpty == false,
           let liveOverlays = try? await amapLineOverlays(for: system) {
            if !liveOverlays.isEmpty {
                let displayOverlays = liveOverlays.map { $0.simplifiedForMap() }
                lineOverlayCache[system.cityID] = displayOverlays
                try? lineOverlayDiskCache.save(displayOverlays, cityID: system.cityID)
                return displayOverlays
            }
        }

        let fallback = system.lineOverlays.isEmpty ? stationSequenceLineOverlays(for: system) : system.lineOverlays
        let displayFallback = fallback.map { $0.simplifiedForMap() }
        lineOverlayCache[system.cityID] = displayFallback
        return displayFallback
    }

    func searchPlaces(keyword: String, city: String, limit: Int) async throws -> [TransitPlace] {
        guard AMapUsage.routeSearchEnabled, !AMapConfiguration.apiKey.isEmpty else {
            return try await searchFallbackPlaces(keyword: keyword, city: city, limit: limit)
        }

        let cityQuery = try await localDataStore.webCityQuery(for: city, urlSession: urlSession)
        let result: AMapPlaceTextResponse = try await fetchJSON(
            AMapPlaceTextResponse.self,
            endpoint: "https://restapi.amap.com/v3/place/text",
            queryItems: amapQueryItems([
            URLQueryItem(name: "keywords", value: keyword),
            URLQueryItem(name: "city", value: cityQuery),
            URLQueryItem(name: "citylimit", value: "true"),
            URLQueryItem(name: "children", value: "1"),
            URLQueryItem(name: "offset", value: "\(limit)"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "extensions", value: "all")
            ]),
            urlSession: urlSession
        )
        guard result.status == "1" else { return [] }
        return result.pois.compactMap { $0.transitPlace(source: .poiSearch) }
    }

    func inputTips(keyword: String, city: String, limit: Int) async throws -> [TransitPlace] {
        guard AMapUsage.routeSearchEnabled, !AMapConfiguration.apiKey.isEmpty else {
            return try await searchFallbackPlaces(keyword: keyword, city: city, limit: limit)
        }

        let cityQuery = try await localDataStore.webCityQuery(for: city, urlSession: urlSession)
        let result: AMapInputTipsResponse = try await fetchJSON(
            AMapInputTipsResponse.self,
            endpoint: "https://restapi.amap.com/v3/assistant/inputtips",
            queryItems: amapQueryItems([
            URLQueryItem(name: "keywords", value: keyword),
            URLQueryItem(name: "city", value: cityQuery),
            URLQueryItem(name: "citylimit", value: "true"),
            URLQueryItem(name: "datatype", value: "all")
            ]),
            urlSession: urlSession
        )
        guard result.status == "1" else { return [] }
        let places = result.tips.compactMap { tip -> TransitPlace? in
            guard !tip.name.isEmpty, let coordinate = tip.coordinate else { return nil }
            return TransitPlace(
                name: tip.name,
                coordinate: coordinate,
                uid: tip.id,
                type: tip.type,
                typeCode: tip.typecode,
                address: tip.address,
                cityCode: nil,
                adCode: tip.adcode,
                source: .inputTip
            )
        }
        if places.isEmpty {
            return try await searchPlaces(keyword: keyword, city: city, limit: limit)
        }
        return Array(places.prefix(limit))
    }

    private func resolvePlace(_ place: TransitPlace, city: String) async throws -> TransitPlace {
        if place.cityCode != nil && place.adCode != nil {
            return place
        }

        if let uid = place.uid,
           let detailedPlace = try await placeDetail(id: uid, city: city) {
            return detailedPlace
        }

        if let bestMatch = try await searchPlaces(keyword: place.name, city: city, limit: 8).first(where: { candidate in
            if let uid = place.uid, candidate.uid == uid {
                return true
            }
            return candidate.name == place.name || candidate.coordinate.distance(to: place.coordinate) < 80
        }) {
            return bestMatch
        }

        if let reverseGeocoded = try? await reverseGeocode(location: place.coordinate, name: place.name) {
            return TransitPlace(
                name: place.name,
                coordinate: place.coordinate,
                uid: place.uid,
                type: place.type,
                typeCode: place.typeCode,
                address: place.address ?? reverseGeocoded.address,
                cityCode: reverseGeocoded.cityCode,
                adCode: reverseGeocoded.adCode,
                naviPOIID: place.naviPOIID,
                entranceCoordinate: place.entranceCoordinate,
                source: place.source
            )
        }

        return place
    }

    func reverseGeocode(location: CLLocationCoordinate2D, name: String? = nil) async throws -> TransitPlace {
        guard AMapUsage.routeSearchEnabled, !AMapConfiguration.apiKey.isEmpty else {
            throw RoutePlanningError.amapAPIKeyMissing
        }

        let result: AMapRegeocodeResponse = try await fetchJSON(
            AMapRegeocodeResponse.self,
            endpoint: "https://restapi.amap.com/v3/geocode/regeo",
            queryItems: amapQueryItems([
            URLQueryItem(name: "location", value: "\(location.longitude),\(location.latitude)"),
            URLQueryItem(name: "extensions", value: "base"),
            URLQueryItem(name: "radius", value: "1000")
            ]),
            urlSession: urlSession
        )
        guard result.status == "1", let regeocode = result.regeocode else {
            throw RoutePlanningError.noRouteFound
        }

        return TransitPlace(
            name: name ?? AppLocalization.localized("Current Location"),
            coordinate: location,
            uid: nil,
            type: AppLocalization.localized("Current Location"),
            typeCode: nil,
            address: regeocode.formattedAddress,
            cityCode: regeocode.addressComponent.citycode,
            adCode: regeocode.addressComponent.adcode,
            source: .reverseGeocode
        )
    }

    private func placeDetail(id: String, city: String) async throws -> TransitPlace? {
        guard AMapUsage.routeSearchEnabled, !AMapConfiguration.apiKey.isEmpty else {
            return nil
        }

        let cityQuery = try await localDataStore.webCityQuery(for: city, urlSession: urlSession)
        let result: AMapPlaceTextResponse = try await fetchJSON(
            AMapPlaceTextResponse.self,
            endpoint: "https://restapi.amap.com/v3/place/detail",
            queryItems: amapQueryItems([
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "city", value: cityQuery),
            URLQueryItem(name: "extensions", value: "all")
            ]),
            urlSession: urlSession
        )
        guard result.status == "1", let poi = result.pois.first else {
            return nil
        }

        return poi.transitPlace(source: .poiSearch)
    }

    private func amapPlaceDetails(ids: [String]) async throws -> [AMapPlacePOI] {
        var pois: [AMapPlacePOI] = []
        for id in ids {
            let result: AMapPlaceTextResponse = try await fetchJSON(
                AMapPlaceTextResponse.self,
                endpoint: "https://restapi.amap.com/v5/place/detail",
                queryItems: amapQueryItems([
                    URLQueryItem(name: "id", value: id),
                    URLQueryItem(name: "show_fields", value: "children,navi")
                ]),
                urlSession: urlSession
            )

            if result.status == "1" {
                pois.append(contentsOf: result.pois)
            }
        }

        return pois
    }

    private func amapStationPOIs(keyword: String, city: String) async throws -> [AMapPlacePOI] {
        let cityQuery = try await localDataStore.webCityQuery(for: city, urlSession: urlSession)
        let result: AMapPlaceTextResponse = try await fetchJSON(
            AMapPlaceTextResponse.self,
            endpoint: "https://restapi.amap.com/v5/place/text",
            queryItems: amapQueryItems([
                URLQueryItem(name: "keywords", value: keyword),
                URLQueryItem(name: "region", value: cityQuery),
                URLQueryItem(name: "city_limit", value: "true"),
                URLQueryItem(name: "show_fields", value: "children,navi")
            ]),
            urlSession: urlSession
        )

        guard result.status == "1" else {
            return []
        }

        return result.pois
    }

    private func amapStationPOIsAround(station: Station, keyword: String) async throws -> [AMapPlacePOI] {
        let result: AMapPlaceTextResponse = try await fetchJSON(
            AMapPlaceTextResponse.self,
            endpoint: "https://restapi.amap.com/v5/place/around",
            queryItems: amapQueryItems([
                URLQueryItem(name: "keywords", value: keyword),
                URLQueryItem(name: "location", value: "\(station.longitude),\(station.latitude)"),
                URLQueryItem(name: "radius", value: "650"),
                URLQueryItem(name: "show_fields", value: "children,navi")
            ]),
            urlSession: urlSession
        )

        guard result.status == "1" else {
            return []
        }

        return result.pois
    }

    private func amapStationExits(from pois: [AMapPlacePOI], station: Station) -> [StationExit] {
        var exitsByKey: [String: StationExit] = [:]
        var genericNavigationExitsByKey: [String: StationExit] = [:]

        func appendExit(
            id: String?,
            name: String,
            coordinate: CLLocationCoordinate2D?,
            source: String,
            to storage: inout [String: StationExit]
        ) {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedName.isEmpty == false else { return }
            let coordinateKey = coordinate.map {
                String(format: "%.5f,%.5f", $0.latitude, $0.longitude)
            }
            let key = [id, normalizedName, coordinateKey]
                .compactMap { $0 }
                .joined(separator: "|")
            guard storage[key] == nil else { return }
            let accessibilityHints = AMapExitAccessibilityHints(text: normalizedName)

            storage[key] = StationExit(
                exitID: id ?? "\(station.stationID)-amap-\(storage.count)",
                stationID: station.stationID,
                name: normalizedName,
                hasElevator: accessibilityHints.hasElevator,
                hasEscalator: accessibilityHints.hasEscalator,
                hasWheelchairRamp: accessibilityHints.hasWheelchairRamp,
                isAccessible: accessibilityHints.isAccessible,
                nearbyLandmarks: [source],
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude
            )
        }

        for poi in pois {
            if poi.isSubwayEntranceOrExit,
               poi.coordinate?.distance(to: station.coordinate) ?? 0 < 900 {
                appendExit(
                    id: poi.id,
                    name: poi.name,
                    coordinate: poi.coordinate ?? poi.entranceCoordinate ?? poi.exitCoordinate,
                    source: AppLocalization.localized("AMap entrance/exit"),
                    to: &exitsByKey
                )
            }

            for child in poi.children where child.isSubwayEntranceOrExit {
                let coordinate = child.coordinate ?? child.entranceCoordinate ?? child.exitCoordinate
                if let coordinate, coordinate.distance(to: station.coordinate) > 900 {
                    continue
                }
                appendExit(
                    id: child.id,
                    name: child.name,
                    coordinate: coordinate,
                    source: AppLocalization.localized("AMap entrance/exit"),
                    to: &exitsByKey
                )
            }

            if let entranceCoordinate = poi.entranceCoordinate {
                appendExit(
                    id: nil,
                    name: AppLocalization.localized("AMap entrance/exit"),
                    coordinate: entranceCoordinate,
                    source: AppLocalization.localized("AMap navigation point"),
                    to: &genericNavigationExitsByKey
                )
            }

            if let exitCoordinate = poi.exitCoordinate {
                appendExit(
                    id: nil,
                    name: AppLocalization.localized("AMap entrance/exit"),
                    coordinate: exitCoordinate,
                    source: AppLocalization.localized("AMap navigation point"),
                    to: &genericNavigationExitsByKey
                )
            }
        }

        let exits = exitsByKey.isEmpty
            ? Array(genericNavigationExitsByKey.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }.prefix(2))
            : Array(exitsByKey.values)
        let hasSpecificExits = exits.contains { $0.isSpecificAMapExitName(for: station.name) }
        let filteredExits = hasSpecificExits
            ? exits.filter { $0.isSpecificAMapExitName(for: station.name) }
            : exits

        return filteredExits.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func searchFallbackPlaces(keyword: String, city: String, limit: Int) async throws -> [TransitPlace] {
        let variants = AppLocalization.searchVariants(for: keyword)
        guard !variants.isEmpty else { return [] }
        return try await subwaySystem(for: city).stations
            .filter { matches(station: $0, queryVariants: variants) }
            .prefix(limit)
            .map {
                TransitPlace(
                    name: $0.localizedName,
                    coordinate: $0.coordinate,
                    uid: $0.stationID,
                    type: AppLocalization.localized("Subway"),
                    typeCode: "150500",
                    address: nil,
                    source: .localStationData
                )
            }
    }

    func getTransitCities() async throws -> [City] {
        try await localDataStore.transitCities(urlSession: urlSession)
    }

    private func subwaySystem(for city: String?) async throws -> LoadedSubwaySystem {
        let system = try await localDataStore.system(for: city, urlSession: urlSession)
        return await systemEnrichedWithCityPack(system)
    }

    private func systemEnrichedWithCityPack(_ system: LoadedSubwaySystem) async -> LoadedSubwaySystem {
        guard !cityPackEnrichedCityIDs.contains(system.cityID) else {
            return system
        }

        let loadStatus = try? await cityPackStore.ensurePack(cityID: system.cityID, urlSession: urlSession)

        for station in system.stations {
            guard let cityPackStation = await cityPackStore.station(cityID: station.cityID, stationName: station.name) else {
                continue
            }

            if let accessibilityData = cityPackStation.accessibilityData {
                let existingAccessibilityData: AccessibilityData? = station.accessibility?.accessibilityData
                let mergedData = existingAccessibilityData.merged(with: accessibilityData) ?? accessibilityData
                station.accessibility = StationAccessibility(stationID: station.stationID, data: mergedData)
            }
            station.facilities = cityPackStation.stationFacilities(for: station)
        }

        if loadStatus != nil {
            cityPackEnrichedCityIDs.insert(system.cityID)
        }
        return system
    }

    private func matches(station: Station, queryVariants: Set<String>) -> Bool {
        let lineNames = station.lines.map { $0.name }.joined(separator: " ")
        let lineEnglishNames = station.lines.compactMap { $0.nameEn }.joined(separator: " ")
        let searchableFields = [
            station.name,
            AppLocalization.chinese(station.name),
            station.nameEn,
            station.namePinyin,
            station.stationID,
            lineNames,
            lineEnglishNames
        ].compactMap { $0 }

        return searchableFields.contains { field in
            let variants = AppLocalization.searchVariants(for: field)
            return queryVariants.contains { query in
                variants.contains { $0.contains(query) || query.contains($0) }
            }
        }
    }

    private func amapTransitRoutesV5(
        from origin: TransitPlace,
        to destination: TransitPlace,
        city: String,
        filter: AccessibilityFilter
    ) async throws -> [Route] {
        let system = try await subwaySystem(for: city)
        let cityQuery = try await localDataStore.webCityQuery(for: city, urlSession: urlSession)
        let requests = [RouteStrategy.metroFirst, .fastest, .leastWalking].map { strategy in
            var queryItems = [
                URLQueryItem(name: "origin", value: "\(origin.routeCoordinate.longitude),\(origin.routeCoordinate.latitude)"),
                URLQueryItem(name: "destination", value: "\(destination.routeCoordinate.longitude),\(destination.routeCoordinate.latitude)"),
                URLQueryItem(name: "city1", value: origin.cityCode ?? cityQuery),
                URLQueryItem(name: "city2", value: destination.cityCode ?? cityQuery),
                URLQueryItem(name: "strategy", value: strategy.amapV5StrategyValue),
                URLQueryItem(name: "AlternativeRoute", value: "5"),
                URLQueryItem(name: "alternative_route", value: "5"),
                URLQueryItem(name: "multiexport", value: "1"),
                URLQueryItem(name: "nightflag", value: "1"),
                URLQueryItem(name: "show_fields", value: "cost,navi,polyline")
            ]

            if let adCode = origin.adCode {
                queryItems.append(URLQueryItem(name: "ad1", value: adCode))
            }
            if let adCode = destination.adCode {
                queryItems.append(URLQueryItem(name: "ad2", value: adCode))
            }
            if let originPOI = origin.routePOIID {
                queryItems.append(URLQueryItem(name: "originpoi", value: originPOI))
            }
            if let destinationPOI = destination.routePOIID {
                queryItems.append(URLQueryItem(name: "destinationpoi", value: destinationPOI))
            }

            return TransitRouteRequest(strategy: strategy, queryItems: queryItems)
        }

        return try await transitRoutes(
            endpoint: "https://restapi.amap.com/v5/direction/transit/integrated",
            requests: requests,
            originName: origin.name,
            destinationName: destination.name,
            system: system,
            filter: filter
        )
    }

    private func amapTransitRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        originName: String,
        destinationName: String,
        city: String,
        filter: AccessibilityFilter
    ) async throws -> [Route] {
        let system = try await subwaySystem(for: city)
        let cityQuery = try await localDataStore.webCityQuery(for: city, urlSession: urlSession)
        let requests = [RouteStrategy.fastest, .leastWalking].map { strategy in
            TransitRouteRequest(strategy: strategy, queryItems: [
                URLQueryItem(name: "origin", value: "\(origin.longitude),\(origin.latitude)"),
                URLQueryItem(name: "destination", value: "\(destination.longitude),\(destination.latitude)"),
                URLQueryItem(name: "city", value: cityQuery),
                URLQueryItem(name: "cityd", value: cityQuery),
                URLQueryItem(name: "strategy", value: strategy.amapV3StrategyValue),
                URLQueryItem(name: "nightflag", value: "1"),
                URLQueryItem(name: "extensions", value: "all")
            ])
        }

        return try await transitRoutes(
            endpoint: "https://restapi.amap.com/v3/direction/transit/integrated",
            requests: requests,
            originName: originName,
            destinationName: destinationName,
            system: system,
            filter: filter
        )
    }

    private struct TransitRouteRequest {
        let strategy: RouteStrategy
        let queryItems: [URLQueryItem]
    }

    private func transitRoutes(
        endpoint: String,
        requests: [TransitRouteRequest],
        originName: String,
        destinationName: String,
        system: LoadedSubwaySystem,
        filter: AccessibilityFilter
    ) async throws -> [Route] {
        var routes: [Route] = []

        for request in requests {
            let payload: AMapTransitResponse = try await fetchJSON(
                AMapTransitResponse.self,
                endpoint: endpoint,
                queryItems: amapQueryItems(request.queryItems),
                urlSession: urlSession
            )
            guard payload.status == "1" else { continue }
            for transit in payload.route?.transits ?? [] {
                if let route = await route(
                    from: transit,
                    strategy: request.strategy,
                    originName: originName,
                    destinationName: destinationName,
                    system: system,
                    filter: filter
                ) {
                    routes.append(route)
                }
            }
        }

        return uniqueRoutes(routes)
    }

    private func uniqueRoutes(_ routes: [Route]) -> [Route] {
        var bestRoutesByKey: [String: Route] = [:]
        var orderedKeys: [String] = []

        for route in routes {
            let key = route.deduplicationKey
            if let existing = bestRoutesByKey[key] {
                if route.isBetterDuplicate(than: existing) {
                    bestRoutesByKey[key] = route
                }
            } else {
                bestRoutesByKey[key] = route
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { bestRoutesByKey[$0] }
    }

    private func amapLineOverlays(for system: LoadedSubwaySystem) async throws -> [SubwayLineMapOverlay] {
        guard let subwaySystem = system.system else { return [] }
        let cityQuery = try await localDataStore.webCityQuery(for: system.cityID, urlSession: urlSession)
        var overlays: [SubwayLineMapOverlay] = []

        for line in subwaySystem.lines {
            let liveLineOverlays = try await amapLineOverlays(for: line, cityQuery: cityQuery)
            overlays.append(contentsOf: liveLineOverlays)
        }

        return overlays
    }

    private func amapLineOverlays(for line: SubwayLineData, cityQuery: String) async throws -> [SubwayLineMapOverlay] {
        var seenIDs: Set<String> = []
        var overlays: [SubwayLineMapOverlay] = []

        for lineID in line.amapLineIDs ?? [] {
            let busLines = try await amapBusLines(endpoint: "lineid", queryName: "id", queryValue: lineID, cityQuery: cityQuery)
            overlays.append(contentsOf: busLines.compactMap { overlay(from: $0, fallback: line, seenIDs: &seenIDs) })
        }

        if overlays.isEmpty {
            let busLines = try await amapBusLines(endpoint: "linename", queryName: "keywords", queryValue: line.name, cityQuery: cityQuery)
            overlays.append(contentsOf: busLines.compactMap { overlay(from: $0, fallback: line, seenIDs: &seenIDs) })
        }

        return overlays
    }

    private func amapBusLines(endpoint: String, queryName: String, queryValue: String, cityQuery: String) async throws -> [AMapBusLineDetail] {
        let payload: AMapBusLineResponse = try await fetchJSON(
            AMapBusLineResponse.self,
            endpoint: "https://restapi.amap.com/v3/bus/\(endpoint)",
            queryItems: amapQueryItems([
            URLQueryItem(name: queryName, value: queryValue),
            URLQueryItem(name: "city", value: cityQuery),
            URLQueryItem(name: "extensions", value: "all")
            ]),
            urlSession: urlSession
        )
        let diagnostic = AMapResponseDiagnostic(
            endpoint: "v3/bus/\(endpoint)",
            city: cityQuery,
            queryType: "\(queryName)=\(queryValue)",
            status: payload.status,
            info: payload.info,
            infocode: payload.infocode,
            itemCount: payload.buslines.count
        )
        debugPrint("[AMap] \(diagnostic.developerSummary)")
        guard payload.status == "1" else {
            throw RoutePlanningError.amapServiceDiagnostic(diagnostic)
        }
        return payload.buslines
    }

    private func overlay(
        from busLine: AMapBusLineDetail,
        fallback line: SubwayLineData,
        seenIDs: inout Set<String>
    ) -> SubwayLineMapOverlay? {
        let coordinates = closedLoopCoordinatesIfNeeded(busLine.routeCoordinates, for: line)
        guard coordinates.count >= 2 else { return nil }
        let id = busLine.id ?? "\(line.lineID)-\(seenIDs.count)"
        guard !seenIDs.contains(id) else { return nil }
        seenIDs.insert(id)

        return SubwayLineMapOverlay(
            id: id,
            name: busLine.displayName ?? line.localizedName,
            colorHex: line.colorHex,
            coordinates: coordinates
        )
    }

    private func stationSequenceLineOverlays(for system: LoadedSubwaySystem) -> [SubwayLineMapOverlay] {
        guard let subwaySystem = system.system else { return [] }
        let stationsByID = Dictionary(uniqueKeysWithValues: system.stations.map { ($0.stationID, $0) })

        return subwaySystem.lines.compactMap { line in
            let coordinates = line.stationIDs.compactMap { stationID -> CodableCoordinate? in
                guard let station = stationsByID[stationID] else { return nil }
                return CodableCoordinate(latitude: station.latitude, longitude: station.longitude)
            }
            let displayCoordinates = closedLoopCoordinatesIfNeeded(coordinates, for: line)
            guard displayCoordinates.count >= 2 else { return nil }
            return SubwayLineMapOverlay(
                id: line.lineID,
                name: line.localizedName,
                colorHex: line.colorHex,
                coordinates: displayCoordinates
            )
        }
    }

    private func closedLoopCoordinatesIfNeeded(
        _ coordinates: [CodableCoordinate],
        for line: SubwayLineData
    ) -> [CodableCoordinate] {
        guard coordinates.count >= 8,
              let first = coordinates.first,
              let last = coordinates.last else {
            return coordinates
        }

        let firstCoordinate = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
        let lastCoordinate = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
        let endpointDistance = firstCoordinate.distance(to: lastCoordinate)
        guard endpointDistance > 1 else { return coordinates }

        let adjacentDistances = zip(coordinates, coordinates.dropFirst())
            .map { current, next in
                CLLocationCoordinate2D(latitude: current.latitude, longitude: current.longitude)
                    .distance(to: CLLocationCoordinate2D(latitude: next.latitude, longitude: next.longitude))
            }
            .filter { $0 > 1 }
            .sorted()
        guard !adjacentDistances.isEmpty else { return coordinates }

        let medianAdjacentDistance = adjacentDistances[adjacentDistances.count / 2]
        let loopNameHint = line.name.localizedCaseInsensitiveContains("环") ||
            line.name.localizedCaseInsensitiveContains("loop") ||
            line.nameEn?.localizedCaseInsensitiveContains("loop") == true
        let maxClosureDistance = loopNameHint ? 5_000 : min(2_800, max(1_200, medianAdjacentDistance * 2.2))
        guard endpointDistance <= maxClosureDistance else { return coordinates }

        return coordinates + [first]
    }

    private func route(
        from transit: AMapTransitPlan,
        strategy: RouteStrategy,
        originName: String,
        destinationName: String,
        system: LoadedSubwaySystem,
        filter: AccessibilityFilter
    ) async -> Route? {
        var segments: [RouteSegment] = []
        var routeStops: [RouteStationStop] = []
        var transferCount = 0

        for segment in transit.segments {
            if let walking = segment.walking, walking.distanceValue > 0 {
                let steps = walking.steps.map {
                    WalkingStep(
                        instruction: $0.instruction ?? AppLocalization.localized("Walk"),
                        distance: $0.distanceValue,
                        duration: $0.durationValue,
                        isAccessible: !$0.hasStairs,
                        road: $0.road,
                        action: $0.action,
                        assistantAction: $0.assistantAction,
                        walkType: $0.walkType
                    )
                }
                guard shouldDisplayWalkingSegment(distance: walking.distanceValue, duration: walking.durationValue, steps: steps) else {
                    continue
                }
                segments.append(RouteSegment(
                    id: UUID(),
                    type: .walking,
                    lineName: nil,
                    lineColorHex: "#8E8E93",
                    fromStationName: nil,
                    toStationName: nil,
                    fromStationID: nil,
                    toStationID: nil,
                    duration: walking.durationValue,
                    distance: walking.distanceValue,
                    stops: 0,
                    stationStops: [],
                    polylineCoordinates: walking.routeCoordinates,
                    walkingDirections: steps,
                    accessibilityNotes: walkingAccessibilityNotes(from: steps, filter: filter)
                ))
            }

            for line in segment.bus?.buslines ?? [] {
                let stops = stationStops(from: line, system: system)
                if routeStops.isEmpty {
                    routeStops = stops
                } else {
                    for stop in stops where routeStops.last?.stationID != stop.stationID {
                        routeStops.append(stop)
                    }
                }
                if segments.contains(where: { $0.type == .subway }) {
                    transferCount += 1
                }
                segments.append(RouteSegment(
                    id: UUID(),
                    type: .subway,
                    lineName: line.displayName,
                    lineColorHex: line.colorHex ?? "#007AFF",
                    fromStationName: line.departureStop.name,
                    toStationName: line.arrivalStop.name,
                    fromStationID: line.departureStop.id,
                    toStationID: line.arrivalStop.id,
                    duration: line.durationValue,
                    distance: line.distanceValue,
                    stops: line.viaNumValue + 1,
                    stationStops: stops,
                    polylineCoordinates: line.routeCoordinates,
                    walkingDirections: nil,
                    accessibilityNotes: []
                ))
            }
        }

        guard !segments.isEmpty else { return nil }
        let segmentsWithPlaceNames = annotateWalkingSegments(
            segments,
            originName: originName,
            destinationName: destinationName,
            routeStops: routeStops
        )
        let firstStationID = routeStops.first?.stationID ?? originName
        let lastStationID = routeStops.last?.stationID ?? destinationName
        let totalStops = segments.filter { $0.type == .subway }.reduce(0) { $0 + $1.stops }
        let fullyAccessible = routeStops.allSatisfy { stop in
            system.stations.first(where: { $0.stationID == stop.stationID })?.accessibility?.isFullyAccessible == true
        }
        let accessGuidance = buildAccessGuidance(
            originName: originName,
            destinationName: destinationName,
            routeStops: routeStops,
            segments: segmentsWithPlaceNames,
            system: system,
            filter: filter
        )
        let warnings = routeWarnings(
            from: segmentsWithPlaceNames,
            accessGuidance: accessGuidance,
            walkingDistance: transit.walkingDistanceValue,
            fullyAccessible: fullyAccessible,
            filter: filter
        )

        let dataCoverage = await cityPackStore.routeCoverage(
            cityID: system.cityID,
            stationNames: routeStops.map(\.name)
        )

        return Route(
            id: UUID(),
            origin: originName,
            destination: destinationName,
            originStationID: firstStationID,
            destinationStationID: lastStationID,
            strategy: strategy,
            segments: segmentsWithPlaceNames,
            totalDuration: transit.durationValue,
            walkingDistance: transit.walkingDistanceValue,
            totalStops: totalStops,
            transferCount: transferCount,
            accessibilityScore: fullyAccessible ? 1.0 : 0.65,
            isFullyAccessible: fullyAccessible,
            warnings: warnings,
            accessGuidance: accessGuidance,
            dataCoverage: dataCoverage
        )
    }

    private func annotateWalkingSegments(
        _ segments: [RouteSegment],
        originName: String,
        destinationName: String,
        routeStops: [RouteStationStop]
    ) -> [RouteSegment] {
        guard !segments.isEmpty else { return segments }
        let firstSubwayIndex = segments.firstIndex { $0.type == .subway }
        let lastSubwayIndex = segments.lastIndex { $0.type == .subway }

        return segments.enumerated().map { index, segment in
            guard segment.type == .walking else { return segment }

            let previousSubway = segments[..<index].last { $0.type == .subway }
            let nextSubway = segments.dropFirst(index + 1).first { $0.type == .subway }

            let fromName: String?
            let toName: String?
            let fromID: String?
            let toID: String?

            if let firstSubwayIndex, index < firstSubwayIndex {
                fromName = originName
                toName = nextSubway?.fromStationName ?? routeStops.first?.name
                fromID = nil
                toID = nextSubway?.fromStationID ?? routeStops.first?.stationID
            } else if let lastSubwayIndex, index > lastSubwayIndex {
                fromName = previousSubway?.toStationName ?? routeStops.last?.name
                toName = destinationName
                fromID = previousSubway?.toStationID ?? routeStops.last?.stationID
                toID = nil
            } else {
                fromName = previousSubway?.toStationName
                toName = nextSubway?.fromStationName
                fromID = previousSubway?.toStationID
                toID = nextSubway?.fromStationID
            }

            return RouteSegment(
                id: segment.id,
                type: segment.type,
                lineName: segment.lineName,
                lineColorHex: segment.lineColorHex,
                fromStationName: fromName,
                toStationName: toName,
                fromStationID: fromID,
                toStationID: toID,
                duration: segment.duration,
                distance: segment.distance,
                stops: segment.stops,
                stationStops: segment.stationStops,
                polylineCoordinates: segment.polylineCoordinates,
                walkingDirections: segment.walkingDirections,
                accessibilityNotes: segment.accessibilityNotes
            )
        }
    }

    private func buildAccessGuidance(
        originName: String,
        destinationName: String,
        routeStops: [RouteStationStop],
        segments: [RouteSegment],
        system: LoadedSubwaySystem,
        filter: AccessibilityFilter
    ) -> [RouteAccessGuide] {
        guard !routeStops.isEmpty else { return [] }

        let firstSubwayIndex = segments.firstIndex { $0.type == .subway }
        let lastSubwayIndex = segments.lastIndex { $0.type == .subway }
        let originWalkingSegment = firstSubwayIndex.flatMap { index in
            segments[..<index].last { $0.type == .walking }
        }
        let destinationWalkingSegment = lastSubwayIndex.flatMap { index in
            segments.dropFirst(index + 1).first { $0.type == .walking }
        }

        var guides: [RouteAccessGuide] = []
        if let firstStop = routeStops.first {
            let station = station(for: firstStop, system: system)
            let accessPoint = preferredAccessPoint(for: station, fallbackStop: firstStop, kind: .origin, filter: filter)
            let steps = originWalkingSegment?.walkingDirections ?? []
            guides.append(RouteAccessGuide(
                id: UUID(),
                kind: .origin,
                placeName: originName,
                stationName: firstStop.name,
                accessPoint: accessPoint,
                walkingDistance: originWalkingSegment?.distance ?? 0,
                walkingDuration: originWalkingSegment?.duration ?? 0,
                walkingSteps: steps,
                accessibilityNotes: accessNotes(for: station, accessPoint: accessPoint, steps: steps, filter: filter)
            ))
        }

        if let lastStop = routeStops.last {
            let station = station(for: lastStop, system: system)
            let accessPoint = preferredAccessPoint(for: station, fallbackStop: lastStop, kind: .destination, filter: filter)
            let steps = destinationWalkingSegment?.walkingDirections ?? []
            guides.append(RouteAccessGuide(
                id: UUID(),
                kind: .destination,
                placeName: destinationName,
                stationName: lastStop.name,
                accessPoint: accessPoint,
                walkingDistance: destinationWalkingSegment?.distance ?? 0,
                walkingDuration: destinationWalkingSegment?.duration ?? 0,
                walkingSteps: steps,
                accessibilityNotes: accessNotes(for: station, accessPoint: accessPoint, steps: steps, filter: filter)
            ))
        }

        return guides
    }

    private func routeWarnings(
        from segments: [RouteSegment],
        accessGuidance: [RouteAccessGuide],
        walkingDistance: Double,
        fullyAccessible: Bool,
        filter: AccessibilityFilter
    ) -> [RouteWarning] {
        let walkingSteps = segments.flatMap { $0.walkingDirections ?? [] }
        var warnings: [RouteWarning] = []

        if filter.avoidStairs && walkingSteps.contains(where: \.hasBarrierRisk) {
            warnings.append(RouteWarning(
                type: .stairsDetected,
                message: walkingSteps.contains(where: \.hasStairs)
                    ? AppLocalization.localized("Stairs detected from AMap walking directions")
                    : AppLocalization.localized("Stairs may be present"),
                affectedStationID: nil
            ))
        }

        if (filter.requiresWheelchairAccess || filter.requiresElevator) && !fullyAccessible {
            let missingStationData = accessGuidance.contains { guide in
                guide.accessibilityNotes.contains(AppLocalization.localized("Step-free access not confirmed because station accessibility data is missing"))
            }
            warnings.append(RouteWarning(
                type: .stepFreeAccessUnconfirmed,
                message: missingStationData
                    ? AppLocalization.localized("Step-free access not confirmed because station accessibility data is missing")
                    : AppLocalization.localized("Step-free access not confirmed from station data"),
                affectedStationID: nil
            ))
        }

        if walkingDistance > 900 {
            warnings.append(RouteWarning(
                type: .longWalk,
                message: AppLocalization.localized("Long walking segment"),
                affectedStationID: nil
            ))
        }

        return warnings
    }

    private func walkingAccessibilityNotes(from steps: [WalkingStep], filter: AccessibilityFilter) -> [String] {
        var notes: [String] = []

        if steps.contains(where: \.hasStairs) {
            notes.append(AppLocalization.localized("Stairs detected from AMap walking directions"))
        } else if filter.avoidStairs && steps.contains(where: \.hasBarrierRisk) {
            notes.append(AppLocalization.localized("Check for step-free path before walking"))
        }

        if steps.contains(where: \.hasElevator) {
            notes.append(AppLocalization.localized("Elevator indicated by AMap walking directions"))
        }

        if steps.contains(where: \.hasRamp) {
            notes.append(AppLocalization.localized("Ramp indicated by AMap walking directions"))
        }

        if steps.contains(where: \.hasEscalator) {
            notes.append(AppLocalization.localized("Escalator indicated by AMap walking directions"))
        }

        var seen: Set<String> = []
        return notes.filter { seen.insert($0).inserted }
    }

    private func shouldDisplayWalkingSegment(distance: Double, duration: TimeInterval, steps: [WalkingStep]) -> Bool {
        if distance >= 10 || duration >= 60 {
            return true
        }
        return steps.contains { step in
            step.hasStairs ||
                step.hasRamp ||
                step.hasElevator ||
                step.hasEscalator ||
                step.hasOverpass ||
                step.hasUnderpass
        }
    }

    private func station(for stop: RouteStationStop, system: LoadedSubwaySystem) -> Station? {
        if let station = system.stations.first(where: { $0.stationID == stop.stationID }) {
            return station
        }

        let stopVariants = AppLocalization.searchVariants(for: stop.name)
        if let nameMatch = system.stations.first(where: { station in
            let stationVariants = AppLocalization.searchVariants(for: station.name)
                .union(AppLocalization.searchVariants(for: station.nameEn ?? ""))
                .union(AppLocalization.searchVariants(for: station.namePinyin ?? ""))
            return stopVariants.contains { stopVariant in
                stationVariants.contains { stationVariant in
                    stationVariant.contains(stopVariant) || stopVariant.contains(stationVariant)
                }
            }
        }) {
            return nameMatch
        }

        guard let coordinate = stop.coordinate else { return nil }
        return system.stations
            .map { station in
                let distance = station.coordinate.distance(
                    to: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                )
                return (station, distance)
            }
            .filter { $0.1 <= 900 }
            .sorted { $0.1 < $1.1 }
            .first?
            .0
    }

    private func preferredAccessPoint(
        for station: Station?,
        fallbackStop: RouteStationStop,
        kind: RouteAccessKind,
        filter: AccessibilityFilter
    ) -> RouteAccessPoint {
        if let station {
            let exits = station.exits.sorted { $0.name < $1.name }
            if let exit = exits.first(where: { exit in
                if filter.requiresWheelchairAccess || filter.requiresElevator || filter.avoidStairs {
                    return exit.isAccessible || exit.hasElevator || exit.hasWheelchairRamp
                }
                return true
            }) ?? exits.first {
                return RouteAccessPoint(
                    id: exit.exitID,
                    name: exit.localizedName,
                    coordinate: nil,
                    isWheelchairLikely: exit.isAccessible || exit.hasWheelchairRamp,
                    hasElevatorHint: exit.hasElevator,
                    source: .localStationData
                )
            }

            if let entrance = station.accessibility?.accessibleEntrances.first {
                return RouteAccessPoint(
                    id: "\(station.stationID)-accessible-entrance",
                    name: AppLocalization.chinese(entrance),
                    coordinate: CodableCoordinate(latitude: station.latitude, longitude: station.longitude),
                    isWheelchairLikely: true,
                    hasElevatorHint: station.accessibility?.hasElevator == true,
                    source: .localStationData
                )
            }

            if let elevator = station.accessibility?.elevatorLocations.first {
                return RouteAccessPoint(
                    id: "\(station.stationID)-elevator",
                    name: AppLocalization.chinese(elevator),
                    coordinate: CodableCoordinate(latitude: station.latitude, longitude: station.longitude),
                    isWheelchairLikely: true,
                    hasElevatorHint: true,
                    source: .localStationData
                )
            }
        }

        let fallbackName = kind == .origin
            ? AppLocalization.localized("nearest entrance")
            : AppLocalization.localized("nearest exit")
        return RouteAccessPoint(
            id: "\(fallbackStop.stationID)-\(kind.rawValue)-inferred",
            name: fallbackName,
            coordinate: fallbackStop.coordinate,
            isWheelchairLikely: false,
            hasElevatorHint: false,
            source: .inferred
        )
    }

    private func accessNotes(
        for station: Station?,
        accessPoint: RouteAccessPoint?,
        steps: [WalkingStep],
        filter: AccessibilityFilter
    ) -> [String] {
        var notes: [String] = []

        if filter.avoidStairs && steps.contains(where: \.hasBarrierRisk) {
            notes.append(steps.contains(where: \.hasStairs)
                ? AppLocalization.localized("Stairs detected from AMap walking directions")
                : AppLocalization.localized("Stairs may be present"))
        }

        if steps.contains(where: \.hasElevator) {
            notes.append(AppLocalization.localized("Elevator indicated by AMap walking directions"))
        } else if accessPoint?.hasElevatorHint == true || station?.accessibility?.hasElevator == true {
            notes.append(AppLocalization.localized("Elevator available"))
        }

        if steps.contains(where: \.hasRamp) {
            notes.append(AppLocalization.localized("Ramp indicated by AMap walking directions"))
        } else if accessPoint?.isWheelchairLikely == true || station?.accessibility?.hasWheelchairRamp == true {
            notes.append(AppLocalization.localized("Wheelchair path likely"))
        }

        if steps.contains(where: \.hasEscalator) {
            notes.append(AppLocalization.localized("Escalator indicated by AMap walking directions"))
        }

        if (filter.requiresWheelchairAccess || filter.requiresElevator) &&
            accessPoint?.hasElevatorHint != true &&
            accessPoint?.isWheelchairLikely != true &&
            station?.accessibility?.isFullyAccessible != true {
            let stationDataMissing = station?.accessibility?.summary == .notVerified || station?.accessibility == nil
            notes.append(stationDataMissing
                ? AppLocalization.localized("Step-free access not confirmed because station accessibility data is missing")
                : AppLocalization.localized("Step-free access not confirmed from station data"))
        }

        if notes.isEmpty && accessPoint?.source == .inferred {
            notes.append(AppLocalization.localized("Entrance selected from AMap transit route"))
        }

        var seen: Set<String> = []
        return notes.filter { seen.insert($0).inserted }
    }

    private func stationStops(from line: AMapTransitBusLine, system: LoadedSubwaySystem) -> [RouteStationStop] {
        let rawStops = [line.departureStop] + line.viaStops + [line.arrivalStop]
        return rawStops.map { rawStop in
            let rawVariants = AppLocalization.searchVariants(for: rawStop.name)
            let station = system.stations.first { station in
                if station.stationID == rawStop.id {
                    return true
                }
                let stationVariants = AppLocalization.searchVariants(for: station.name)
                return stationVariants.contains { stationVariant in
                    rawVariants.contains { rawVariant in
                        rawVariant.contains(stationVariant) || stationVariant.contains(rawVariant)
                    }
                }
            }
            let coordinate = rawStop.coordinate.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) } ??
                station.map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            return RouteStationStop(
                stationID: station?.stationID ?? rawStop.id,
                name: station?.localizedName ?? rawStop.name,
                lineName: line.displayName,
                lineColorHex: line.colorHex,
                coordinate: coordinate,
                arrivalTimeText: rawStop.id == line.departureStop.id ? line.stationScheduleText : rawStop.arrivalTimeText,
                isTransfer: station?.isTransferStation ?? false
            )
        }
    }
}

private final class SubwayDataStore {
    private var systemsByCityID: [String: CitySubwaySystem] = [:]
    private var catalogCitiesByID: [String: City] = [:]
    private var cityNameToID: [String: String] = [:]
    private var citySpellToID: [String: String] = [:]
    private var cityWebQueryByID: [String: String] = [:]
    private var stationsByCityID: [String: [Station]] = [:]
    private var loadedSystems: [String: LoadedSubwaySystem] = [:]

    init(bundle: Bundle = .main) {
        loadCities(bundle: bundle)
        loadSystems(bundle: bundle)
#if SWIFT_PACKAGE
        loadCities(bundle: .module)
        loadSystems(bundle: .module)
#endif
        buildStations()
    }

    func transitCities(urlSession: URLSession) async throws -> [City] {
        var citiesByID = catalogCitiesByID
        let liveCities = (try? await loadAmapCityList(urlSession: urlSession)) ?? []
        if !liveCities.isEmpty {
            for liveCity in liveCities {
                citiesByID[liveCity.adcode] = City(
                    amapCity: liveCity,
                    catalogCity: catalogCitiesByID[liveCity.adcode],
                    system: systemsByCityID[liveCity.adcode]
                )
            }
        }

        for (cityID, system) in systemsByCityID where citiesByID[cityID] == nil {
            citiesByID[cityID] = City(system: system, catalogCity: nil)
        }

        return citiesByID.values
            .sorted { $0.localizedName < $1.localizedName }
    }

    func webCityQuery(for city: String, urlSession: URLSession) async throws -> String {
        if let cityID = resolveCityID(city),
           let cityQuery = cityWebQueryByID[cityID] {
            return cityQuery
        }

        _ = try await loadAmapCityList(urlSession: urlSession)
        if let cityID = resolveCityID(city),
           let cityQuery = cityWebQueryByID[cityID] {
            return cityQuery
        }

        return city
    }

    func system(for city: String?, urlSession: URLSession) async throws -> LoadedSubwaySystem {
        if let cityID = city.flatMap(resolveCityID),
           let cached = loadedSystems[cityID] {
            return cached
        }

        if let cityID = city.flatMap(resolveCityID),
           let liveSystem = try? await loadAmapSubwaySystem(cityID: cityID, urlSession: urlSession) {
            if liveSystem.system?.lines.isEmpty == false && liveSystem.stations.isEmpty == false {
                loadedSystems[cityID] = liveSystem
                systemsByCityID[cityID] = liveSystem.system
                stationsByCityID[cityID] = liveSystem.stations
                return liveSystem
            }
        }

        if let cityID = city.flatMap(resolveCityID),
           let fallback = fallbackSystem(cityID: cityID) {
            loadedSystems[cityID] = fallback
            return fallback
        }

        let stations = stationsByCityID.values.flatMap { $0 }
        return LoadedSubwaySystem(cityID: city ?? "all", system: nil, stations: stations, lineOverlays: [])
    }

    func stations(near location: CLLocationCoordinate2D) async throws -> [Station]? {
        let candidate = loadedSystems.values
            .map { system in
                (system, system.center.distance(to: location))
            }
            .sorted { $0.1 < $1.1 }
            .first?.0
        return candidate?.stations
    }

    func lineContext(lineID: String, stationID: String) -> (system: CitySubwaySystem, line: SubwayLineData, station: StationData?)? {
        for system in systemsByCityID.values {
            guard let line = system.lines.first(where: { line in
                line.lineID == lineID || line.amapLineIDs?.contains(lineID) == true
            }) else {
                continue
            }

            let station = system.stations.first { $0.stationID == stationID }
            return (system, line, station)
        }

        return nil
    }

    func arrivals(lineID: String, stationID: String, systemOverride: LoadedSubwaySystem? = nil) -> [RealTimeArrival] {
        guard let system = systemOverride?.system ?? systemsByCityID.values.first(where: { city in
            city.lines.contains { $0.lineID == lineID }
        }),
              let line = system.lines.first(where: { $0.lineID == lineID }),
              let station = system.stations.first(where: { $0.stationID == stationID }) else {
            return []
        }

        let terminalNames: [String] = [
            station.firstTrainTime,
            station.lastTrainTime
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        guard !terminalNames.isEmpty else { return [] }

        return terminalNames.enumerated().map { index, timeText in
            return RealTimeArrival(
                id: UUID(),
                lineName: line.localizedName,
                lineColorHex: line.colorHex,
                destination: line.localizedName,
                arrivalTime: nil,
                minutesRemaining: nil,
                timeText: timeText,
                isAccessible: stationsByCityID[system.cityID]?.first(where: { $0.stationID == stationID })?.accessibility?.isFullyAccessible ?? false,
                platformNumber: "\(index + 1)",
                source: .bundledSchedule
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
            catalogCitiesByID[city.id] = city
            cityNameToID[city.id.lowercased()] = city.id
            cityNameToID[city.name.lowercased()] = city.id
            cityNameToID[city.nameEn.lowercased()] = city.id
            cityNameToID[city.namePinyin.lowercased()] = city.id
            citySpellToID[city.id] = city.namePinyin
            cityWebQueryByID[city.id] = city.name
        }
    }

    private func loadSystems(bundle: Bundle) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileName in bundledSubwaySystemNames(bundle: bundle) {
            guard let url = resourceURL(fileName, bundle: bundle),
                  let data = try? Data(contentsOf: url),
                  let system = try? decoder.decode(CitySubwaySystem.self, from: data) else {
                continue
            }

            systemsByCityID[system.cityID] = system
        }
    }

    private func loadAmapSubwaySystem(cityID: String, urlSession: URLSession) async throws -> LoadedSubwaySystem? {
        if citySpellToID[cityID] == nil {
            _ = try await loadAmapCityList(urlSession: urlSession)
        }

        guard let spell = citySpellToID[cityID] else { return nil }
        let payload: AMapSubwayPayload = try await fetchJSON(
            AMapSubwayPayload.self,
            endpoint: "https://map.amap.com/service/subway",
            queryItems: [
                URLQueryItem(name: "_", value: "\(Int(Date().timeIntervalSince1970 * 1000))"),
                URLQueryItem(name: "srhdata", value: "\(cityID)_drw_\(spell).json")
            ],
            urlSession: urlSession
        )
        return buildAmapSubwaySystem(payload: payload, cityID: cityID)
    }

    private func loadAmapCityList(urlSession: URLSession) async throws -> [AMapSubwayCity] {
        let cityListResponse: AMapSubwayCityListResponse = try await fetchJSON(
            AMapSubwayCityListResponse.self,
            endpoint: "https://map.amap.com/service/subway",
            queryItems: [URLQueryItem(name: "srhdata", value: "citylist.json")],
            urlSession: urlSession
        )
        for city in cityListResponse.citylist {
            cityNameToID[city.adcode.lowercased()] = city.adcode
            cityNameToID[city.cityname.lowercased()] = city.adcode
            cityNameToID[city.shortCityName.lowercased()] = city.adcode
            cityNameToID[city.spell.lowercased()] = city.adcode
            citySpellToID[city.adcode] = city.spell
            cityWebQueryByID[city.adcode] = city.cityname
        }
        return cityListResponse.citylist
    }

    private func buildAmapSubwaySystem(payload: AMapSubwayPayload, cityID: String) -> LoadedSubwaySystem {
        var stationByID: [String: Station] = [:]
        var rawStationByID: [String: AMapSubwayStation] = [:]
        var lines: [SubwayLineData] = []
        var lineModels: [String: SubwayLine] = [:]
        let localSystem = systemsByCityID[cityID]
        let localStations = stationsByCityID[cityID] ?? []
        var localStationDataByID: [String: StationData] = [:]
        var localStationByID: [String: Station] = [:]

        for stationData in localSystem?.stations ?? [] {
            localStationDataByID[stationData.stationID] = stationData
        }

        for station in localStations {
            localStationByID[station.stationID] = station
        }

        func matches(rawStation: AMapSubwayStation, localName: String, localNameEn: String?, localPinyin: String?) -> Bool {
            let rawVariants = AppLocalization.searchVariants(for: rawStation.name)
                .union(AppLocalization.searchVariants(for: rawStation.pinyin ?? ""))
            let localVariants = AppLocalization.searchVariants(for: localName)
                .union(AppLocalization.searchVariants(for: localNameEn ?? ""))
                .union(AppLocalization.searchVariants(for: localPinyin ?? ""))

            return rawVariants.contains { rawVariant in
                localVariants.contains { localVariant in
                    rawVariant == localVariant ||
                    rawVariant.contains(localVariant) ||
                    localVariant.contains(rawVariant)
                }
            }
        }

        func localStationData(for rawStation: AMapSubwayStation) -> StationData? {
            if let stationData = localStationDataByID[rawStation.stationID] {
                return stationData
            }

            let poiIDs = Set(rawStation.poiIDs)
            if !poiIDs.isEmpty,
               let poiMatch = localSystem?.stations.first(where: { stationData in
                   Set(stationData.poiIDs ?? []).isDisjoint(with: poiIDs) == false
               }) {
                return poiMatch
            }

            return localSystem?.stations.first {
                matches(rawStation: rawStation, localName: $0.name, localNameEn: $0.nameEn, localPinyin: $0.namePinyin)
            }
        }

        func localStation(for rawStation: AMapSubwayStation) -> Station? {
            if let station = localStationByID[rawStation.stationID] {
                return station
            }

            let poiIDs = Set(rawStation.poiIDs)
            if !poiIDs.isEmpty,
               let poiMatch = localStations.first(where: { Set($0.poiIDs).isDisjoint(with: poiIDs) == false }) {
                return poiMatch
            }

            return localStations.first {
                matches(rawStation: rawStation, localName: $0.name, localNameEn: $0.nameEn, localPinyin: $0.namePinyin)
            }
        }

        func stationMergeKey(for rawStation: AMapSubwayStation, localStation: Station?, localData: StationData?) -> String {
            if let localStation {
                return localStation.stationID
            }
            if let localData {
                return localData.stationID
            }
            if let poiID = rawStation.poiIDs.first(where: \.isLikelyAMapPOIID) {
                return poiID
            }
            return rawStation.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        for line in payload.l {
            let colorHex = line.colorHex.isEmpty ? "#007AFF" : "#\(line.colorHex)"
            let lineModel = SubwayLine(
                lineID: line.lineID,
                name: line.displayName,
                nameEn: nil,
                colorHex: colorHex,
                cityID: cityID
            )
            lineModels[line.lineID] = lineModel
            lines.append(SubwayLineData(
                lineID: line.lineID,
                name: line.displayName,
                nameEn: nil,
                colorHex: colorHex,
                stationIDs: line.stations.map { $0.stationID },
                amapLineIDs: line.rawLineIDs,
                polyline: nil
            ))

            for rawStation in line.stations {
                guard let coordinate = rawStation.coordinate else { continue }
                let localStation = localStation(for: rawStation)
                let localData = localStationData(for: rawStation)
                let stationKey = stationMergeKey(for: rawStation, localStation: localStation, localData: localData)
                rawStationByID[stationKey] = rawStation
                let station = stationByID[stationKey] ?? Station(
                    stationID: stationKey,
                    name: rawStation.name,
                    nameEn: localStation?.nameEn,
                    namePinyin: rawStation.pinyin,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    cityID: cityID,
                    isTransferStation: false,
                    floorCount: localStation?.floorCount ?? 1
                )
                station.latitude = coordinate.latitude
                station.longitude = coordinate.longitude
                station.nameEn = station.nameEn ?? localStation?.nameEn
                station.floorCount = max(station.floorCount, localStation?.floorCount ?? 1)
                if station.exits.isEmpty, let exits = localStation?.exits {
                    station.exits = exits
                }
                if station.exits.isEmpty, let exits = localData?.exits {
                    station.exits = exits.map { exit in
                        StationExit(
                            exitID: exit.exitID,
                            stationID: station.stationID,
                            name: exit.name,
                            nameEn: exit.nameEn,
                            hasElevator: exit.hasElevator,
                            hasEscalator: exit.hasEscalator,
                            hasWheelchairRamp: exit.hasWheelchairRamp,
                            isAccessible: exit.isAccessible,
                            nearbyLandmarks: exit.nearbyLandmarks ?? []
                        )
                    }
                }
                if station.accessibility == nil {
                    station.accessibility = localStation?.accessibility ?? localData.map {
                        StationAccessibility(stationID: station.stationID, data: $0.accessibility ?? .inferredFromAMapStation)
                    }
                }
                for poiID in localStation?.poiIDs ?? [] where !station.poiIDs.contains(poiID) {
                    station.poiIDs.append(poiID)
                }
                for poiID in localData?.poiIDs ?? [] where !station.poiIDs.contains(poiID) {
                    station.poiIDs.append(poiID)
                }
                if station.lines.contains(where: { $0.lineID == line.lineID }) == false {
                    station.lines.append(lineModel)
                }
                for poiID in rawStation.poiIDs where !station.poiIDs.contains(poiID) {
                    station.poiIDs.append(poiID)
                }
                stationByID[stationKey] = station
            }
        }

        for station in stationByID.values {
            station.isTransferStation = station.lines.count > 1
        }

        let stations = stationByID.values.sorted { $0.name < $1.name }
        let system = CitySubwaySystem(
            cityID: cityID,
            version: "amap-live",
            lastUpdated: Date(),
            lines: lines,
            stations: stations.map { station in
                let rawStation = rawStationByID[station.stationID]
                let localData = rawStation.flatMap { localStationData(for: $0) } ?? localStationDataByID[station.stationID]
                let firstTrainTime = rawStation.flatMap { firstTimeText(from: $0.firstDepartures) } ?? localData?.firstTrainTime
                let lastTrainTime = rawStation.flatMap { firstTimeText(from: $0.lastDepartures) } ?? localData?.lastTrainTime
                return StationData(
                    stationID: station.stationID,
                    name: station.name,
                    nameEn: station.nameEn,
                    namePinyin: station.namePinyin,
                    latitude: station.latitude,
                    longitude: station.longitude,
                    isTransferStation: station.isTransferStation,
                    floorCount: station.floorCount,
                    lineIDs: station.lines.map(\.lineID),
                    poiIDs: station.poiIDs,
                    exits: localData?.exits,
                    accessibility: (localData?.accessibility).mergedWithAMapStationHints,
                    platformCount: localData?.platformCount,
                    firstTrainTime: firstTrainTime,
                    lastTrainTime: lastTrainTime
                )
            }
        )
        return LoadedSubwaySystem(cityID: cityID, system: system, stations: stations, lineOverlays: [])
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
                station.poiIDs = data.poiIDs ?? []
                station.lines = data.lineIDs.compactMap { lineLookup[$0] }
                station.isTransferStation = station.lines.count > 1 || Set(data.lineIDs).count > 1
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
                station.accessibility = data.accessibility.map {
                    StationAccessibility(stationID: data.stationID, data: $0)
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

    private func bundledSubwaySystemNames(bundle: Bundle) -> [String] {
        let urls = [
            bundle.url(forResource: "SubwayData", withExtension: nil),
            bundle.resourceURL?.appending(path: "SubwayData"),
            bundle.resourceURL?.appending(path: "Resources/SubwayData")
        ]
            .compactMap { $0 }

        let names = urls.flatMap { url -> [String] in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return files
                .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent != "cities" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }

        return Array(Set(names)).sorted()
    }

    private func resourceURL(_ name: String, bundle: Bundle) -> URL? {
        let directURLs = [
            bundle.resourceURL?.appending(path: "SubwayData/\(name).json"),
            bundle.resourceURL?.appending(path: "Resources/SubwayData/\(name).json"),
            bundle.resourceURL?.appending(path: "Resources/\(name).json"),
            bundle.resourceURL?.appending(path: "\(name).json")
        ]
            .compactMap { $0 }

        return directURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ??
            bundle.url(forResource: name, withExtension: "json", subdirectory: "SubwayData") ??
            bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources/SubwayData") ??
            bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources") ??
            bundle.url(forResource: name, withExtension: "json")
    }

    private func fallbackSystem(cityID: String) -> LoadedSubwaySystem? {
        guard let system = systemsByCityID[cityID] else { return nil }
        return LoadedSubwaySystem(
            cityID: cityID,
            system: system,
            stations: stationsByCityID[cityID] ?? [],
            lineOverlays: []
        )
    }
}

struct SubwayLineMapOverlay: Identifiable, Codable {
    let id: String
    let name: String
    let colorHex: String
    let coordinates: [CodableCoordinate]

    var polylineCoordinates: [CLLocationCoordinate2D] {
        coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    func simplifiedForMap(maxPoints: Int = 420, minDistanceMeters: Double = 14) -> SubwayLineMapOverlay {
        guard coordinates.count > maxPoints else { return self }

        var simplified: [CodableCoordinate] = []
        simplified.reserveCapacity(min(coordinates.count, maxPoints))

        for coordinate in coordinates {
            guard let previous = simplified.last else {
                simplified.append(coordinate)
                continue
            }

            let previousLocation = CLLocationCoordinate2D(latitude: previous.latitude, longitude: previous.longitude)
            let currentLocation = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if previousLocation.distance(to: currentLocation) >= minDistanceMeters {
                simplified.append(coordinate)
            }
        }

        if let last = coordinates.last {
            let currentLast = simplified.last
            if currentLast?.latitude != last.latitude || currentLast?.longitude != last.longitude {
                simplified.append(last)
            }
        }

        if simplified.count > maxPoints {
            let stride = max(1, simplified.count / maxPoints)
            simplified = simplified.enumerated().compactMap { index, coordinate in
                index == 0 || index == simplified.count - 1 || index.isMultiple(of: stride) ? coordinate : nil
            }
        }

        return SubwayLineMapOverlay(
            id: id,
            name: name,
            colorHex: colorHex,
            coordinates: simplified.count >= 2 ? simplified : coordinates
        )
    }
}

private final class LineOverlayDiskCache {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load(cityID: String) throws -> [SubwayLineMapOverlay] {
        let url = try cacheURL(cityID: cityID)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let overlays = try decoder.decode([SubwayLineMapOverlay].self, from: data)
        return overlays.filter { $0.coordinates.count >= 2 }
    }

    func save(_ overlays: [SubwayLineMapOverlay], cityID: String) throws {
        let validOverlays = overlays.filter { $0.coordinates.count >= 2 }
        guard !validOverlays.isEmpty else { return }
        let url = try cacheURL(cityID: cityID)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try encoder.encode(validOverlays)
        try data.write(to: url, options: [.atomic])
    }

    private func cacheURL(cityID: String) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL
            .appendingPathComponent("LineOverlays", isDirectory: true)
            .appendingPathComponent("\(cityID)-amap-v1.json")
    }
}

struct TransitPlace: Identifiable, Equatable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let uid: String?
    let type: String?
    let typeCode: String?
    let address: String?
    let cityCode: String?
    let adCode: String?
    let naviPOIID: String?
    let entranceCoordinate: CLLocationCoordinate2D?
    let source: TransitPlaceSource

    init(
        name: String,
        coordinate: CLLocationCoordinate2D,
        uid: String? = nil,
        type: String? = nil,
        typeCode: String? = nil,
        address: String? = nil,
        cityCode: String? = nil,
        adCode: String? = nil,
        naviPOIID: String? = nil,
        entranceCoordinate: CLLocationCoordinate2D? = nil,
        source: TransitPlaceSource = .poiSearch
    ) {
        self.name = name
        self.coordinate = coordinate
        self.uid = uid
        self.type = type
        self.typeCode = typeCode
        self.address = address
        self.cityCode = cityCode
        self.adCode = adCode
        self.naviPOIID = naviPOIID
        self.entranceCoordinate = entranceCoordinate
        self.source = source
    }

    var id: String {
        uid ?? "\(name)-\(String(format: "%.6f", coordinate.latitude))-\(String(format: "%.6f", coordinate.longitude))"
    }

    var routeCoordinate: CLLocationCoordinate2D {
        entranceCoordinate ?? coordinate
    }

    var routePOIID: String? {
        naviPOIID ?? uid
    }

    func withSource(_ source: TransitPlaceSource) -> TransitPlace {
        TransitPlace(
            name: name,
            coordinate: coordinate,
            uid: uid,
            type: type,
            typeCode: typeCode,
            address: address,
            cityCode: cityCode,
            adCode: adCode,
            naviPOIID: naviPOIID,
            entranceCoordinate: entranceCoordinate,
            source: source
        )
    }

    var detailText: String? {
        let candidates = [
            type,
            address
        ]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        return candidates.isEmpty ? nil : candidates.joined(separator: " - ")
    }

    static func == (lhs: TransitPlace, rhs: TransitPlace) -> Bool {
        lhs.id == rhs.id
    }
}

struct LoadedSubwaySystem {
    let cityID: String
    let system: CitySubwaySystem?
    let stations: [Station]
    let lineOverlays: [SubwayLineMapOverlay]

    var center: CLLocationCoordinate2D {
        guard !stations.isEmpty else {
            return CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        }

        let latitude = stations.reduce(0) { $0 + $1.latitude } / Double(stations.count)
        let longitude = stations.reduce(0) { $0 + $1.longitude } / Double(stations.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

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

    var resolvedURL: URL? {
        URL(string: assetURL)
    }

    func resolving(relativeTo baseURL: URL?) -> CityPackStationMap {
        guard URL(string: assetURL)?.scheme == nil,
              let baseURL,
              let resolvedURL = URL(string: assetURL, relativeTo: baseURL)?.absoluteURL else {
            return self
        }

        return CityPackStationMap(
            title: title,
            assetURL: resolvedURL.absoluteString,
            assetType: assetType,
            sourceURL: sourceURL
        )
    }

    var isImage: Bool {
        ["image", "png", "jpg", "jpeg", "webp"].contains(assetType.lowercased())
    }
}

struct CityPackStationAsset: Codable, Equatable {
    let category: String
    let title: String?
    let assetURL: String
    let assetType: String
    let sourceURL: String?

    var resolvedURL: URL? {
        URL(string: assetURL)
    }

    func resolving(relativeTo baseURL: URL?) -> CityPackStationAsset {
        guard URL(string: assetURL)?.scheme == nil,
              let baseURL,
              let resolvedURL = URL(string: assetURL, relativeTo: baseURL)?.absoluteURL else {
            return self
        }

        return CityPackStationAsset(
            category: category,
            title: title,
            assetURL: resolvedURL.absoluteString,
            assetType: assetType,
            sourceURL: sourceURL
        )
    }

    var isImage: Bool {
        ["image", "png", "jpg", "jpeg", "webp"].contains(assetType.lowercased())
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

private struct RemoteDataManifest: Decodable {
    let schemaVersion: Int
    let generatedAt: String?
    let primaryHost: String?
    let cities: [RemoteCityPack]

    func entry(for cityID: String) -> RemoteCityPack? {
        cities.first { $0.cityID == cityID }
    }
}

private struct RemoteCityPack: Decodable {
    let cityID: String
    let version: String
    let sizeBytes: Int?
    let sha256: String?
    let downloadURL: String?
    let sourceURLs: [String]
    let capabilities: CityPackCapabilities

    var hasDownload: Bool {
        guard let downloadURL else { return false }
        return downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private struct CityPackCapabilities: Codable {
    let accessibility: String
    let schedules: String
    let liveArrivals: String
    let stationMaps: String
}

private struct CityDataPack: Decodable {
    let schemaVersion: Int
    let cityID: String
    let version: String
    let generatedAt: String?
    let sourceURLs: [String]
    let capabilities: CityPackCapabilities
    let liveProvider: String
    let sourceAttribution: String?
    let stations: [CityPackStation]

    private var stationLookup: [String: CityPackStation] {
        Dictionary(stations.map { (normalizeStationKey($0.stationName), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func station(named name: String) -> CityPackStation? {
        stationLookup[normalizeStationKey(name)]
    }
}

private struct CityPackStation: Decodable {
    let stationName: String
    let stationID: String?
    let accessibility: CityPackAccessibility?
    let schedules: [CityPackSchedule]
    let stationMaps: [CityPackStationMap]
    let stationAssets: [CityPackStationAsset]
    let stationFacilities: [CityPackStationFacility]
    let serviceStatus: CityPackServiceStatus?

    enum CodingKeys: String, CodingKey {
        case stationName
        case stationID
        case accessibility
        case schedules
        case stationMaps
        case stationAssets
        case stationFacilities
        case serviceStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationName = try container.decode(String.self, forKey: .stationName)
        stationID = try container.decodeIfPresent(String.self, forKey: .stationID)
        accessibility = try container.decodeIfPresent(CityPackAccessibility.self, forKey: .accessibility)
        schedules = try container.decodeIfPresent([CityPackSchedule].self, forKey: .schedules) ?? []
        stationMaps = try container.decodeIfPresent([CityPackStationMap].self, forKey: .stationMaps) ?? []
        stationAssets = try container.decodeIfPresent([CityPackStationAsset].self, forKey: .stationAssets) ?? []
        stationFacilities = try container.decodeIfPresent([CityPackStationFacility].self, forKey: .stationFacilities) ?? []
        serviceStatus = try container.decodeIfPresent(CityPackServiceStatus.self, forKey: .serviceStatus)
    }

    var accessibilityData: AccessibilityData? {
        accessibility?.accessibilityData
    }

    func stationFacilities(for station: Station) -> [StationFacility] {
        let explicitFacilities = stationFacilities.map { $0.stationFacility(stationID: station.stationID) }
        if !explicitFacilities.isEmpty {
            return deduplicatedFacilities(explicitFacilities)
        }

        let notes = accessibility?.facilityNotes ?? []
        return deduplicatedFacilities(notes.enumerated().map { index, note in
            StationFacility(
                id: "\(station.stationID)-note-\(index)",
                stationID: station.stationID,
                type: StationFacilityType.inferred(from: note),
                name: note,
                locationText: nil,
                source: .officialCityPack,
                verification: .verified
            )
        })
    }

    private func deduplicatedFacilities(_ facilities: [StationFacility]) -> [StationFacility] {
        var seen = Set<String>()
        return facilities.filter { facility in
            let key = [
                facility.type.rawValue,
                normalizedFacilityText(facility.name),
                normalizedFacilityText(facility.locationText ?? ""),
                facility.source.rawValue,
                facility.verification.rawValue
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    private func normalizedFacilityText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .lowercased()
    }
}

private struct CityPackStationFacility: Decodable {
    let id: String?
    let type: String?
    let name: String
    let locationText: String?
    let source: String?
    let verification: String?

    func stationFacility(stationID: String) -> StationFacility {
        StationFacility(
            id: id ?? "\(stationID)-facility-\(name)",
            stationID: stationID,
            type: StationFacilityType(rawValue: type ?? "") ?? StationFacilityType.inferred(from: "\(name) \(locationText ?? "")"),
            name: name,
            locationText: locationText,
            source: StationFacilitySource(rawValue: source ?? "") ?? .officialCityPack,
            verification: StationFacilityVerification(rawValue: verification ?? "") ?? .verified
        )
    }
}

private struct CityPackAccessibility: Decodable {
    let source: String?
    let hasElevator: Bool?
    let hasEscalator: Bool?
    let hasWheelchairRamp: Bool?
    let hasTactilePath: Bool?
    let hasAccessibleRestroom: Bool?
    let elevatorLocations: [String]?
    let accessibleEntrances: [String]?
    let facilityNotes: [String]?

    var accessibilityData: AccessibilityData {
        let hasMobilityAid = hasElevator == true || hasWheelchairRamp == true
        return AccessibilityData(
            source: source ?? "official_city_pack",
            hasElevator: hasElevator,
            hasEscalator: hasEscalator,
            hasWheelchairRamp: hasWheelchairRamp,
            hasAccessibleRestroom: hasAccessibleRestroom,
            isFullyAccessible: hasMobilityAid ? true : nil,
            elevatorLocations: elevatorLocations,
            accessibleEntrances: accessibleEntrances,
            facilityNotes: facilityNotes,
            hasTactilePath: hasTactilePath,
            hasColorCoding: true,
            hasPictograms: true
        )
    }
}

private struct CityPackSchedule: Decodable {
    let lineName: String
    let direction: String
    let firstTime: String?
    let lastTime: String?

    func matches(line: SubwayLineData) -> Bool {
        let officialName = normalizeTransitLineName(lineName)
        let lineNames = line.scheduleQueryNames.map(normalizeTransitLineName)
        return lineNames.contains { name in
            officialName.contains(name) || name.contains(officialName)
        }
    }
}

private actor CityPackStore {
    private struct LoadedCityPack {
        let pack: CityDataPack
        let assetBaseURL: URL?
    }

    private let manifestURL: URL?
    private let fileManager: FileManager
    private var manifest: RemoteDataManifest?
    private var packsByCityID: [String: LoadedCityPack] = [:]

    init(
        manifestURL: URL? = CityPackStore.configuredManifestURL,
        fileManager: FileManager = .default
    ) {
        self.manifestURL = manifestURL
        self.fileManager = fileManager
    }

    func ensurePack(cityID: String, urlSession: URLSession) async throws -> CityPackLoadStatus {
        if let loadedPack = packsByCityID[cityID] {
            return .loaded(version: loadedPack.pack.version)
        }
        guard manifestURL != nil else {
            return .notConfigured
        }

        let manifest = try await loadManifest(urlSession: urlSession)
        guard let entry = manifest.entry(for: cityID) else {
            return .notAvailable
        }
        guard entry.hasDownload else {
            return entry.capabilities.accessibility == "source_pending" ||
                entry.capabilities.schedules == "source_pending" ||
                entry.capabilities.stationMaps == "source_pending"
                ? .sourcePending
                : .notAvailable
        }

        if let cachedPack = try? loadCachedPack(entry: entry) {
            packsByCityID[cityID] = LoadedCityPack(pack: cachedPack, assetBaseURL: assetBaseURL(for: entry))
            return .loaded(version: cachedPack.version)
        }

        guard let downloadURL = resolvedDownloadURL(entry.downloadURL) else {
            return .notAvailable
        }

        let (data, response) = try await urlSession.data(from: downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RoutePlanningError.networkError
        }
        try verify(data: data, expectedSHA256: entry.sha256)
        let pack = try JSONDecoder().decode(CityDataPack.self, from: data)
        try cache(data: data, entry: entry)
        try deleteOldVersions(cityID: cityID, keeping: entry.version)
        packsByCityID[cityID] = LoadedCityPack(pack: pack, assetBaseURL: assetBaseURL(for: entry))
        return .loaded(version: pack.version)
    }

    func station(cityID: String, stationName: String) -> CityPackStation? {
        packsByCityID[cityID]?.pack.station(named: stationName)
    }

    func stationMap(cityID: String, stationName: String) -> CityPackStationMap? {
        guard let loadedPack = packsByCityID[cityID] else { return nil }
        return loadedPack.pack.station(named: stationName)?
            .stationMaps
            .first?
            .resolving(relativeTo: loadedPack.assetBaseURL)
    }

    func stationAssets(cityID: String, stationName: String, category: String? = nil) -> [CityPackStationAsset] {
        guard let loadedPack = packsByCityID[cityID] else { return [] }
        return loadedPack.pack.station(named: stationName)?
            .stationAssets
            .filter { asset in
                category == nil || asset.category == category
            }
            .map { $0.resolving(relativeTo: loadedPack.assetBaseURL) } ?? []
    }

    func routeCoverage(cityID: String, stationNames: [String]) -> RouteDataCoverage {
        let uniqueNames = Array(Set(stationNames.map(normalizeStationKey)))
        guard let pack = packsByCityID[cityID]?.pack else {
            return RouteDataCoverage(
                stationCount: uniqueNames.count,
                officialAccessibilityCount: 0,
                officialScheduleCount: 0,
                officialStationMapCount: 0,
                officialFacilityCount: 0
            )
        }

        let stationsByName = Dictionary(
            pack.stations.map { (normalizeStationKey($0.stationName), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let stations = uniqueNames.compactMap { stationsByName[$0] }
        return RouteDataCoverage(
            stationCount: max(uniqueNames.count, stations.count),
            officialAccessibilityCount: stations.filter { $0.accessibilityData != nil }.count,
            officialScheduleCount: stations.filter { !$0.schedules.isEmpty }.count,
            officialStationMapCount: stations.filter { !$0.stationMaps.isEmpty }.count,
            officialFacilityCount: stations.filter { !$0.stationFacilities.isEmpty }.count
        )
    }

    func serviceStatus(cityID: String, stationName: String) -> CityPackServiceStatus? {
        packsByCityID[cityID]?.pack.station(named: stationName)?.serviceStatus
    }

    func officialArrivals(context: (system: CitySubwaySystem, line: SubwayLineData, station: StationData?)) -> [RealTimeArrival] {
        guard let station = context.station,
              let cityPackStation = packsByCityID[context.system.cityID]?.pack.station(named: station.name) else {
            return []
        }

        return cityPackStation.schedules
            .filter { schedule in
                schedule.matches(line: context.line)
            }
            .compactMap { schedule in
                let text = formatScheduleText(first: schedule.firstTime, last: schedule.lastTime)
                guard text != nil else { return nil }
                return RealTimeArrival(
                    id: UUID(),
                    lineName: context.line.localizedName,
                    lineColorHex: context.line.colorHex,
                    destination: schedule.direction,
                    arrivalTime: nil,
                    minutesRemaining: nil,
                    timeText: text,
                    isAccessible: cityPackStation.accessibilityData?.isFullyAccessible == true || station.accessibility?.isFullyAccessible == true,
                    platformNumber: nil,
                    source: .officialSchedule
                )
            }
    }

    private func loadManifest(urlSession: URLSession) async throws -> RemoteDataManifest {
        if let manifest {
            return manifest
        }
        guard let manifestURL else {
            throw RoutePlanningError.networkError
        }

        let (data, response) = try await urlSession.data(from: manifestURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RoutePlanningError.networkError
        }

        let decoded = try JSONDecoder().decode(RemoteDataManifest.self, from: data)
        manifest = decoded
        return decoded
    }

    private func loadCachedPack(entry: RemoteCityPack) throws -> CityDataPack {
        let url = cacheURL(cityID: entry.cityID, version: entry.version)
        let data = try Data(contentsOf: url)
        try verify(data: data, expectedSHA256: entry.sha256)
        return try JSONDecoder().decode(CityDataPack.self, from: data)
    }

    private func cache(data: Data, entry: RemoteCityPack) throws {
        let url = cacheURL(cityID: entry.cityID, version: entry.version)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func deleteOldVersions(cityID: String, keeping version: String) throws {
        let cityDirectory = cityPacksDirectory.appendingPathComponent(cityID, isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(at: cityDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for url in versions where url.lastPathComponent != version {
            try? fileManager.removeItem(at: url)
        }
    }

    private func verify(data: Data, expectedSHA256: String?) throws {
        guard let expectedSHA256, !expectedSHA256.isEmpty else { return }
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual.lowercased() == expectedSHA256.lowercased() else {
            throw RoutePlanningError.networkError
        }
    }

    private func resolvedDownloadURL(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        if let absolute = URL(string: rawValue), absolute.scheme != nil {
            return absolute
        }
        guard let manifestURL else { return nil }
        return URL(string: rawValue, relativeTo: manifestURL)?.absoluteURL
    }

    private func assetBaseURL(for entry: RemoteCityPack) -> URL? {
        resolvedDownloadURL(entry.downloadURL)?.deletingLastPathComponent()
    }

    private func cacheURL(cityID: String, version: String) -> URL {
        cityPacksDirectory
            .appendingPathComponent(cityID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("city_pack.json")
    }

    private var cityPacksDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory
        return base.appendingPathComponent("CityPacks", isDirectory: true)
    }

    private static var configuredManifestURL: URL? {
        let candidates = [
            Bundle.main.object(forInfoDictionaryKey: "CityPackBaseURL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CityPackManifestURL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CityPackFallbackBaseURL") as? String
        ]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("$(") && !$0.isPlaceholderCityPackURL }

        guard let rawValue = candidates.first else {
            return nil
        }
        if rawValue.hasSuffix("/manifest.json") {
            return URL(string: rawValue)
        }
        return URL(string: rawValue)?
            .appendingPathComponent("manifest.json")
    }
}

private extension String {
    var isPlaceholderCityPackURL: Bool {
        contains("justgo-city-packs.cos.ap-beijing.myqcloud.com") ||
        contains("<owner>") ||
        contains("<repo>") ||
        contains("example.com/justgo-city-data")
    }
}

private extension Route {
    var deduplicationKey: String {
        let stationSequence = stationTimelineStops
            .map { AppLocalization.searchVariants(for: $0.stationID).sorted().first ?? AppLocalization.searchVariants(for: $0.name).sorted().first ?? $0.name }
            .joined(separator: ">")
        let lineSequence = segments
            .filter { $0.type == .subway }
            .map { AppLocalization.searchVariants(for: $0.lineName ?? "").sorted().first ?? ($0.lineName ?? "") }
            .joined(separator: ">")
        let walkingBucket = Int((walkingDistance / 100).rounded())
        return [
            stationSequence,
            lineSequence,
            "\(transferCount)",
            "\(walkingBucket)"
        ].joined(separator: "|")
    }

    func isBetterDuplicate(than other: Route) -> Bool {
        if warnings.count != other.warnings.count {
            return warnings.count < other.warnings.count
        }
        if abs(walkingDistance - other.walkingDistance) > 1 {
            return walkingDistance < other.walkingDistance
        }
        if abs(totalDuration - other.totalDuration) > 1 {
            return totalDuration < other.totalDuration
        }
        if accessibilityScore != other.accessibilityScore {
            return accessibilityScore > other.accessibilityScore
        }
        return strategy == .metroFirst && other.strategy != .metroFirst
    }
}

private extension City {
    init(amapCity: AMapSubwayCity) {
        self.init(amapCity: amapCity, catalogCity: nil, system: nil)
    }

    init(amapCity: AMapSubwayCity, catalogCity: City?, system: CitySubwaySystem?) {
        let systemCenter = system.map { Self.center(for: $0) }
        let latitude = catalogCity?.latitude ?? systemCenter?.latitude ?? amapCity.defaultCoordinate.latitude
        let longitude = catalogCity?.longitude ?? systemCenter?.longitude ?? amapCity.defaultCoordinate.longitude
        self.init(
            id: amapCity.adcode,
            name: catalogCity?.name ?? amapCity.shortCityName,
            nameEn: catalogCity?.nameEn ?? amapCity.spell.capitalized,
            namePinyin: catalogCity?.namePinyin ?? amapCity.spell,
            latitude: latitude,
            longitude: longitude,
            stationCount: catalogCity?.stationCount ?? system?.stations.count ?? 0,
            lineCount: catalogCity?.lineCount ?? system?.lines.count ?? 0
        )
    }

    init(system: CitySubwaySystem) {
        self.init(system: system, catalogCity: nil)
    }

    init(system: CitySubwaySystem, catalogCity: City?) {
        let center = Self.center(for: system)
        self.init(
            id: system.cityID,
            name: catalogCity?.name ?? system.cityID,
            nameEn: catalogCity?.nameEn ?? system.cityID,
            namePinyin: catalogCity?.namePinyin ?? system.cityID,
            latitude: catalogCity?.latitude ?? center.latitude,
            longitude: catalogCity?.longitude ?? center.longitude,
            stationCount: catalogCity?.stationCount ?? system.stations.count,
            lineCount: catalogCity?.lineCount ?? system.lines.count
        )
    }

    static func center(for system: CitySubwaySystem) -> CLLocationCoordinate2D {
        guard !system.stations.isEmpty else {
            return CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        }
        let latitude = system.stations.reduce(0) { $0 + $1.latitude } / Double(system.stations.count)
        let longitude = system.stations.reduce(0) { $0 + $1.longitude } / Double(system.stations.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension AccessibilityData {
    static var inferredFromAMapStation: AccessibilityData {
        AccessibilityData(
            hasElevator: nil,
            hasEscalator: nil,
            hasWheelchairRamp: nil,
            hasAccessibleRestroom: nil,
            isFullyAccessible: nil,
            elevatorLocations: nil,
            accessibleEntrances: nil,
            facilityNotes: nil,
            wheelchairBoardingAssistance: nil,
            hasTactilePath: nil,
            hasBrailleSigns: nil,
            hasAudioAnnouncement: nil,
            tactilePathCoverage: nil,
            hasVisualAnnouncement: nil,
            hasHearingLoop: nil,
            hasSignLanguageDisplay: nil,
            hasSimplifiedSignage: nil,
            hasColorCoding: true,
            hasPictograms: true
        )
    }

    var mergedWithAMapStationHints: AccessibilityData {
        AccessibilityData(
            source: source,
            hasElevator: hasElevator,
            hasEscalator: hasEscalator,
            hasWheelchairRamp: hasWheelchairRamp,
            hasAccessibleRestroom: hasAccessibleRestroom,
            isFullyAccessible: isFullyAccessible,
            elevatorLocations: elevatorLocations,
            accessibleEntrances: accessibleEntrances,
            facilityNotes: facilityNotes,
            wheelchairBoardingAssistance: wheelchairBoardingAssistance,
            hasTactilePath: hasTactilePath,
            hasBrailleSigns: hasBrailleSigns,
            hasAudioAnnouncement: hasAudioAnnouncement,
            tactilePathCoverage: tactilePathCoverage,
            hasVisualAnnouncement: hasVisualAnnouncement,
            hasHearingLoop: hasHearingLoop,
            hasSignLanguageDisplay: hasSignLanguageDisplay,
            hasSimplifiedSignage: hasSimplifiedSignage,
            hasColorCoding: hasColorCoding ?? true,
            hasPictograms: hasPictograms ?? true
        )
    }
}

private extension Station {
    var amapEntranceSearchKeywords: [String] {
        [
            "\(name) 出入口",
            "\(name) 地铁站 出入口",
            "\(name) 地铁站",
            name
        ]
    }
}

private extension StationExit {
    func isSpecificAMapExitName(for stationName: String) -> Bool {
        let compactName = name.replacingOccurrences(of: " ", with: "")
        let compactStationName = stationName.replacingOccurrences(of: " ", with: "")
        let genericNames = [
            "\(compactStationName)地铁站出入口",
            "\(compactStationName)站出入口",
            "\(compactStationName)出入口"
        ]
        if genericNames.contains(compactName) {
            return false
        }

        return compactName.range(
            of: #"[A-ZＡ-Ｚ]\d*|[A-ZＡ-Ｚ][一二三四五六七八九十]?|[东西南北][北南东西]?\d*口"#,
            options: .regularExpression
        ) != nil
    }
}

private extension String {
    var isLikelyAMapPOIID: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty == false && trimmed.rangeOfCharacter(from: .letters) != nil
    }
}

private extension Optional where Wrapped == AccessibilityData {
    var mergedWithAMapStationHints: AccessibilityData {
        switch self {
        case .some(let accessibility):
            return accessibility.mergedWithAMapStationHints
        case .none:
            return .inferredFromAMapStation
        }
    }
}

private struct CitiesResponse: Codable {
    let version: String
    let cities: [City]
}

private extension Optional where Wrapped == AccessibilityData {
    func merged(with officialData: AccessibilityData?) -> AccessibilityData? {
        guard let officialData else { return self }
        guard let existing = self else { return officialData }

        return AccessibilityData(
            source: officialData.source ?? existing.source,
            hasElevator: officialData.hasElevator ?? existing.hasElevator,
            hasEscalator: officialData.hasEscalator ?? existing.hasEscalator,
            hasWheelchairRamp: officialData.hasWheelchairRamp ?? existing.hasWheelchairRamp,
            hasAccessibleRestroom: officialData.hasAccessibleRestroom ?? existing.hasAccessibleRestroom,
            isFullyAccessible: officialData.isFullyAccessible ?? existing.isFullyAccessible,
            elevatorLocations: mergeOfficialValues(existing.elevatorLocations, officialData.elevatorLocations),
            accessibleEntrances: mergeOfficialValues(existing.accessibleEntrances, officialData.accessibleEntrances),
            facilityNotes: mergeOfficialValues(existing.facilityNotes, officialData.facilityNotes),
            wheelchairBoardingAssistance: officialData.wheelchairBoardingAssistance ?? existing.wheelchairBoardingAssistance,
            hasTactilePath: officialData.hasTactilePath ?? existing.hasTactilePath,
            hasBrailleSigns: officialData.hasBrailleSigns ?? existing.hasBrailleSigns,
            hasAudioAnnouncement: officialData.hasAudioAnnouncement ?? existing.hasAudioAnnouncement,
            tactilePathCoverage: officialData.tactilePathCoverage ?? existing.tactilePathCoverage,
            hasVisualAnnouncement: officialData.hasVisualAnnouncement ?? existing.hasVisualAnnouncement,
            hasHearingLoop: officialData.hasHearingLoop ?? existing.hasHearingLoop,
            hasSignLanguageDisplay: officialData.hasSignLanguageDisplay ?? existing.hasSignLanguageDisplay,
            hasSimplifiedSignage: officialData.hasSimplifiedSignage ?? existing.hasSimplifiedSignage,
            hasColorCoding: officialData.hasColorCoding ?? existing.hasColorCoding,
            hasPictograms: officialData.hasPictograms ?? existing.hasPictograms
        )
    }
}

private extension StationAccessibility {
    var accessibilityData: AccessibilityData {
        AccessibilityData(
            source: dataSource,
            hasElevator: elevatorAvailability.boolValue,
            hasEscalator: escalatorAvailability.boolValue,
            hasWheelchairRamp: wheelchairRampAvailability.boolValue,
            hasAccessibleRestroom: accessibleRestroomAvailability.boolValue,
            isFullyAccessible: fullAccessibilityAvailability.boolValue,
            elevatorLocations: elevatorLocations.isEmpty ? nil : elevatorLocations,
            accessibleEntrances: accessibleEntrances.isEmpty ? nil : accessibleEntrances,
            facilityNotes: facilityNotes.isEmpty ? nil : facilityNotes,
            wheelchairBoardingAssistance: wheelchairBoardingAssistanceAvailability.boolValue,
            hasTactilePath: tactilePathAvailability.boolValue,
            hasBrailleSigns: brailleSignsAvailability.boolValue,
            hasAudioAnnouncement: audioAnnouncementAvailability.boolValue,
            tactilePathCoverage: tactilePathCoverage > 0 ? tactilePathCoverage : nil,
            hasVisualAnnouncement: visualAnnouncementAvailability.boolValue,
            hasHearingLoop: hearingLoopAvailability.boolValue,
            hasSignLanguageDisplay: signLanguageDisplayAvailability.boolValue,
            hasSimplifiedSignage: simplifiedSignageAvailability.boolValue,
            hasColorCoding: colorCodingAvailability.boolValue,
            hasPictograms: pictogramsAvailability.boolValue
        )
    }
}

private extension AccessibilityAvailability {
    var boolValue: Bool? {
        switch self {
        case .available:
            return true
        case .unavailable:
            return false
        case .unknown:
            return nil
        }
    }
}

private func mergeOfficialValues(_ existing: [String]?, _ official: [String]?) -> [String]? {
    let values = (existing ?? []) + (official ?? [])
    var seen: Set<String> = []
    let unique = values
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    return unique.isEmpty ? nil : unique
}

private struct AMapExitAccessibilityHints {
    let hasElevator: Bool
    let hasEscalator: Bool
    let hasWheelchairRamp: Bool
    let isAccessible: Bool

    init(text: String) {
        let lowered = text.lowercased()

        hasElevator = text.contains("电梯") ||
            text.contains("直梯") ||
            lowered.contains("elevator")
        hasEscalator = text.contains("扶梯") ||
            lowered.contains("escalator")
        hasWheelchairRamp = text.contains("坡道") ||
            text.contains("无障碍") ||
            lowered.contains("ramp") ||
            lowered.contains("wheelchair")
        isAccessible = hasElevator ||
            hasWheelchairRamp ||
            text.contains("无障碍") ||
            lowered.contains("accessible")
    }
}
