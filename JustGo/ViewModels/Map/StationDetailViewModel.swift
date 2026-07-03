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
    var accessGuidance: StationAccessGuidance?

    private let officialStationData: OfficialStationDataProviding
    private var trainTimesGeneration = 0
    private var cityPackGeneration = 0

    init(officialStationData: OfficialStationDataProviding) {
        self.officialStationData = officialStationData
    }

    func loadStation(_ station: Station) {
        trainTimesGeneration += 1
        cityPackGeneration += 1
        self.station = station
    }

    func loadTrainTimes() async {
        guard let station = station else { return }
        let stationID = station.id
        let generation = trainTimesGeneration

        isLoading = true
        arrivals = []
        errorMessage = nil
        defer {
            if isCurrentTrainTimesLoad(stationID: stationID, generation: generation) {
                isLoading = false
            }
        }

        let loadedArrivals = await officialStationData.trainTimes(for: station)
        guard isCurrentTrainTimesLoad(stationID: stationID, generation: generation) else { return }

        arrivals = loadedArrivals.sorted {
            ($0.minutesRemaining ?? Int.max) < ($1.minutesRemaining ?? Int.max)
        }

        if arrivals.isEmpty {
            errorMessage = AppLocalization.localized("Official schedule pending for this city/station")
        }
    }

    func loadCityPack() async {
        guard let station else { return }
        let stationID = station.id
        let generation = cityPackGeneration

        isLoadingCityPack = true
        stationMapStatusMessage = nil
        stationMap = nil
        timetableAssets = []
        serviceStatus = nil
        accessGuidance = nil
        defer {
            if isCurrentCityPackLoad(stationID: stationID, generation: generation) {
                isLoadingCityPack = false
            }
        }

        let status = await officialStationData.loadCityPack(for: station.cityID)
        guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
        cityPackLoadStatus = status
        switch status {
        case .available:
            stationMapStatusMessage = AppLocalization.text(
                english: "Official city data is not loaded yet.",
                simplified: "官方城市数据尚未加载。",
                traditional: "官方城市資料尚未載入。"
            )
        case .loaded:
            let enrichedStation = await officialStationData.enrichStation(station)
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            self.station = enrichedStation

            let loadedStationMap = await officialStationData.stationMap(for: station)
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            stationMap = loadedStationMap

            let loadedTimetableAssets = await officialStationData.timetableAssets(for: station)
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            timetableAssets = loadedTimetableAssets

            let loadedServiceStatus = await officialStationData.serviceStatus(for: station)
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            serviceStatus = loadedServiceStatus

            let loadedGuidance = (await officialStationData.stationGuidance(
                cityID: station.cityID,
                stationNames: [station.name]
            ))[station.name]
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            accessGuidance = loadedGuidance

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

    private func isCurrentTrainTimesLoad(stationID: String, generation: Int) -> Bool {
        station?.id == stationID && trainTimesGeneration == generation
    }

    private func isCurrentCityPackLoad(stationID: String, generation: Int) -> Bool {
        station?.id == stationID && cityPackGeneration == generation
    }

    var trainTimeStatusMessage: String? {
        guard !arrivals.isEmpty else { return nil }
        return arrivals.contains(where: \.hasLiveCountdown) ? nil : AppLocalization.localized("Live countdown unavailable")
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
        station?.accessibility?.hasVerifiedAccessibilityData == true ? .official : cityPackPendingConfidence
    }

    var liveArrivalConfidence: DataConfidence {
        arrivals.contains(where: \.hasLiveCountdown) ? .official : .unavailable
    }

    /// Best-available exits/entrances for the Station Guide section (official or text-estimated).
    var accessPoints: [StationAccessPoint] {
        accessGuidance?.accessPoints ?? []
    }

    var platformHints: [StationPlatformHint] {
        accessGuidance?.platformHints ?? []
    }

    /// Source label for the Station Guide header: the exit-data confidence when present,
    /// otherwise the broader accessibility-data confidence.
    var guideConfidence: DataConfidence {
        if let confidence = accessGuidance?.confidence, confidence == .official || confidence == .estimated {
            return confidence
        }
        return accessibilityConfidence
    }

    private var cityPackPendingConfidence: DataConfidence {
        switch cityPackLoadStatus {
        case .available:
            return .unknown
        case .loaded, .sourcePending:
            return .sourcePending
        case .notConfigured, .notAvailable, .failed:
            return .unavailable
        case nil:
            return .unknown
        }
    }
}
