import Foundation

@Observable
final class StationDetailViewModel {
    var station: Station?
    var arrivals: [RealTimeArrival] = []
    var realtimeAvailability: RealtimeArrivalAvailability = .notConfigured
    var isLoading = false
    var isLoadingCityPack = false
    var errorMessage: String?
    var stationLayoutStatusMessage: String?
    var externalResources: [ExternalTransitResource] = []
    var officialResourceReview: OfficialTransitResourceStation?
    var licensedMedia: [LicensedStationMedia] = []
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
        realtimeAvailability = .notConfigured
        errorMessage = nil
        defer {
            if isCurrentTrainTimesLoad(stationID: stationID, generation: generation) {
                isLoading = false
            }
        }

        let snapshot = await officialStationData.arrivalSnapshot(for: station)
        guard isCurrentTrainTimesLoad(stationID: stationID, generation: generation) else { return }

        realtimeAvailability = snapshot.realtimeAvailability
        arrivals = snapshot.arrivals.sorted {
            ($0.minutesRemaining ?? Int.max) < ($1.minutesRemaining ?? Int.max)
        }

        if arrivals.isEmpty {
            switch realtimeAvailability {
            case .available, .noUpcomingService:
                errorMessage = AppLocalization.text(
                    english: "No upcoming trains are reported right now.",
                    simplified: "目前没有即将到站的列车。",
                    traditional: "目前沒有即將到站的列車。"
                )
            case .temporarilyUnavailable:
                errorMessage = AppLocalization.text(
                    english: "Live arrivals are temporarily unavailable. Try again shortly.",
                    simplified: "实时到站信息暂时不可用，请稍后重试。",
                    traditional: "即時到站資訊暫時不可用，請稍後重試。"
                )
            case .notConfigured:
                errorMessage = AppLocalization.localized("Official schedule pending for this city/station")
            }
        }
    }

    func loadCityPack() async {
        guard let station else { return }
        let stationID = station.id
        let generation = cityPackGeneration

        isLoadingCityPack = true
        stationLayoutStatusMessage = nil
        externalResources = []
        officialResourceReview = nil
        licensedMedia = []
        serviceStatus = nil
        accessGuidance = nil
        defer {
            if isCurrentCityPackLoad(stationID: stationID, generation: generation) {
                isLoadingCityPack = false
            }
        }

        async let statusLoad = officialStationData.loadCityPack(for: station.cityID)
        async let resourceLoad = officialStationData.externalResources(for: station)
        async let reviewLoad = officialStationData.officialResourceReview(for: station)
        let loadedExternalResources = await resourceLoad
        guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
        externalResources = loadedExternalResources
        let loadedReview = await reviewLoad
        guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
        officialResourceReview = loadedReview
        let status = await statusLoad
        guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
        cityPackLoadStatus = status
        switch status {
        case .available:
            stationLayoutStatusMessage = AppLocalization.text(
                english: "Official city data is not loaded yet.",
                simplified: "官方城市数据尚未加载。",
                traditional: "官方城市資料尚未載入。"
            )
        case .included, .loaded, .updateAvailable:
            let enrichedStation = await officialStationData.enrichStation(station)
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            self.station = enrichedStation

            let loadedLicensedMedia = await officialStationData.licensedMedia(for: station)
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            licensedMedia = loadedLicensedMedia

            let loadedServiceStatus = await officialStationData.serviceStatus(for: station)
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            serviceStatus = loadedServiceStatus

            let loadedGuidance = (await officialStationData.stationGuidance(
                cityID: station.cityID,
                stationNames: [station.name]
            ))[station.name]
            guard isCurrentCityPackLoad(stationID: stationID, generation: generation) else { return }
            accessGuidance = loadedGuidance

            if externalResources.contains(where: { [.locationMap, .streetMap, .stationLayout].contains($0.kind) }) {
                stationLayoutStatusMessage = AppLocalization.text(
                    english: "Official external map links are available; verified indoor paths and door positions remain separate.",
                    simplified: "可打开官方外部地图链接；经核实的站内路径与车门位置仍单独标示。",
                    traditional: "可開啟官方外部地圖連結；經核實的站內路徑與車門位置仍單獨標示。"
                )
            } else {
                stationLayoutStatusMessage = AppLocalization.text(
                    english: "Verified indoor layout and door positions are unavailable.",
                    simplified: "暂无经核实的站内布局和车门位置。",
                    traditional: "暫無經核實的站內佈局和車門位置。"
                )
            }
        case .notConfigured:
            stationLayoutStatusMessage = AppLocalization.localized("Official city data is not configured; basic station data still works.")
        case .sourcePending:
            stationLayoutStatusMessage = AppLocalization.localized("Official city data is pending for this city.")
        case .notAvailable:
            stationLayoutStatusMessage = AppLocalization.localized("Official city data is not available for this city yet.")
        case .failed:
            stationLayoutStatusMessage = AppLocalization.localized("Official city data could not be reached; basic station data still works.")
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
        if arrivals.contains(where: \.isLiveArrival) { return nil }
        switch realtimeAvailability {
        case .temporarilyUnavailable:
            return AppLocalization.text(
                english: "Live arrivals are temporarily unavailable. Showing official schedule information.",
                simplified: "实时到站信息暂时不可用，现显示官方时刻信息。",
                traditional: "即時到站資訊暫時不可用，現顯示官方時刻資訊。"
            )
        case .noUpcomingService:
            return AppLocalization.text(
                english: "No live trains are reported right now. Showing official schedule information.",
                simplified: "目前没有实时列车信息，现显示官方时刻信息。",
                traditional: "目前沒有即時列車資訊，現顯示官方時刻資訊。"
            )
        case .available, .notConfigured:
            return AppLocalization.localized("Live countdown unavailable")
        }
    }

    var scheduleConfidence: DataConfidence {
        if arrivals.contains(where: {
            $0.isLiveArrival || $0.source == .officialSchedule || $0.source == .bundledSchedule
        }) {
            return .official
        }
        return arrivals.isEmpty ? cityPackPendingConfidence : .estimated
    }

    var stationMapConfidence: DataConfidence {
        cityPackPendingConfidence
    }

    var accessibilityConfidence: DataConfidence {
        station?.accessibility?.hasVerifiedAccessibilityData == true ? .official : cityPackPendingConfidence
    }

    var liveArrivalConfidence: DataConfidence {
        if arrivals.contains(where: \.isLiveArrival) || realtimeAvailability == .noUpcomingService {
            return .official
        }
        return .unavailable
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
        case .included, .loaded, .updateAvailable, .sourcePending:
            return .sourcePending
        case .notConfigured, .notAvailable, .failed:
            return .unavailable
        case nil:
            return .unknown
        }
    }
}
