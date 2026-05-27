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
    var stationAssets: [CityPackStationAsset] = []
    var serviceStatus: CityPackServiceStatus?

    private let aMapService: AMapService

    init(aMapService: AMapService) {
        self.aMapService = aMapService
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

        var lookupErrors: [Error] = []

        for line in station.lines {
            do {
                let lineArrivals = try await aMapService.getTrainTimes(
                    lineID: line.lineID,
                    stationID: station.stationID
                )
                arrivals.append(contentsOf: lineArrivals)
            } catch {
                lookupErrors.append(error)
            }
        }

        arrivals.sort {
            ($0.minutesRemaining ?? Int.max) < ($1.minutesRemaining ?? Int.max)
        }

        if arrivals.isEmpty {
            errorMessage = preferredTrainTimeError(from: lookupErrors)
        }
    }

    func loadCityPack() async {
        guard let station else { return }

        isLoadingCityPack = true
        cityPackStatusMessage = nil
        stationMapStatusMessage = nil
        stationAssets = []
        serviceStatus = nil
        defer { isLoadingCityPack = false }

        let status = await aMapService.loadCityPack(for: station.cityID)
        switch status {
        case .loaded:
            self.station = await aMapService.enrichStationFromCityPack(station)
            stationMap = await aMapService.stationMapFromCityPack(for: station)
            stationAssets = await aMapService.stationAssetsFromCityPack(for: station)
            serviceStatus = await aMapService.stationServiceStatusFromCityPack(for: station)
            cityPackStatusMessage = AppLocalization.localized("Official city data downloaded")
            if stationMap != nil {
                stationMapStatusMessage = AppLocalization.localized("Official station map downloaded")
            } else if stationAssets.isEmpty == false {
                stationMapStatusMessage = AppLocalization.localized("Official station images downloaded")
            } else {
                stationMapStatusMessage = AppLocalization.localized("Official station map not collected for this station")
            }
        case .notConfigured:
            cityPackStatusMessage = AppLocalization.localized("Official city data cloud address is not configured")
            stationMapStatusMessage = cityPackStatusMessage
        case .sourcePending:
            cityPackStatusMessage = AppLocalization.localized("Official city data source is pending")
            stationMapStatusMessage = cityPackStatusMessage
        case .notAvailable:
            cityPackStatusMessage = AppLocalization.localized("Official city data not available yet")
            stationMapStatusMessage = cityPackStatusMessage
        case .failed:
            cityPackStatusMessage = AppLocalization.localized("Official city data download failed")
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

    private func preferredTrainTimeError(from errors: [Error]) -> String {
        if errors.contains(where: { error in
            guard case .amapScheduleLookupNotEnabled? = error as? RoutePlanningError else { return false }
            return true
        }) {
            return AppLocalization.localized("AMap schedule lookup is not enabled")
        }

        if errors.contains(where: { error in
            guard case .trainScheduleUnavailable? = error as? RoutePlanningError else { return false }
            return true
        }) {
            return AppLocalization.localized("Schedule unavailable")
        }

        return errors.first?.localizedDescription ?? AppLocalization.localized("Schedule unavailable")
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
