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

    var dataCapabilities: CityDataCapabilities {
        CityDataCapabilities.forCity(id)
    }
}

struct CityDataCapabilities: Equatable {
    let accessibility: CityDataCapabilityStatus
    let stationEssentials: CityDataCapabilityStatus
    let stationMap: CityDataCapabilityStatus
    let coverage: CityDataCoverage

    static func forCity(_ cityID: String) -> CityDataCapabilities {
        manifestCapabilities[cityID] ?? CityDataCapabilities(
            accessibility: .pending,
            stationEssentials: .pending,
            stationMap: .pending,
            coverage: .empty
        )
    }

    /// `manifestCapabilities` is a lazily-computed `static let` — its first touch decodes
    /// `manifest.json` synchronously. `forCity` is called directly from SwiftUI view bodies
    /// (city list rows), so an un-prewarmed first access blocks the main thread mid-render.
    /// Call this once, off the main thread, during app launch so the lazy static is already
    /// populated (a cheap dictionary lookup) by the time any view needs it.
    static func prewarm() {
        _ = manifestCapabilities
    }

    private static let manifestCapabilities: [String: CityDataCapabilities] = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else {
            return [:]
        }
        return Dictionary(
            manifest.cities.map { city in
                let coverage = city.coverage ?? .empty
                return (city.cityID, CityDataCapabilities(
                    accessibility: coverage.accessibility.status(
                        fallback: CityDataCapabilityStatus(manifestValue: city.capabilities.accessibility)
                    ),
                    stationEssentials: coverage.bestTimesStatus(
                        fallback: CityDataCapabilityStatus(manifestValue: city.capabilities.schedules)
                    ),
                    stationMap: coverage.externalLayouts.status(
                        fallback: CityDataCapabilityStatus(manifestValue: city.capabilities.stationMaps)
                    ),
                    coverage: coverage
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }()
}

struct CityDataCoverage: Codable, Equatable, Sendable {
    let networkStations: Int
    let matchedStations: CityCoverageMetric
    let accessibility: CityCoverageMetric
    let staticSchedules: CityCoverageMetric
    let liveArrivals: CityCoverageMetric
    let externalLayouts: CityCoverageMetric
    let licensedMedia: CityCoverageMetric
    let verifiedTransferContexts: CityCoverageMetric

    static let empty = CityDataCoverage(
        networkStations: 0,
        matchedStations: .zero,
        accessibility: .zero,
        staticSchedules: .zero,
        liveArrivals: .zero,
        externalLayouts: .zero,
        licensedMedia: .zero,
        verifiedTransferContexts: .zero
    )

    func bestTimesStatus(fallback: CityDataCapabilityStatus) -> CityDataCapabilityStatus {
        let best = liveArrivals.covered >= staticSchedules.covered ? liveArrivals : staticSchedules
        return best.status(fallback: fallback)
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

    fileprivate init(manifestValue: String) {
        switch manifestValue {
        case "official_static": self = .available
        case "partial_static": self = .partial
        default: self = .pending
        }
    }
}

private struct PackManifest: Decodable {
    let cities: [PackManifestCity]
}

private struct PackManifestCity: Decodable {
    let cityID: String
    let capabilities: PackCapabilities
    let coverage: CityDataCoverage?
}

private struct PackCapabilities: Decodable {
    let accessibility: String
    let schedules: String
    let stationMaps: String
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
