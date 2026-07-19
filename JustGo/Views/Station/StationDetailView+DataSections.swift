import SwiftUI

extension StationDetailView {
    @ViewBuilder
    var officialStationInformationSection: some View {
        if displayedStation.cityID == "1100" || displayedStation.cityID == "8100" {
            let review = viewModel?.officialResourceReview
            let resource = viewModel?.officialStationInformationSourceResource
            let contextResources = review?.resources.filter { $0.kind != .stationInformation } ?? []
            let provider = viewModel?.officialStationInformation?.source.title
                ?? resource?.provider
                ?? contextResources.first?.provider
                ?? AppLocalization.text(
                    english: "Reviewed official sources",
                    simplified: "已审核官方来源",
                    traditional: "已審核官方來源"
                )
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.text(
                                english: "Official Station Information",
                                simplified: "官方车站信息",
                                traditional: "官方車站資訊"
                            ))
                            .font(.headline)
                            Text(provider)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        DataConfidenceChip(
                            confidence: officialStationInformationConfidence(
                                review?.stationInformationStatus,
                                cityID: displayedStation.cityID
                            ),
                            compact: true
                        )
                    }

                    if usesNativeStationInformationSurface {
                        Picker(
                            AppLocalization.text(
                                english: "Station information category",
                                simplified: "车站信息类别",
                                traditional: "車站資訊類別"
                            ),
                            selection: $selectedOfficialInformationCategory
                        ) {
                            ForEach(OfficialStationInformationCategory.allCases) { category in
                                Text(category.title(for: displayedStation.cityID))
                                    .tag(category)
                            }
                        }
                        .pickerStyle(.segmented)

                        nativeOfficialStationInformationContent

                        if let resource {
                            Divider()
                            OfficialTransitResourceButton(resource: resource)
                        }

                        Text(officialStationInformationProvenance)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else if viewModel == nil || viewModel?.isLoadingCityPack == true {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(AppLocalization.text(
                                english: "Matching this station to the official directory",
                                simplified: "正在匹配官方车站目录",
                                traditional: "正在比對官方車站目錄"
                            ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    } else if let review {
                        Label {
                            Text(officialStationInformationStatusText(review.stationInformationStatus))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }

                        if !contextResources.isEmpty {
                            Divider()
                            ForEach(contextResources) { contextResource in
                                OfficialTransitResourceButton(resource: contextResource)
                            }
                            Text(AppLocalization.text(
                                english: "This is official context, not an exact station-information page. It opens in the same temporary JustGo reader.",
                                simplified: "这是官方背景资料，并非本站的精确车站信息页。内容会在同一临时 JustGo 阅读器中打开。",
                                traditional: "這是官方背景資料，並非本站的精確車站資訊頁。內容會在同一臨時 JustGo 閱讀器中開啟。"
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(AppLocalization.text(
                            english: "No reviewed official station-information record is available.",
                            simplified: "暂无已审核的官方车站信息记录。",
                            traditional: "暫無已審核的官方車站資訊記錄。"
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nativeOfficialStationInformationContent: some View {
        if viewModel == nil ||
            (viewModel?.isLoadingOfficialStationInformation == true &&
                viewModel?.officialStationInformation == nil) ||
            (displayedStation.cityID == "8100" &&
                viewModel?.officialStationInformation == nil &&
                viewModel?.isLoading == true) {
            HStack(spacing: 10) {
                ProgressView()
                Text(AppLocalization.text(
                    english: "Loading official station information",
                    simplified: "正在加载官方车站信息",
                    traditional: "正在載入官方車站資訊"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let snapshot = viewModel?.officialStationInformation {
            switch selectedOfficialInformationCategory {
            case .firstLast:
                officialTrainRows(snapshot.trains)
            case .exits:
                officialExitRows(snapshot.exits)
            case .facilities:
                officialFacilityRows(snapshot.facilityGroups)
            }
        } else if let error = viewModel?.officialStationInformationError {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    viewModel?.retryRiderInformation()
                } label: {
                    Label(
                        AppLocalization.text(
                            english: "Retry",
                            simplified: "重试",
                            traditional: "重試"
                        ),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            officialCategoryEmptyState
        }
    }

    @ViewBuilder
    private func officialTrainRows(_ trains: [OfficialStationTrainInformation]) -> some View {
        if displayedStation.cityID == "8100",
           viewModel?.isLoading == true,
           trains.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text(AppLocalization.text(
                    english: "Loading live trains",
                    simplified: "正在加载实时列车",
                    traditional: "正在載入即時列車"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if trains.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                officialCategoryEmptyState
                if displayedStation.cityID == "8100",
                   let message = viewModel?.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        viewModel?.retryRiderInformation()
                    } label: {
                        Label(
                            AppLocalization.text(
                                english: "Retry",
                                simplified: "重试",
                                traditional: "重試"
                            ),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(trains.enumerated()), id: \.element.id) { index, train in
                    if index > 0 {
                        Divider()
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(train.lineColorHex.map(Color.init(hex:)) ?? Color.accentColor)
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(train.lineName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(AppLocalization.text(
                                english: "Toward \(train.destination)",
                                simplified: "开往 \(train.destination)",
                                traditional: "開往 \(train.destination)"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if let liveTime = train.liveTime {
                                Label(liveTime, systemImage: "wave.3.right")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                HStack(spacing: 16) {
                                    if let firstTime = train.firstTime {
                                        trainTimeValue(
                                            label: AppLocalization.localized("First"),
                                            value: firstTime
                                        )
                                    }
                                    if let lastTime = train.lastTime {
                                        trainTimeValue(
                                            label: AppLocalization.localized("Last"),
                                            value: lastTime
                                        )
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func trainTimeValue(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func officialExitRows(_ exits: [OfficialStationExitInformation]) -> some View {
        if exits.isEmpty {
            officialCategoryEmptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(exits.enumerated()), id: \.element.id) { index, exit in
                    if index > 0 {
                        Divider()
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: exit.isAccessible == true
                            ? "figure.roll"
                            : "door.left.hand.open")
                            .foregroundStyle(exit.isAccessible == true ? .green : Color.accentColor)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exit.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            ForEach(exit.details, id: \.self) { detail in
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                }
            }
        }
    }

    @ViewBuilder
    private func officialFacilityRows(
        _ groups: [OfficialStationFacilityGroup]
    ) -> some View {
        if groups.isEmpty {
            officialCategoryEmptyState
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(group.items) { item in
                            let isUnavailable = item.availability == .unavailable
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isUnavailable
                                    ? "xmark.circle.fill"
                                    : "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(isUnavailable ? .red : .green)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.subheadline)
                                    if let location = item.location {
                                        Text(location)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else if isUnavailable {
                                        Text(AppLocalization.localized("Not available"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var officialCategoryEmptyState: some View {
        let categoryTitle = selectedOfficialInformationCategory.title(
            for: displayedStation.cityID
        )
        return Label {
            Text(AppLocalization.text(
                english: "The official source has no verified \(categoryTitle.lowercased()) information for this station.",
                simplified: "官方来源暂无本站的已核实\(categoryTitle)信息。",
                traditional: "官方來源暫無本站的已核實\(categoryTitle)資訊。"
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: selectedOfficialInformationCategory.icon)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var officialStationInformationProvenance: String {
        if displayedStation.cityID == "8100" {
            return AppLocalization.text(
                english: "Live trains online · accessibility data included offline",
                simplified: "列车信息在线获取 · 无障碍数据已离线内置",
                traditional: "列車資訊線上取得 · 無障礙資料已離線內置"
            )
        }
        if case .cached(let fetchedAt) = viewModel?.officialStationInformation?.freshness {
            let age = fetchedAt.formatted(.relative(presentation: .named))
            return AppLocalization.text(
                english: "Official data saved on this device · updated \(age) · service unreachable",
                simplified: "本机保存的官方数据 · 更新于\(age) · 官方服务暂时无法访问",
                traditional: "本機儲存的官方資料 · 更新於\(age) · 官方服務暫時無法連線"
            )
        }
        return AppLocalization.text(
            english: "Official online data · cached on this device · clear it in Settings",
            simplified: "官方在线数据 · 已缓存到本机 · 可在设置中清除",
            traditional: "官方線上資料 · 已快取到本機 · 可在設定中清除"
        )
    }

    private func officialStationInformationConfidence(
        _ status: OfficialTransitStationInformationStatus?,
        cityID: String
    ) -> DataConfidence {
        if cityID == "8100" {
            return viewModel == nil || viewModel?.isLoadingCityPack == true
                ? .unknown
                : .official
        }
        switch status {
        case .exactPage, .officialContextOnly:
            return .official
        case .notOpenForPassengerService, .noCurrentPassengerService:
            return .unavailable
        case nil:
            return .unknown
        }
    }

    private func officialStationInformationStatusText(
        _ status: OfficialTransitStationInformationStatus?
    ) -> String {
        switch status {
        case .exactPage:
            return AppLocalization.text(
                english: "An exact official station page is available.",
                simplified: "已有与本站精确匹配的官方车站页面。",
                traditional: "已有與本站精確匹配的官方車站頁面。"
            )
        case .officialContextOnly:
            return AppLocalization.text(
                english: "The responsible source publishes current line or operator information, but no stable page dedicated to this station.",
                simplified: "相关官方来源发布了当前线路或运营信息，但没有专属于本站的稳定页面。",
                traditional: "相關官方來源發布了目前路線或營運資訊，但沒有專屬於本站的穩定頁面。"
            )
        case .notOpenForPassengerService:
            return AppLocalization.text(
                english: "This station is not open for passenger service. The reviewed official project or opening status appears below.",
                simplified: "本站尚未开放客运服务。下方提供已审核的官方工程或开通状态。",
                traditional: "本站尚未開放客運服務。下方提供已審核的官方工程或開通狀態。"
            )
        case .noCurrentPassengerService:
            return AppLocalization.text(
                english: "The latest official review does not list this point as a current passenger stop. JustGo will not invent a station page.",
                simplified: "最新官方审核未将此地点列为当前客运停靠站。JustGo 不会虚构车站页面。",
                traditional: "最新官方審核未將此地點列為目前客運停靠站。JustGo 不會虛構車站頁面。"
            )
        case nil:
            return AppLocalization.text(
                english: "No reviewed exact station page is available.",
                simplified: "暂无已审核的精确车站页面。",
                traditional: "暫無已審核的精確車站頁面。"
            )
        }
    }

    /// "Station Guide" — the specific entrance/exit guidance riders ask for, plus any authored
    /// platform hints, labeled with a confidence chip. Sits above Train Times.
    @ViewBuilder
    var stationGuideSection: some View {
        let exits = viewModel?.accessPoints ?? []
        let platformHints = viewModel?.platformHints ?? []
        if viewModel?.isLoadingCityPack == true || !exits.isEmpty || !platformHints.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(AppLocalization.text(english: "Station Guide", simplified: "进出站指引", traditional: "進出站指引"))
                            .font(.headline)
                        Spacer()
                        DataConfidenceChip(confidence: viewModel?.guideConfidence ?? .unknown, compact: true)
                    }

                    if viewModel?.isLoadingCityPack == true {
                        ProgressView()
                    } else if !exits.isEmpty {
                        Text(AppLocalization.text(english: "Exits & entrances", simplified: "出入口", traditional: "出入口"))
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ForEach(exits) { exit in
                            HStack(spacing: 8) {
                                Image(systemName: exit.isAccessible ? "figure.roll" : "figure.walk")
                                    .foregroundStyle(exit.isAccessible ? .green : Color.accentColor)
                                    .frame(width: 22)
                                Text(exit.name)
                                    .font(.subheadline)
                                if exit.isAccessible {
                                    Text(AppLocalization.text(english: "Step-free", simplified: "无障碍", traditional: "無障礙"))
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                Spacer()
                            }
                        }
                    }

                    if !platformHints.isEmpty {
                        if !exits.isEmpty {
                            Divider()
                        }
                        Text(AppLocalization.text(english: "On the platform", simplified: "站台提示", traditional: "月台提示"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        ForEach(Array(platformHints.enumerated()), id: \.offset) { _, hint in
                            platformHintRow(hint)
                        }
                    }

                    if viewModel?.externalResources.contains(where: {
                        [.locationMap, .streetMap, .stationLayout].contains($0.kind)
                    }) == true {
                        Text(AppLocalization.text(
                            english: "Use the official link below to view the operator's current layout information.",
                            simplified: "可使用下方官方链接查看运营方当前的布局信息。",
                            traditional: "可使用下方官方連結查看營運方目前的佈局資訊。"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                }
            }
        }
    }

    private func platformHintRow(_ hint: StationPlatformHint) -> some View {
        let parts = [hint.lineName, hint.directionText, hint.boardingCarText, hint.doorSideText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "tram.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.subheadline)
                }
                ForEach(hint.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    var arrivalsSection: some View {
        let arrivals = viewModel?.arrivals ?? []
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Train Times"))
                    .font(.headline)

                if viewModel?.isLoading == true {
                    ProgressView()
                } else if arrivals.isEmpty {
                    Text(viewModel?.errorMessage ?? AppLocalization.localized("Schedule unavailable"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(arrivals) { arrival in
                        ArrivalCountdown(arrival: arrival)
                    }

                    if let statusMessage = viewModel?.trainTimeStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if arrivals.contains(where: \.isLiveArrival) == false {
                        Text(AppLocalization.localized("Shows first/last train times, not live arrival countdowns."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var stationEssentialsSection: some View {
        let station = displayedStation
        let facilities = station.facilities.deduplicatedForDisplay()
        if !facilities.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppLocalization.localized("Station Essentials"))
                        .font(.headline)

                    ForEach(facilities) { facility in
                        facilityRow(facility)
                    }

                    Text(AppLocalization.localized("Official city data"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func facilityRow(_ facility: StationFacility) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: facility.type.iconName)
                .foregroundStyle(facility.type.isAccessibilityCritical ? .green : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(facility.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let location = facility.locationText, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(facility.source.label) • \(facility.verification.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    var stationMapSection: some View {
        let resources = (viewModel?.externalResources ?? []).filter {
            $0.kind != .stationInformation
        }
        let media = viewModel?.licensedMedia ?? []
        if viewModel?.isLoadingCityPack == true || !resources.isEmpty || !media.isEmpty || viewModel?.stationLayoutStatusMessage != nil {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppLocalization.text(
                        english: "Station Resources",
                        simplified: "车站资源",
                        traditional: "車站資源"
                    ))
                        .font(.headline)

                    if viewModel?.isLoadingCityPack == true {
                        ProgressView()
                    } else {
                        ForEach(resources) { resource in
                            OfficialTransitResourceButton(resource: resource, compact: true)
                        }

                        ForEach(media) { item in
                            licensedMediaContent(item)
                        }
                    }

                    if let statusMessage = viewModel?.stationLayoutStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var serviceStatusSection: some View {
        if let status = viewModel?.serviceStatus, status.hasDisplayableStatus {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppLocalization.localized("Station Status"))
                        .font(.headline)

                    if let statusColor = status.statusColor, statusColor.isEmpty == false {
                        Text(AppLocalization.text(
                            english: "Official live station status: \(statusColor)",
                            chinese: "官方实时车站状态：\(localizedStatusColor(statusColor))"
                        ))
                        .font(.subheadline)
                    }

                    ForEach(status.crowdControlWindows, id: \.self) { window in
                        Text(AppLocalization.text(
                            english: "Crowd-control window: \(window)",
                            chinese: "限流时段：\(window)"
                        ))
                        .font(.subheadline)
                    }

                    Text(AppLocalization.text(
                        english: "Status details are separate from train-arrival countdowns.",
                        simplified: "车站状态信息与列车到站倒计时相互独立。",
                        traditional: "車站狀態資訊與列車到站倒數相互獨立。"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func licensedMediaContent(_ media: LicensedStationMedia) -> some View {
        if let url = media.bundledURL {
            VStack(alignment: .leading, spacing: 6) {
                Text(media.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                localStationImage(
                    url: url,
                    title: media.title
                )
                Text("\(media.attribution) · \(media.licenseSPDX)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(media.modifications)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    if let sourceURL = URL(string: media.sourcePageURL) {
                        Link(destination: sourceURL) {
                            Label(
                                AppLocalization.text(
                                    english: "Source page",
                                    simplified: "来源页面",
                                    traditional: "來源頁面"
                                ),
                                systemImage: "arrow.up.right.square"
                            )
                        }
                    }
                    if let licenseURL = URL(string: media.licenseURL) {
                        Link(destination: licenseURL) {
                            Label(media.licenseSPDX, systemImage: "doc.text")
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func localStationImage(url: URL, title: String) -> some View {
        StationAssetImage(url: url) { image in
            Button {
                selectedStationImage = FullScreenStationImage(url: url, title: title)
            } label: {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 160)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(8)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                    }
                }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.localized("Open station image full screen"))
        } failure: {
            Text(AppLocalization.text(
                english: "Station media could not be loaded",
                simplified: "车站媒体无法加载",
                traditional: "車站媒體無法載入"
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func localizedStatusColor(_ color: String) -> String {
        switch color.lowercased() {
        case "green":
            return AppLocalization.text(english: "green", chinese: "绿色")
        case "yellow":
            return AppLocalization.text(english: "yellow", chinese: "黄色")
        case "red":
            return AppLocalization.text(english: "red", chinese: "红色")
        case "black":
            return AppLocalization.text(english: "black", chinese: "黑色")
        default:
            return color
        }
    }

}

private extension Array where Element == StationFacility {
    func deduplicatedForDisplay() -> [StationFacility] {
        uniqued { facility in
            [
                facility.type.rawValue,
                facility.name.normalizedFacilityText,
                (facility.locationText ?? "").normalizedFacilityText,
                facility.source.rawValue,
                facility.verification.rawValue
            ].joined(separator: "|")
        }
    }
}

private extension String {
    var normalizedFacilityText: String {
        String(filter { !$0.isWhitespace })
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .lowercased()
    }
}
