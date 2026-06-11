import Foundation

@Observable
final class StationDetailViewModel {
    var station: Station?
    var arrivals: [RealTimeArrival] = []
    var isLoading = false
    var isLoadingCityPack = false
    var errorMessage: String?
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
            if stationMap != nil {
                stationMapStatusMessage = AppLocalization.localized("Official station map available")
            } else {
                stationMapStatusMessage = AppLocalization.localized("Official 3D station map not collected for this station")
            }
        case .notConfigured:
            stationMapStatusMessage = AppLocalization.localized("Official city data is not configured; basic station data still works.")
        case .sourcePending:
            stationMapStatusMessage = AppLocalization.localized("Official city data is pending for this city.")
        case .notAvailable:
            stationMapStatusMessage = AppLocalization.localized("Official city data is not available for this city yet.")
        case .failed:
            stationMapStatusMessage = AppLocalization.localized("Official city data could not be reached; basic station data still works.")
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
