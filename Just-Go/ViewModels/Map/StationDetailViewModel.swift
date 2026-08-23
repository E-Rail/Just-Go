import Foundation

@Observable
@MainActor
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
    var cityPackLoadStatus: CityPackLoadStatus?
    var accessGuidance: StationAccessGuidance?
    var officialStationInformation: OfficialStationInformationSnapshot?
    var isLoadingOfficialStationInformation = false
    var officialStationInformationError: String?

    private let officialStationData: OfficialStationDataProviding
    private let officialStationInformationProvider: OfficialStationInformationProviding
    private let stationInformationDirectory: StationInformationDirectory
    private var trainTimesGeneration = 0
    private var cityPackGeneration = 0
    private var officialInformationGeneration = 0

    init(
        officialStationData: OfficialStationDataProviding,
        officialStationInformationProvider: OfficialStationInformationProviding,
        stationInformationDirectory: StationInformationDirectory
    ) {
        self.officialStationData = officialStationData
        self.officialStationInformationProvider = officialStationInformationProvider
        self.stationInformationDirectory = stationInformationDirectory
    }

    func loadStation(_ station: Station) {
        trainTimesGeneration += 1
        cityPackGeneration += 1
        officialInformationGeneration += 1
        self.station = station
        officialStationInformation = nil
        officialStationInformationError = nil
        isLoadingOfficialStationInformation = false
    }

    func loadRiderInformation() async {
        guard let stationID = station?.id,
              let cityID = station?.cityID else { return }
        let generation = officialInformationGeneration
        if cityID == "8100" {
            buildHongKongStationInformation()
            await loadTrainTimes()
            guard isCurrentOfficialInformationLoad(
                stationID: stationID,
                generation: generation
            ) else { return }
            buildHongKongStationInformation()
            return
        }
        // Train times and the official online lookup are independent; awaiting them
        // in sequence made every station open wait for both round-trips end to end.
        let onlineInformationLoad = Task { await loadOnlineStationInformation() }
        await loadTrainTimes()
        await onlineInformationLoad.value
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

    func loadOnlineStationInformation() async {
        guard let station,
              let reference = stationInformationDirectory.officialReference(
                  forStationID: station.id,
                  name: station.name,
                  nameEn: station.nameEn
              ) else { return }

        let stationID = station.id
        let generation = officialInformationGeneration
        isLoadingOfficialStationInformation = true
        // Keep any snapshot already on screen: `loadStation` clears it on a station change,
        // so anything still here is this station's own data. Blanking it during a refresh
        // just swaps real content for a spinner.
        officialStationInformationError = nil
        defer {
            if isCurrentOfficialInformationLoad(stationID: stationID, generation: generation) {
                isLoadingOfficialStationInformation = false
            }
        }

        let request = OfficialStationInformationRequest(
            stationID: stationID,
            reference: reference
        )

        do {
            let snapshot = try await requestOfficialInformation(
                request,
                stationID: stationID,
                generation: generation
            )
            guard isCurrentOfficialInformationLoad(
                stationID: stationID,
                generation: generation
            ) else { return }
            officialStationInformation = snapshot
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentOfficialInformationLoad(
                stationID: stationID,
                generation: generation
            ) else { return }
            officialStationInformationError = stationInformationErrorMessage(error)
        }
    }

    /// The first station opened after launch fails intermittently: the cold DNS/TLS handshake to
    /// the official service, racing the app's own launch work, times out or resets while the
    /// endpoint is reachable: leaving a blank "unavailable" card that loads on a manual retry.
    /// Retry transient failures a couple of times (short, growing backoff) before surfacing the
    /// error, so the first load succeeds on its own. Non-transient failures throw immediately, and
    /// a superseded load bails as cancelled rather than overwriting a newer station's data.
    private func requestOfficialInformation(
        _ request: OfficialStationInformationRequest,
        stationID: String,
        generation: Int
    ) async throws -> OfficialStationInformationSnapshot {
        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await officialStationInformationProvider.information(for: request)
            } catch let error as OfficialStationInformationProviderError
                where error.isRetryable && attempt < maxAttempts {
                try await Task.sleep(for: .milliseconds(300 * attempt))
                guard isCurrentOfficialInformationLoad(
                    stationID: stationID,
                    generation: generation
                ) else { throw CancellationError() }
            }
        }
    }

    func retryRiderInformation() {
        Task {
            await loadRiderInformation()
        }
    }

    /// Builds the source-specific reference from a bundled directory entry. The directory says
    /// which source and key; this maps that to the provider's typed request.
    var usesCategorizedStationInformation: Bool {
        guard let station else { return false }
        if station.cityID == "8100" {
            return true
        }
        return stationInformationDirectory.onlineEntry(forStationID: station.id) != nil
    }

    var officialStationInformationSourceResource: ExternalTransitResource? {
        officialResourceReview?.resources.first {
            $0.kind == .stationInformation && $0.scope == .station
        }
    }

    private func buildHongKongStationInformation() {
        guard let station, station.cityID == "8100" else { return }
        let stationID = station.id
        let accessibility = station.accessibility
        let accessibleEntrances = accessibility?.accessibleEntrances ?? []
        let elevatorLocations = accessibility?.elevatorLocations ?? []
        var seenExitNames = Set<String>()
        var exits: [OfficialStationExitInformation] = []

        for entrance in accessibleEntrances where seenExitNames.insert(entrance).inserted {
            var details = [
                AppLocalization.text(
                    english: "Step-free entrance",
                    simplified: "无障碍出入口",
                    traditional: "無障礙出入口"
                )
            ]
            if elevatorLocations.contains(entrance) {
                details.append(AppLocalization.text(
                    english: "Lift access",
                    simplified: "设有升降机",
                    traditional: "設有升降機"
                ))
            }
            exits.append(OfficialStationExitInformation(
                name: entrance,
                details: details,
                isAccessible: true
            ))
        }
        for location in elevatorLocations where seenExitNames.insert(location).inserted {
            exits.append(OfficialStationExitInformation(
                name: location,
                details: [
                    AppLocalization.text(
                        english: "Lift location",
                        simplified: "升降机位置",
                        traditional: "升降機位置"
                    )
                ],
                isAccessible: true
            ))
        }

        let statusItems: [OfficialStationFacilityInformation] = accessibility.map {
            [
                accessibilityFacility(
                    name: AppLocalization.localized("Elevator"),
                    availability: $0.elevatorAvailability
                ),
                accessibilityFacility(
                    name: AppLocalization.localized("Escalator"),
                    availability: $0.escalatorAvailability
                ),
                accessibilityFacility(
                    name: AppLocalization.localized("Wheelchair Ramp"),
                    availability: $0.wheelchairRampAvailability
                ),
                accessibilityFacility(
                    name: AppLocalization.localized("Accessible Restroom"),
                    availability: $0.accessibleRestroomAvailability
                ),
                accessibilityFacility(
                    name: AppLocalization.localized("Tactile Path"),
                    availability: $0.tactilePathAvailability
                ),
                accessibilityFacility(
                    name: AppLocalization.localized("Audio Announcement"),
                    availability: $0.audioAnnouncementAvailability
                ),
                accessibilityFacility(
                    name: AppLocalization.localized("Visual Display"),
                    availability: $0.visualAnnouncementAvailability
                )
            ].compactMap { $0 }
        } ?? []
        let facilityItems = (accessibility?.facilityNotes ?? []).map {
            OfficialStationFacilityInformation(
                name: $0,
                location: nil,
                availability: .available
            )
        }
        var facilityGroups: [OfficialStationFacilityGroup] = []
        if !statusItems.isEmpty {
            facilityGroups.append(OfficialStationFacilityGroup(
                name: AppLocalization.text(
                    english: "Accessibility status",
                    simplified: "无障碍状态",
                    traditional: "無障礙狀態"
                ),
                items: statusItems
            ))
        }
        if !facilityItems.isEmpty {
            facilityGroups.append(OfficialStationFacilityGroup(
                name: AppLocalization.text(
                    english: "Barrier-free facilities",
                    simplified: "无障碍设施",
                    traditional: "無障礙設施"
                ),
                items: facilityItems
            ))
        }
        // Both service times are nil here, so a row's identity collapses to direction|arrival.
        // Two trains on the same line and destination showing the same countdown produce
        // duplicate ForEach ids, which is undefined behavior in SwiftUI. Uniquing happens within
        // a line, since the line name is no longer part of the row's identity.
        var lineOrder: [String] = []
        var colorsByLine: [String: String?] = [:]
        var servicesByLine: [String: [OfficialStationServiceInformation]] = [:]
        for arrival in arrivals {
            if servicesByLine[arrival.lineName] == nil {
                lineOrder.append(arrival.lineName)
                servicesByLine[arrival.lineName] = []
                colorsByLine[arrival.lineName] = arrival.lineColorHex
            }
            servicesByLine[arrival.lineName]?.append(
                OfficialStationServiceInformation(
                    direction: arrival.destination,
                    firstTrain: nil,
                    lastTrain: nil,
                    liveTime: arrival.formattedArrival
                )
            )
        }
        let serviceLines = lineOrder.map { lineName in
            OfficialStationLineInformation(
                lineName: lineName,
                lineColorHex: colorsByLine[lineName] ?? nil,
                services: (servicesByLine[lineName] ?? [])
                    .uniqued(by: \OfficialStationServiceInformation.id)
            )
        }
        officialStationInformation = OfficialStationInformationSnapshot(
            stationID: stationID,
            stationName: station.name,
            source: .hongKongGovernment,
            freshness: .live,
            lines: serviceLines,
            exits: exits,
            facilityGroups: facilityGroups
        )
        officialStationInformationError = nil
        isLoadingOfficialStationInformation = false
    }

    private func accessibilityFacility(
        name: String,
        availability: AccessibilityAvailability
    ) -> OfficialStationFacilityInformation? {
        switch availability {
        case .available:
            return OfficialStationFacilityInformation(
                name: name,
                location: nil,
                availability: .available
            )
        case .unavailable:
            return OfficialStationFacilityInformation(
                name: name,
                location: nil,
                availability: .unavailable
            )
        case .unknown:
            return nil
        }
    }

    private func stationInformationErrorMessage(_ error: Error) -> String {
        guard let providerError = error as? OfficialStationInformationProviderError else {
            return AppLocalization.text(
                english: "Official station information is temporarily unavailable.",
                simplified: "官方车站信息暂时不可用。",
                traditional: "官方車站資訊暫時不可用。"
            )
        }
        switch providerError {
        case .timedOut, .transport, .rateLimited, .httpStatus, .serviceUnavailable:
            return AppLocalization.text(
                english: "The official service is temporarily unavailable. Try again shortly.",
                simplified: "官方服务暂时不可用，请稍后重试。",
                traditional: "官方服務暫時不可用，請稍後重試。"
            )
        case .invalidRequest, .invalidResponse, .responseTooLarge, .contractViolation:
            return AppLocalization.text(
                english: "The official response could not be verified for this station.",
                simplified: "无法核实此车站的官方响应。",
                traditional: "無法核實此車站的官方回應。"
            )
        }
    }

    private func isCurrentTrainTimesLoad(stationID: String, generation: Int) -> Bool {
        station?.id == stationID && trainTimesGeneration == generation
    }

    private func isCurrentCityPackLoad(stationID: String, generation: Int) -> Bool {
        station?.id == stationID && cityPackGeneration == generation
    }

    private func isCurrentOfficialInformationLoad(
        stationID: String,
        generation: Int
    ) -> Bool {
        station?.id == stationID && officialInformationGeneration == generation
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
        // The official online surface carries first/last train times for every live-fetch city.
        // While it is showing them, the chip must agree instead of reporting that this station
        // has no schedule data at all.
        if officialStationInformation?.lines.isEmpty == false {
            return .official
        }
        return arrivals.isEmpty ? cityPackPendingConfidence : .estimated
    }

    var accessibilityConfidence: DataConfidence {
        if station?.accessibility?.hasVerifiedAccessibilityData == true {
            return .official
        }
        // Accessibility facts for the live-fetch cities come from the official online surface,
        // not the bundled pack: Beijing publishes them as facility groups, Shanghai and
        // Guangzhou as per-exit accessibility flags. While that surface is showing either (live
        // or cached), the "Before You Go" chip must agree with it instead of claiming nothing
        // exists.
        if let information = officialStationInformation,
           !information.facilityGroups.isEmpty ||
            information.exits.contains(where: { $0.isAccessible == true }) {
            return .official
        }
        return cityPackPendingConfidence
    }

    var liveArrivalConfidence: DataConfidence {
        if arrivals.contains(where: \.isLiveArrival) || realtimeAvailability == .noUpcomingService {
            return .official
        }
        return .unavailable
    }

    /// Whether live arrivals are a thing this station could have at all. Hong Kong publishes them;
    /// no mainland operator here does, so the chip was a permanent "Not available" telling the
    /// rider nothing about the station they are standing in. A row of dead chips is not honesty,
    /// it is furniture: the ones that remain are the ones that can change.
    var showsLiveArrivalConfidence: Bool {
        realtimeAvailability != .notConfigured
    }

    /// Best-available exits/entrances for the Station Guide section (official or text-estimated).
    var accessPoints: [StationAccessPoint] {
        accessGuidance?.accessPoints ?? []
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
