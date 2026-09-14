import Foundation
import CoreLocation

struct City: Identifiable, Codable {
    let id: String
    let name: String
    let nameEn: String
    let namePinyin: String
    let latitude: Double
    let longitude: Double
    let stationCount: Int
    let lineCount: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// What the bundled manifest says this city's pack covers.
    var dataCoverage: CityDataCoverage {
        CityDataCoverage.manifestCoverage[id] ?? .empty
    }
}

struct CityDataCoverage: Codable, Equatable, Sendable {
    let networkStations: Int
    let matchedStations: CityCoverageMetric
    let accessibility: CityCoverageMetric
    let staticSchedules: CityCoverageMetric
    let liveArrivals: CityCoverageMetric
    let externalLayouts: CityCoverageMetric
    let verifiedTransferContexts: CityCoverageMetric

    static let empty = CityDataCoverage(
        networkStations: 0,
        matchedStations: .zero,
        accessibility: .zero,
        staticSchedules: .zero,
        liveArrivals: .zero,
        externalLayouts: .zero,
        verifiedTransferContexts: .zero
    )

    /// Decoded from the bundled `manifest.json` on first touch, which is synchronous and reached
    /// from view bodies: `JustGoApp` calls `prewarm()` off the main thread at launch so a city list
    /// never pays for it mid-render.
    fileprivate static let manifestCoverage: [String: CityDataCoverage] = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else {
            return [:]
        }
        return Dictionary(
            manifest.cities.compactMap { city in city.coverage.map { (city.cityID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }()

    static func prewarm() {
        _ = manifestCoverage
    }

    /// Whether a station pack actually carries anything for this city.
    ///
    /// `networkStations` is deliberately excluded: it counts the routable OSM network, which every
    /// city has. The manifest catalogs 58 cities and only 14 carry station data, so a page keyed on
    /// the catalog advertises 44 packs that hold nothing. `verifiedTransferContexts` is excluded
    /// too: `validate_indoor_maps.rb` pins it at zero everywhere, so it can never be the reason a
    /// city has data.
    var hasStationData: Bool {
        [matchedStations, accessibility, staticSchedules, liveArrivals, externalLayouts]
            .contains { $0.covered > 0 }
    }
}

struct CityCoverageMetric: Codable, Equatable, Sendable {
    let covered: Int
    let total: Int

    static let zero = CityCoverageMetric(covered: 0, total: 0)

    var displayText: String {
        total > 0 ? "\(covered)/\(total)" : "0"
    }

    func status(fallback: CityDataCapabilityStatus = .pending) -> CityDataCapabilityStatus {
        guard total > 0 else { return fallback }
        guard covered > 0 else { return .pending }
        return covered >= total ? .available : .partial
    }
}

enum CityDataCapabilityStatus: String, Codable, Sendable {
    case available
    case partial
    case pending

    var iconName: String {
        switch self {
        case .available:
            return "checkmark.circle.fill"
        case .partial:
            return "circle.lefthalf.filled"
        case .pending:
            return "clock"
        }
    }
}

private struct PackManifest: Decodable {
    let cities: [PackManifestCity]
}

private struct PackManifestCity: Decodable {
    let cityID: String
    let coverage: CityDataCoverage?
}

struct AccessibilityData: Codable {
    let source: String?
    let hasElevator: Bool?
    let hasEscalator: Bool?
    let hasWheelchairRamp: Bool?
    let hasAccessibleRestroom: Bool?
    let isFullyAccessible: Bool?
    let elevatorLocations: [String]?
    let accessibleEntrances: [String]?
    let facilityNotes: [String]?
    let hasTactilePath: Bool?
    let hasAudioAnnouncement: Bool?
    let tactilePathCoverage: Double?
    let hasVisualAnnouncement: Bool?

    init(
        source: String? = nil,
        hasElevator: Bool? = nil,
        hasEscalator: Bool? = nil,
        hasWheelchairRamp: Bool? = nil,
        hasAccessibleRestroom: Bool? = nil,
        isFullyAccessible: Bool? = nil,
        elevatorLocations: [String]? = nil,
        accessibleEntrances: [String]? = nil,
        facilityNotes: [String]? = nil,
        hasTactilePath: Bool? = nil,
        hasAudioAnnouncement: Bool? = nil,
        tactilePathCoverage: Double? = nil,
        hasVisualAnnouncement: Bool? = nil
    ) {
        self.source = source
        self.hasElevator = hasElevator
        self.hasEscalator = hasEscalator
        self.hasWheelchairRamp = hasWheelchairRamp
        self.hasAccessibleRestroom = hasAccessibleRestroom
        self.isFullyAccessible = isFullyAccessible
        self.elevatorLocations = elevatorLocations
        self.accessibleEntrances = accessibleEntrances
        self.facilityNotes = facilityNotes
        self.hasTactilePath = hasTactilePath
        self.hasAudioAnnouncement = hasAudioAnnouncement
        self.tactilePathCoverage = tactilePathCoverage
        self.hasVisualAnnouncement = hasVisualAnnouncement
    }
}
