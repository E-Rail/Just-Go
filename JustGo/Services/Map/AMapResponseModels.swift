import Foundation
import CoreLocation

struct AMapTransitResponse: Decodable {
    let status: String
    let route: AMapTransitRoute?

    enum CodingKeys: String, CodingKey {
        case status
        case route
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeFlexibleString(forKey: .status) ?? "0"
        route = try? container.decodeIfPresent(AMapTransitRoute.self, forKey: .route)
    }
}

struct AMapTransitRoute: Decodable {
    let transits: [AMapTransitPlan]

    enum CodingKeys: String, CodingKey {
        case transits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transits = container.decodeLossyArray(forKey: .transits)
    }
}

struct AMapTransitPlan: Decodable {
    let duration: String?
    let distance: String?
    let walkingDistance: String?
    let cost: AMapTransitCost?
    let segments: [AMapTransitSegment]

    enum CodingKeys: String, CodingKey {
        case duration
        case distance
        case walkingDistance = "walking_distance"
        case cost
        case segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = container.decodeFlexibleString(forKey: .duration)
        distance = container.decodeFlexibleString(forKey: .distance)
        walkingDistance = container.decodeFlexibleString(forKey: .walkingDistance)
        cost = try? container.decodeIfPresent(AMapTransitCost.self, forKey: .cost)
        segments = container.decodeLossyArray(forKey: .segments)
    }

    var durationValue: TimeInterval {
        TimeInterval(Double(duration ?? cost?.duration ?? "") ?? 0)
    }

    var walkingDistanceValue: Double {
        if let walkingDistanceValue = Double(walkingDistance ?? "") {
            return walkingDistanceValue
        }

        return segments.reduce(0) { total, segment in
            total + (segment.walking?.distanceValue ?? 0)
        }
    }
}

struct AMapTransitCost: Decodable {
    let duration: String?

    enum CodingKeys: String, CodingKey {
        case duration
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            duration = container.decodeFlexibleString(forKey: .duration)
        } else {
            duration = nil
        }
    }
}

struct AMapTransitSegment: Decodable {
    let walking: AMapTransitWalking?
    let bus: AMapTransitBus?

    enum CodingKeys: String, CodingKey {
        case walking
        case bus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walking = try? container.decodeIfPresent(AMapTransitWalking.self, forKey: .walking)
        bus = try? container.decodeIfPresent(AMapTransitBus.self, forKey: .bus)
    }
}

struct AMapTransitWalking: Decodable {
    let distance: String?
    let duration: String?
    let steps: [AMapTransitWalkingStep]

    enum CodingKeys: String, CodingKey {
        case distance
        case duration
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        distance = container.decodeFlexibleString(forKey: .distance)
        duration = container.decodeFlexibleString(forKey: .duration)
        steps = container.decodeLossyArray(forKey: .steps)
    }

    var distanceValue: Double {
        Double(distance ?? "") ?? 0
    }

    var durationValue: TimeInterval {
        TimeInterval(Double(duration ?? "") ?? 0)
    }

    var routeCoordinates: [CodableCoordinate] {
        steps.flatMap(\.routeCoordinates)
    }
}

struct AMapTransitWalkingStep: Decodable {
    let instruction: String?
    let road: String?
    let action: String?
    let assistantAction: String?
    let walkType: String?
    let distance: String?
    let duration: String?
    let polyline: String?

    enum CodingKeys: String, CodingKey {
        case instruction
        case road
        case action
        case assistantAction = "assistant_action"
        case walkType = "walk_type"
        case distance
        case duration
        case polyline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instruction = container.decodeFlexibleString(forKey: .instruction)
        road = container.decodeFlexibleString(forKey: .road)
        action = container.decodeFlexibleString(forKey: .action)
        assistantAction = container.decodeFlexibleString(forKey: .assistantAction)
        walkType = container.decodeFlexibleString(forKey: .walkType)
        distance = container.decodeFlexibleString(forKey: .distance)
        duration = container.decodeFlexibleString(forKey: .duration)
        polyline = container.decodeFlexiblePolylineString(forKey: .polyline)
    }

    var distanceValue: Double {
        Double(distance ?? "") ?? 0
    }

    var durationValue: TimeInterval {
        TimeInterval(Double(duration ?? "") ?? 0)
    }

    var routeCoordinates: [CodableCoordinate] {
        parseSemicolonCoordinates(polyline)
    }

    var hasStairs: Bool {
        walkType == "20" ||
        instruction?.contains("阶梯") == true ||
        instruction?.contains("楼梯") == true ||
        instruction?.localizedCaseInsensitiveContains("stairs") == true ||
        action?.contains("阶梯") == true ||
        action?.contains("楼梯") == true ||
        assistantAction?.contains("阶梯") == true ||
        assistantAction?.contains("楼梯") == true
    }
}

struct AMapTransitBus: Decodable {
    let buslines: [AMapTransitBusLine]

    enum CodingKeys: String, CodingKey {
        case buslines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buslines = container.decodeLossyArray(forKey: .buslines)
    }
}

struct AMapTransitBusLine: Decodable {
    let id: String?
    let name: String?
    let type: String?
    let polyline: String?
    let distance: String?
    let duration: String?
    let viaNum: String?
    let startTime: String?
    let endTime: String?
    let stationStartTime: String?
    let stationEndTime: String?
    let departureStop: AMapTransitBusStop
    let arrivalStop: AMapTransitBusStop
    let viaStops: [AMapTransitBusStop]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case polyline
        case distance
        case duration
        case viaNum = "via_num"
        case startTime = "start_time"
        case endTime = "end_time"
        case stationStartTime = "station_start_time"
        case stationEndTime = "station_end_time"
        case departureStop = "departure_stop"
        case arrivalStop = "arrival_stop"
        case viaStops = "via_stops"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id)
        name = container.decodeFlexibleString(forKey: .name)
        type = container.decodeFlexibleString(forKey: .type)
        polyline = container.decodeFlexiblePolylineString(forKey: .polyline)
        distance = container.decodeFlexibleString(forKey: .distance)
        duration = container.decodeFlexibleString(forKey: .duration)
        viaNum = container.decodeFlexibleString(forKey: .viaNum)
        startTime = container.decodeFlexibleString(forKey: .startTime)
        endTime = container.decodeFlexibleString(forKey: .endTime)
        stationStartTime = container.decodeFlexibleString(forKey: .stationStartTime)
        stationEndTime = container.decodeFlexibleString(forKey: .stationEndTime)
        departureStop = try container.decode(AMapTransitBusStop.self, forKey: .departureStop)
        arrivalStop = try container.decode(AMapTransitBusStop.self, forKey: .arrivalStop)
        viaStops = container.decodeLossyArray(forKey: .viaStops)
    }

    var displayName: String {
        let cleaned = name?.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned! : AppLocalization.localized("Transit")
    }

    var colorHex: String? {
        nil
    }

    var distanceValue: Double {
        Double(distance ?? "") ?? 0
    }

    var durationValue: TimeInterval {
        TimeInterval(Double(duration ?? "") ?? 0)
    }

    var viaNumValue: Int {
        Int(viaNum ?? "") ?? viaStops.count
    }

    var routeCoordinates: [CodableCoordinate] {
        parseSemicolonCoordinates(polyline)
    }

    var stationScheduleText: String? {
        formatScheduleText(first: stationStartTime ?? startTime, last: stationEndTime ?? endTime)
    }
}

struct AMapTransitBusStop: Decodable {
    let id: String
    let name: String
    let location: String?
    let startTime: String?
    let endTime: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case location
        case startTime = "start_time"
        case endTime = "end_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeFlexibleString(forKey: .name) ?? AppLocalization.localized("Station")
        id = container.decodeFlexibleString(forKey: .id) ?? name
        location = container.decodeFlexibleString(forKey: .location)
        startTime = container.decodeFlexibleString(forKey: .startTime)
        endTime = container.decodeFlexibleString(forKey: .endTime)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let location else { return nil }
        return parseCoordinate(location)
    }

    var arrivalTimeText: String? {
        startTime ?? endTime
    }
}

struct AMapBusLineResponse: Decodable {
    let status: String
    let info: String?
    let infocode: String?
    let buslines: [AMapBusLineDetail]

    enum CodingKeys: String, CodingKey {
        case status
        case info
        case infocode
        case buslines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? container.decode(String.self, forKey: .status)) ?? "0"
        info = try? container.decodeIfPresent(String.self, forKey: .info)
        infocode = try? container.decodeIfPresent(String.self, forKey: .infocode)
        buslines = (try? container.decodeIfPresent([AMapBusLineDetail].self, forKey: .buslines)) ?? []
    }
}

struct AMapBusLineDetail: Decodable {
    let id: String?
    let name: String?
    let polyline: String?
    let startStop: String?
    let endStop: String?
    let startTime: String?
    let endTime: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case polyline
        case startStop = "start_stop"
        case endStop = "end_stop"
        case startTime = "start_time"
        case endTime = "end_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id)
        name = container.decodeFlexibleString(forKey: .name)
        polyline = container.decodeFlexibleString(forKey: .polyline)
        startStop = container.decodeFlexibleString(forKey: .startStop)
        endStop = container.decodeFlexibleString(forKey: .endStop)
        startTime = container.decodeFlexibleString(forKey: .startTime)
        endTime = container.decodeFlexibleString(forKey: .endTime)
    }

    var displayName: String? {
        name?.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var routeCoordinates: [CodableCoordinate] {
        parseSemicolonCoordinates(polyline)
    }

    var scheduleText: String? {
        formatScheduleText(first: startTime, last: endTime)
    }

    func matchesSubwayLine(_ line: SubwayLineData) -> Bool {
        guard let displayName else { return true }
        let returnedName = normalizeTransitLineName(displayName)
        return line.scheduleQueryNames.contains { queryName in
            let candidateName = normalizeTransitLineName(queryName)
            return returnedName.contains(candidateName) || candidateName.contains(returnedName)
        }
    }
}

struct AMapPlaceTextResponse: Decodable {
    let status: String
    let pois: [AMapPlacePOI]

    enum CodingKeys: String, CodingKey {
        case status
        case pois
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeFlexibleString(forKey: .status) ?? "0"
        pois = container.decodeFlexiblePOIArray(forKey: .pois)
    }
}

struct AMapInputTipsResponse: Decodable {
    let status: String
    let tips: [AMapInputTip]
}

struct AMapInputTip: Decodable {
    let id: String?
    let name: String
    let type: String?
    let typecode: String?
    let location: String?
    let address: String?
    let adcode: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case typecode
        case location
        case address
        case adcode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id)
        name = container.decodeFlexibleString(forKey: .name) ?? ""
        type = container.decodeFlexibleString(forKey: .type)
        typecode = container.decodeFlexibleString(forKey: .typecode)
        location = container.decodeFlexibleString(forKey: .location)
        address = container.decodeFlexibleString(forKey: .address)
        adcode = container.decodeFlexibleString(forKey: .adcode)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let location else { return nil }
        return parseCoordinate(location)
    }
}

struct AMapRegeocodeResponse: Decodable {
    let status: String
    let regeocode: AMapRegeocode?
}

struct AMapRegeocode: Decodable {
    let formattedAddress: String?
    let addressComponent: AMapAddressComponent

    enum CodingKeys: String, CodingKey {
        case formattedAddress = "formatted_address"
        case addressComponent = "addressComponent"
    }
}

struct AMapAddressComponent: Decodable {
    let citycode: String?
    let adcode: String?

    enum CodingKeys: String, CodingKey {
        case citycode
        case adcode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        citycode = container.decodeFlexibleString(forKey: .citycode)
        adcode = container.decodeFlexibleString(forKey: .adcode)
    }
}

struct AMapSubwayCityListResponse: Decodable {
    let citylist: [AMapSubwayCity]
}

struct AMapSubwayCity: Decodable {
    let spell: String
    let adcode: String
    let cityname: String

    var shortCityName: String {
        var name = cityname
        for suffix in ["市", "地区", "自治州", "盟"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    var defaultCoordinate: CLLocationCoordinate2D {
        cityCoordinateOverrides[adcode] ?? CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
    }
}

struct AMapSubwayPayload: Decodable {
    let i: String
    let s: String
    let l: [AMapSubwayLine]
}

struct AMapSubwayLine: Decodable {
    let st: [AMapSubwayStation]
    let ln: String
    let kn: String?
    let ls: String?
    let cl: String
    let li: String?

    var lineID: String {
        li ?? ls ?? ln
    }

    var displayName: String {
        guard let kn, !kn.isEmpty else { return ln }
        return kn
    }

    var colorHex: String {
        cl
    }

    var rawLineIDs: [String] {
        (li ?? ls ?? lineID)
            .split(separator: "|")
            .map(String.init)
    }

    var stations: [AMapSubwayStation] {
        st
    }

}

struct AMapSubwayStation: Decodable {
    let n: String
    let sid: String?
    let r: String?
    let si: String
    let sl: String?
    let udli: String?
    let poiid: String?
    let sp: String?
    let d: [String]?
    let e: [String]?

    var stationID: String {
        si
    }

    var name: String {
        n
    }

    var pinyin: String? {
        sp
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let sl else { return nil }
        return parseCoordinate(sl)
    }

    var isTransfer: Bool {
        (r ?? "").contains("|") || (udli ?? "").contains(";")
    }

    var poiIDs: [String] {
        [poiid, sid]
            .compactMap { $0 }
            .flatMap { $0.split(separator: "|").map(String.init) }
            .filter { !$0.isEmpty }
    }

    var firstDepartures: [String] {
        d ?? []
    }

    var lastDepartures: [String] {
        e ?? []
    }
}

struct AMapPlacePOI: Decodable {
    let id: String?
    let name: String
    let type: String?
    let typecode: String?
    let location: String?
    let address: String?
    let citycode: String?
    let adcode: String?
    let naviPOIID: String?
    let entrLocation: String?
    let exitLocation: String?
    let navi: AMapPlaceNavi?
    let children: [AMapPlacePOI]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case typecode
        case location
        case address
        case citycode
        case adcode
        case naviPOIID = "navi_poiid"
        case entrLocation = "entr_location"
        case exitLocation = "exit_location"
        case navi
        case children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id)
        name = container.decodeFlexibleString(forKey: .name) ?? ""
        type = container.decodeFlexibleString(forKey: .type)
        typecode = container.decodeFlexibleString(forKey: .typecode)
        location = container.decodeFlexibleString(forKey: .location)
        address = container.decodeFlexibleString(forKey: .address)
        citycode = container.decodeFlexibleString(forKey: .citycode)
        adcode = container.decodeFlexibleString(forKey: .adcode)
        naviPOIID = container.decodeFlexibleString(forKey: .naviPOIID)
        entrLocation = container.decodeFlexibleString(forKey: .entrLocation)
        exitLocation = container.decodeFlexibleString(forKey: .exitLocation)
        navi = try? container.decodeIfPresent(AMapPlaceNavi.self, forKey: .navi)
        children = container.decodeFlexiblePOIArray(forKey: .children)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let location else { return nil }
        return parseCoordinate(location)
    }

    var entranceCoordinate: CLLocationCoordinate2D? {
        guard let entrLocation = entrLocation ?? navi?.entrLocation else { return nil }
        return parseCoordinate(entrLocation)
    }

    var exitCoordinate: CLLocationCoordinate2D? {
        guard let exitLocation = exitLocation ?? navi?.exitLocation else { return nil }
        return parseCoordinate(exitLocation)
    }

    var isSubwayEntranceOrExit: Bool {
        let text = [name, type, typecode]
            .compactMap { $0 }
            .joined(separator: " ")
        return text.contains("出入口") ||
            text.contains("入口") ||
            text.contains("出口") ||
            text.localizedCaseInsensitiveContains("entrance") ||
            text.localizedCaseInsensitiveContains("exit")
    }

    func transitPlace(coordinate: CLLocationCoordinate2D? = nil, source: TransitPlaceSource) -> TransitPlace? {
        guard let coordinate = coordinate ?? self.coordinate else { return nil }
        return TransitPlace(
            name: name,
            coordinate: coordinate,
            uid: id,
            type: type,
            typeCode: typecode,
            address: address,
            cityCode: citycode,
            adCode: adcode,
            naviPOIID: naviPOIID,
            entranceCoordinate: entranceCoordinate,
            source: source
        )
    }
}

struct AMapPlaceNavi: Decodable {
    let naviPOIID: String?
    let entrLocation: String?
    let exitLocation: String?

    enum CodingKeys: String, CodingKey {
        case naviPOIID = "navi_poiid"
        case entrLocation = "entr_location"
        case exitLocation = "exit_location"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        naviPOIID = container.decodeFlexibleString(forKey: .naviPOIID)
        entrLocation = container.decodeFlexibleString(forKey: .entrLocation)
        exitLocation = container.decodeFlexibleString(forKey: .exitLocation)
    }
}

struct AMapPlacePOIList: Decodable {
    let values: [AMapPlacePOI]

    enum CodingKeys: String, CodingKey {
        case poi
        case child
        case children
    }

    init(from decoder: Decoder) throws {
        if let values = try? [AMapPlacePOI](from: decoder) {
            self.values = values
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.poi, .child, .children] {
            if let values = try? container.decodeIfPresent([AMapPlacePOI].self, forKey: key) {
                self.values = values
                return
            }
            if let value = try? container.decodeIfPresent(AMapPlacePOI.self, forKey: key) {
                self.values = [value]
                return
            }
        }

        self.values = []
    }
}

let cityCoordinateOverrides: [String: CLLocationCoordinate2D] = [
    "1100": CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
    "1200": CLLocationCoordinate2D(latitude: 39.3434, longitude: 117.3616),
    "1301": CLLocationCoordinate2D(latitude: 38.0428, longitude: 114.5149),
    "1401": CLLocationCoordinate2D(latitude: 37.8706, longitude: 112.5489),
    "1501": CLLocationCoordinate2D(latitude: 40.8426, longitude: 111.7492),
    "2101": CLLocationCoordinate2D(latitude: 41.8057, longitude: 123.4315),
    "2102": CLLocationCoordinate2D(latitude: 38.9140, longitude: 121.6147),
    "2201": CLLocationCoordinate2D(latitude: 43.8171, longitude: 125.3235),
    "2301": CLLocationCoordinate2D(latitude: 45.8038, longitude: 126.5349),
    "3100": CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
    "3201": CLLocationCoordinate2D(latitude: 32.0603, longitude: 118.7969),
    "3202": CLLocationCoordinate2D(latitude: 31.4912, longitude: 120.3119),
    "3203": CLLocationCoordinate2D(latitude: 34.2058, longitude: 117.2841),
    "3204": CLLocationCoordinate2D(latitude: 31.8107, longitude: 119.9741),
    "3205": CLLocationCoordinate2D(latitude: 31.2989, longitude: 120.5853),
    "3301": CLLocationCoordinate2D(latitude: 30.2741, longitude: 120.1551),
    "3302": CLLocationCoordinate2D(latitude: 29.8683, longitude: 121.5440),
    "3303": CLLocationCoordinate2D(latitude: 27.9949, longitude: 120.6994),
    "3306": CLLocationCoordinate2D(latitude: 30.0303, longitude: 120.5802),
    "3307": CLLocationCoordinate2D(latitude: 29.0792, longitude: 119.6474),
    "3401": CLLocationCoordinate2D(latitude: 31.8206, longitude: 117.2272),
    "3402": CLLocationCoordinate2D(latitude: 31.3529, longitude: 118.4331),
    "3411": CLLocationCoordinate2D(latitude: 32.3016, longitude: 118.3163),
    "3501": CLLocationCoordinate2D(latitude: 26.0745, longitude: 119.2965),
    "3502": CLLocationCoordinate2D(latitude: 24.4798, longitude: 118.0894),
    "3601": CLLocationCoordinate2D(latitude: 28.6829, longitude: 115.8582),
    "3701": CLLocationCoordinate2D(latitude: 36.6512, longitude: 117.1201),
    "3702": CLLocationCoordinate2D(latitude: 36.0671, longitude: 120.3826),
    "4101": CLLocationCoordinate2D(latitude: 34.7466, longitude: 113.6254),
    "4103": CLLocationCoordinate2D(latitude: 34.6197, longitude: 112.4540),
    "4110": CLLocationCoordinate2D(latitude: 34.0355, longitude: 113.8525),
    "4201": CLLocationCoordinate2D(latitude: 30.5928, longitude: 114.3055),
    "4301": CLLocationCoordinate2D(latitude: 28.2282, longitude: 112.9388),
    "4401": CLLocationCoordinate2D(latitude: 23.1291, longitude: 113.2644),
    "4403": CLLocationCoordinate2D(latitude: 22.5431, longitude: 114.0579),
    "4419": CLLocationCoordinate2D(latitude: 23.0207, longitude: 113.7518),
    "4501": CLLocationCoordinate2D(latitude: 22.8170, longitude: 108.3669),
    "5000": CLLocationCoordinate2D(latitude: 29.5630, longitude: 106.5516),
    "5101": CLLocationCoordinate2D(latitude: 30.5728, longitude: 104.0668),
    "5120": CLLocationCoordinate2D(latitude: 30.1286, longitude: 104.6276),
    "5201": CLLocationCoordinate2D(latitude: 26.6470, longitude: 106.6302),
    "5301": CLLocationCoordinate2D(latitude: 25.0389, longitude: 102.7183),
    "6101": CLLocationCoordinate2D(latitude: 34.3416, longitude: 108.9398),
    "6201": CLLocationCoordinate2D(latitude: 36.0611, longitude: 103.8343),
    "6501": CLLocationCoordinate2D(latitude: 43.8256, longitude: 87.6168)
]
