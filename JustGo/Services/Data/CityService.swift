import Foundation
import CoreLocation

final class CityService {
    private var cachedCities: [City]

    private static let seedCities: [City] = [
        City(id: "automatic", name: "自动", nameEn: "Automatic", namePinyin: "automatic", latitude: 0, longitude: 0, stationCount: 0, lineCount: 0),
        City(id: "1100", name: "北京", nameEn: "Beijing", namePinyin: "beijing", latitude: 39.9042, longitude: 116.4074, stationCount: 324, lineCount: 27),
        City(id: "3100", name: "上海", nameEn: "Shanghai", namePinyin: "shanghai", latitude: 31.2304, longitude: 121.4737, stationCount: 404, lineCount: 21),
        City(id: "4401", name: "广州", nameEn: "Guangzhou", namePinyin: "guangzhou", latitude: 23.1291, longitude: 113.2644, stationCount: 320, lineCount: 16),
        City(id: "4403", name: "深圳", nameEn: "Shenzhen", namePinyin: "shenzhen", latitude: 22.5431, longitude: 114.0579, stationCount: 310, lineCount: 16),
        City(id: "5101", name: "成都", nameEn: "Chengdu", namePinyin: "chengdu", latitude: 30.5728, longitude: 104.0668, stationCount: 280, lineCount: 13),
        City(id: "3301", name: "杭州", nameEn: "Hangzhou", namePinyin: "hangzhou", latitude: 30.2741, longitude: 120.1551, stationCount: 250, lineCount: 12)
    ]

    init() {
        self.cachedCities = Self.seedCities
    }

    func getAllCities() -> [City] {
        cachedCities
    }

    func getCity(byID id: String) -> City? {
        cachedCities.first { $0.id == id }
    }

    func refreshCities() async {
        cachedCities = Self.seedCities
    }

    func findNearestCity(to location: CLLocation) async -> City? {
        cachedCities.min { city1, city2 in
            let loc1 = CLLocation(latitude: city1.latitude, longitude: city1.longitude)
            let loc2 = CLLocation(latitude: city2.latitude, longitude: city2.longitude)
            return location.distance(from: loc1) < location.distance(from: loc2)
        }
    }

}
