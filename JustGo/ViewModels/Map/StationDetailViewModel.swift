import Foundation

@Observable
final class StationDetailViewModel {
    var station: Station?
    var arrivals: [RealTimeArrival] = []
    var isLoading = false
    var isLoadingCityPack = false
    var errorMessage: String?
    var cityPackStatusMessage: String?
    var stationMapStatusMessage: String?
    var stationMap: CityPackStationMap?
    var timetableAssets: [CityPackStationAsset] = []
    var serviceStatus: CityPackServiceStatus?
    var cityPackLoadStatus: CityPackLoadStatus?

    private let officialStationData: OfficialStationDataProviding

    init(officialStationData: OfficialStationDataProviding) {
        self.officialStationData = officialStationData
    }

    func loadStation(_ station: Station) {
        self.station = station
    }

    func loadRealTimeArrivals() async {
        await loadTrainTimes()
    }

    func loadTrainTimes() async {
        guard let station = station else { return }

        isLoading = true
        arrivals = []
        errorMessage = nil
        defer { isLoading = false }

        arrivals = await officialStationData.trainTimes(for: station)

        arrivals.sort {
            ($0.minutesRemaining ?? Int.max) < ($1.minutesRemaining ?? Int.max)
        }

        if arrivals.isEmpty {
            errorMessage = AppLocalization.localized("Official schedule pending for this city/station")
        }
    }

    func loadCityPack() async {
        guard let station else { return }

        isLoadingCityPack = true
        cityPackStatusMessage = nil
        stationMapStatusMessage = nil
        timetableAssets = []
        serviceStatus = nil
        defer { isLoadingCityPack = false }

        let status = await officialStationData.loadCityPack(for: station.cityID)
        cityPackLoadStatus = status
        switch status {
        case .loaded:
            self.station = await officialStationData.enrichStation(station)
            stationMap = await officialStationData.stationMap(for: station)
            timetableAssets = await officialStationData.timetableAssets(for: station)
            serviceStatus = await officialStationData.serviceStatus(for: station)
            cityPackStatusMessage = AppLocalization.localized("Official city data available")
            if stationMap != nil {
                stationMapStatusMessage = AppLocalization.localized("Official station map available")
            } else {
                stationMapStatusMessage = AppLocalization.localized("Official 3D station map not collected for this station")
            }
        case .notConfigured:
            cityPackStatusMessage = AppLocalization.localized("Official city data is not configured; basic station data still works.")
            stationMapStatusMessage = cityPackStatusMessage
        case .sourcePending:
            cityPackStatusMessage = AppLocalization.localized("Official city data is pending for this city.")
            stationMapStatusMessage = cityPackStatusMessage
        case .notAvailable:
            cityPackStatusMessage = AppLocalization.localized("Official city data is not available for this city yet.")
            stationMapStatusMessage = cityPackStatusMessage
        case .failed:
            cityPackStatusMessage = AppLocalization.localized("Official city data could not be reached; basic station data still works.")
            stationMapStatusMessage = cityPackStatusMessage
        }
    }

    var trainTimeStatusMessage: String? {
        guard !arrivals.isEmpty else { return nil }
        return arrivals.contains(where: \.hasLiveCountdown) ? nil : AppLocalization.localized("Live countdown unavailable")
    }

    var accessibilityInfo: StationAccessibility? {
        station?.accessibility
    }

    var scheduleConfidence: DataConfidence {
        if arrivals.contains(where: { $0.source == .officialSchedule || $0.source == .bundledSchedule }) {
            return .official
        }
        return arrivals.isEmpty ? cityPackPendingConfidence : .estimated
    }

    var stationMapConfidence: DataConfidence {
        stationMap == nil ? cityPackPendingConfidence : .official
    }

    var accessibilityConfidence: DataConfidence {
        accessibilityInfo?.hasVerifiedAccessibilityData == true ? .official : cityPackPendingConfidence
    }

    var liveArrivalConfidence: DataConfidence {
        arrivals.contains(where: \.hasLiveCountdown) ? .official : .unavailable
    }

    var isAccessible: Bool {
        accessibilityInfo?.isFullyAccessible ?? false
    }

    var hasElevator: Bool {
        accessibilityInfo?.hasElevator ?? false
    }

    var hasEscalator: Bool {
        accessibilityInfo?.hasEscalator ?? false
    }

    var elevatorStatus: ElevatorStatus {
        accessibilityInfo?.elevatorStatusEnum ?? .unknown
    }

    var accessibilityBadges: [AccessibilityBadge] {
        guard let info = accessibilityInfo else { return [] }

        var badges: [AccessibilityBadge] = []

        if info.hasElevator {
            badges.append(AccessibilityBadge(
                icon: "arrow.up.arrow.down.circle.fill",
                label: "Elevator",
                status: info.elevatorStatusEnum == .operational ? .available : .unavailable
            ))
        }

        if info.hasWheelchairRamp {
            badges.append(AccessibilityBadge(
                icon: "figure.roll",
                label: "Wheelchair Access",
                status: .available
            ))
        }

        if info.hasTactilePath {
            badges.append(AccessibilityBadge(
                icon: "hand.raised.fill",
                label: "Tactile Path",
                status: .available
            ))
        }

        if info.hasAudioAnnouncement {
            badges.append(AccessibilityBadge(
                icon: "speaker.wave.2.fill",
                label: "Audio",
                status: .available
            ))
        }

        if info.hasVisualAnnouncement {
            badges.append(AccessibilityBadge(
                icon: "eye.fill",
                label: "Visual Display",
                status: .available
            ))
        }

        return badges
    }

    private var cityPackPendingConfidence: DataConfidence {
        switch cityPackLoadStatus {
        case .loaded:
            return .sourcePending
        case .sourcePending:
            return .sourcePending
        case .notConfigured, .notAvailable, .failed:
            return .unavailable
        case nil:
            return .unknown
        }
    }
}

struct AccessibilityBadge: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let status: BadgeStatus

    enum BadgeStatus {
        case available
        case unavailable
        case unknown

        var color: String {
            switch self {
            case .available: return "green"
            case .unavailable: return "red"
            case .unknown: return "gray"
            }
        }
    }
}
