import Foundation
import CoreLocation

final class CityService {
    private let cities = CityService.seedCities

    // Generated from the bundled OSM MetroNetworks (station/line counts reflect the
    // operator-filtered, own-city-only data). Cities are listed only when they have a
    // drawable network. Regenerate via Scripts/import_osm_metro_geometry.rb.
    private static let seedCities: [City] = [
        City(id: "1100", name: "北京", nameEn: "Beijing", namePinyin: "beijing", latitude: 39.9042, longitude: 116.4074, stationCount: 444, lineCount: 33),
        City(id: "3100", name: "上海", nameEn: "Shanghai", namePinyin: "shanghai", latitude: 31.2304, longitude: 121.4737, stationCount: 471, lineCount: 26),
        City(id: "4401", name: "广州", nameEn: "Guangzhou", namePinyin: "guangzhou", latitude: 23.1291, longitude: 113.2644, stationCount: 407, lineCount: 30),
        City(id: "4403", name: "深圳", nameEn: "Shenzhen", namePinyin: "shenzhen", latitude: 22.5431, longitude: 114.0579, stationCount: 372, lineCount: 18),
        City(id: "5101", name: "成都", nameEn: "Chengdu", namePinyin: "chengdu", latitude: 30.5728, longitude: 104.0668, stationCount: 396, lineCount: 20),
        City(id: "3301", name: "杭州", nameEn: "Hangzhou", namePinyin: "hangzhou", latitude: 30.2741, longitude: 120.1551, stationCount: 270, lineCount: 13),
        City(id: "1200", name: "天津", nameEn: "Tianjin", namePinyin: "tianjin", latitude: 39.0842, longitude: 117.2009, stationCount: 239, lineCount: 13),
        City(id: "5000", name: "重庆", nameEn: "Chongqing", namePinyin: "chongqing", latitude: 29.563, longitude: 106.5516, stationCount: 273, lineCount: 13),
        City(id: "4201", name: "武汉", nameEn: "Wuhan", namePinyin: "wuhan", latitude: 30.5928, longitude: 114.3055, stationCount: 293, lineCount: 13),
        City(id: "3201", name: "南京", nameEn: "Nanjing", namePinyin: "nanjing", latitude: 32.0603, longitude: 118.7969, stationCount: 210, lineCount: 13),
        City(id: "6101", name: "西安", nameEn: "Xian", namePinyin: "xian", latitude: 34.3416, longitude: 108.9398, stationCount: 247, lineCount: 13),
        City(id: "3205", name: "苏州", nameEn: "Suzhou", namePinyin: "suzhou", latitude: 31.2989, longitude: 120.5853, stationCount: 235, lineCount: 8),
        City(id: "4101", name: "郑州", nameEn: "Zhengzhou", namePinyin: "zhengzhou", latitude: 34.7466, longitude: 113.6254, stationCount: 136, lineCount: 7),
        City(id: "4301", name: "长沙", nameEn: "Changsha", namePinyin: "changsha", latitude: 28.2282, longitude: 112.9388, stationCount: 140, lineCount: 6),
        City(id: "2101", name: "沈阳", nameEn: "Shenyang", namePinyin: "shenyang", latitude: 41.8057, longitude: 123.4315, stationCount: 67, lineCount: 3),
        City(id: "3702", name: "青岛", nameEn: "Qingdao", namePinyin: "qingdao", latitude: 36.0671, longitude: 120.3826, stationCount: 92, lineCount: 4),
        City(id: "2102", name: "大连", nameEn: "Dalian", namePinyin: "dalian", latitude: 38.914, longitude: 121.6147, stationCount: 101, lineCount: 6),
        City(id: "3302", name: "宁波", nameEn: "Ningbo", namePinyin: "ningbo", latitude: 29.8683, longitude: 121.544, stationCount: 150, lineCount: 7),
        City(id: "3202", name: "无锡", nameEn: "Wuxi", namePinyin: "wuxi", latitude: 31.4912, longitude: 120.3119, stationCount: 91, lineCount: 5),
        City(id: "5301", name: "昆明", nameEn: "Kunming", namePinyin: "kunming", latitude: 24.8801, longitude: 102.8329, stationCount: 103, lineCount: 6),
        City(id: "3601", name: "南昌", nameEn: "Nanchang", namePinyin: "nanchang", latitude: 28.682, longitude: 115.8579, stationCount: 103, lineCount: 4),
        City(id: "3501", name: "福州", nameEn: "Fuzhou", namePinyin: "fuzhou", latitude: 26.0745, longitude: 119.2965, stationCount: 87, lineCount: 5),
        City(id: "3502", name: "厦门", nameEn: "Xiamen", namePinyin: "xiamen", latitude: 24.4798, longitude: 118.0894, stationCount: 69, lineCount: 3),
        City(id: "3401", name: "合肥", nameEn: "Hefei", namePinyin: "hefei", latitude: 31.8206, longitude: 117.229, stationCount: 184, lineCount: 7),
        City(id: "1301", name: "石家庄", nameEn: "Shijiazhuang", namePinyin: "shijiazhuang", latitude: 38.0428, longitude: 114.5149, stationCount: 60, lineCount: 3),
        City(id: "5201", name: "贵阳", nameEn: "Guiyang", namePinyin: "guiyang", latitude: 26.647, longitude: 106.6302, stationCount: 93, lineCount: 4),
        City(id: "2301", name: "哈尔滨", nameEn: "Harbin", namePinyin: "haerbin", latitude: 45.8038, longitude: 126.535, stationCount: 73, lineCount: 3),
        City(id: "2201", name: "长春", nameEn: "Changchun", namePinyin: "changchun", latitude: 43.8171, longitude: 125.3235, stationCount: 60, lineCount: 3),
        City(id: "4501", name: "南宁", nameEn: "Nanning", namePinyin: "nanning", latitude: 22.817, longitude: 108.3669, stationCount: 95, lineCount: 5),
        City(id: "6201", name: "兰州", nameEn: "Lanzhou", namePinyin: "lanzhou", latitude: 36.0611, longitude: 103.8343, stationCount: 26, lineCount: 2),
        City(id: "6501", name: "乌鲁木齐", nameEn: "Urumqi", namePinyin: "wulumuqi", latitude: 43.8256, longitude: 87.6168, stationCount: 23, lineCount: 1),
        City(id: "1501", name: "呼和浩特", nameEn: "Hohhot", namePinyin: "huhehaote", latitude: 40.8424, longitude: 111.749, stationCount: 44, lineCount: 2),
        City(id: "1401", name: "太原", nameEn: "Taiyuan", namePinyin: "taiyuan", latitude: 37.8706, longitude: 112.5489, stationCount: 46, lineCount: 2),
        City(id: "4419", name: "东莞", nameEn: "Dongguan", namePinyin: "dongguan", latitude: 23.0207, longitude: 113.7518, stationCount: 93, lineCount: 6),
        City(id: "4406", name: "佛山", nameEn: "Foshan", namePinyin: "foshan", latitude: 23.0218, longitude: 113.1219, stationCount: 123, lineCount: 10),
        City(id: "3303", name: "温州", nameEn: "Wenzhou", namePinyin: "wenzhou", latitude: 27.9939, longitude: 120.6994, stationCount: 36, lineCount: 2),
        City(id: "3306", name: "绍兴", nameEn: "Shaoxing", namePinyin: "shaoxing", latitude: 30.0023, longitude: 120.581, stationCount: 41, lineCount: 2),
        City(id: "3203", name: "徐州", nameEn: "Xuzhou", namePinyin: "xuzhou", latitude: 34.2058, longitude: 117.2848, stationCount: 33, lineCount: 2),
        City(id: "3204", name: "常州", nameEn: "Changzhou", namePinyin: "changzhou", latitude: 31.8107, longitude: 119.974, stationCount: 15, lineCount: 1),
        City(id: "3701", name: "济南", nameEn: "Jinan", namePinyin: "jinan", latitude: 36.6512, longitude: 117.1201, stationCount: 46, lineCount: 3),
        City(id: "4103", name: "洛阳", nameEn: "Luoyang", namePinyin: "luoyang", latitude: 34.6197, longitude: 112.454, stationCount: 33, lineCount: 2),
        City(id: "3402", name: "芜湖", nameEn: "Wuhu", namePinyin: "wuhu", latitude: 31.3526, longitude: 118.4331, stationCount: 35, lineCount: 2),
        City(id: "3206", name: "南通", nameEn: "Nantong", namePinyin: "nantong", latitude: 31.9802, longitude: 120.8943, stationCount: 28, lineCount: 1),
        City(id: "3310", name: "台州", nameEn: "Taizhou", namePinyin: "taizhou", latitude: 28.656, longitude: 121.4208, stationCount: 15, lineCount: 1),
        City(id: "3307", name: "金华", nameEn: "Jinhua", namePinyin: "jinhua", latitude: 29.0784, longitude: 119.6474, stationCount: 30, lineCount: 2),
        City(id: "4110", name: "许昌", nameEn: "Xuchang", namePinyin: "xuchang", latitude: 34.0357, longitude: 113.8526, stationCount: 26, lineCount: 1),
        City(id: "3411", name: "滁州", nameEn: "Chuzhou", namePinyin: "chuzhou", latitude: 32.3017, longitude: 118.3068, stationCount: 14, lineCount: 1),
        City(id: "8100", name: "香港", nameEn: "Hong Kong", namePinyin: "xianggang", latitude: 22.3193, longitude: 114.1694, stationCount: 162, lineCount: 22),
        City(id: "8200", name: "澳门", nameEn: "Macau", namePinyin: "aomen", latitude: 22.1987, longitude: 113.5439, stationCount: 15, lineCount: 3),
        City(id: "7101", name: "台北", nameEn: "Taipei", namePinyin: "taibei", latitude: 25.033, longitude: 121.5654, stationCount: 151, lineCount: 10),
        City(id: "7102", name: "高雄", nameEn: "Kaohsiung", namePinyin: "gaoxiong", latitude: 22.6273, longitude: 120.3014, stationCount: 75, lineCount: 3),
        City(id: "7106", name: "桃园", nameEn: "Taoyuan", namePinyin: "taoyuan", latitude: 24.9937, longitude: 121.301, stationCount: 22, lineCount: 1),
        City(id: "7104", name: "台中", nameEn: "Taichung", namePinyin: "taizhong", latitude: 24.1477, longitude: 120.6736, stationCount: 18, lineCount: 1)
    ]

    func getAllCities() -> [City] {
        cities
    }

    func getCity(byID id: String) -> City? {
        cities.first { $0.id == id }
    }

    func findNearestCity(to location: CLLocation) -> City? {
        cities.min { city1, city2 in
            let loc1 = CLLocation(latitude: city1.latitude, longitude: city1.longitude)
            let loc2 = CLLocation(latitude: city2.latitude, longitude: city2.longitude)
            return location.distance(from: loc1) < location.distance(from: loc2)
        }
    }

    /// The city to switch to for a coordinate, or nil to keep the current selection.
    ///
    /// Bounded on purpose: within 80km of the selected city's centre the rider is plausibly still
    /// inside its metro area, and a seam position in adjacent interconnected metros
    /// (Guangzhou/Foshan) must not flip the selection. Beyond that, follow them to the nearest.
    ///
    /// One rule rather than three. The map's locate button, the planner's cross-city fills and the
    /// launch realignment all ask this same question, and each used to carry its own copy of the
    /// answer — including the 80km constant.
    func cityToAdopt(for location: CLLocation, whileSelecting selected: City?) -> City? {
        guard let selected else { return findNearestCity(to: location) }
        let selectedCentre = CLLocation(
            latitude: selected.coordinate.latitude,
            longitude: selected.coordinate.longitude
        )
        guard location.distance(from: selectedCentre) > 80_000,
              let nearest = findNearestCity(to: location),
              nearest.id != selected.id else { return nil }
        return nearest
    }

    /// The city a *place* should be planned against, for places that may not name their own city.
    ///
    /// A known cityID is authoritative — a saved trip or a quick tag knows which network it came
    /// from. A map POI names nothing, so fall back to the bounded rule above: adopt only when the
    /// coordinate is clearly outside the selected city's metro area, because seam places in
    /// adjacent interconnected metros (Guangzhou/Foshan) must keep the rider's selected network.
    ///
    /// Returns nil when the selection is already right, so callers can treat non-nil as "switch".
    /// One rule rather than one per screen: the planner entry page, the map and the search page
    /// all decide this, and they used to decide it in three separate copies.
    func cityToAdopt(
        forPlaceCityID cityID: String?,
        coordinate: CLLocationCoordinate2D,
        whileSelecting selected: City?
    ) -> City? {
        if let cityID {
            guard let city = getCity(byID: cityID), city.id != selected?.id else { return nil }
            return city
        }
        let place = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return cityToAdopt(for: place, whileSelecting: selected)
    }
}
