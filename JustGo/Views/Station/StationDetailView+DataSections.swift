import SwiftUI

extension StationDetailView {
    /// The categories the loaded snapshot actually has data for — so a lines-only source
    /// (Guangzhou) shows just its trains with no empty Exits/Facilities tabs, and the segmented
    /// control appears only when there is more than one thing to switch between.
    private var officialInformationCategories: [OfficialStationInformationCategory] {
        guard let snapshot = viewModel?.officialStationInformation else { return [] }
        var categories: [OfficialStationInformationCategory] = []
        if !snapshot.lines.isEmpty { categories.append(.firstLast) }
        if !snapshot.exits.isEmpty { categories.append(.exits) }
        if !snapshot.facilityGroups.isEmpty { categories.append(.facilities) }
        return categories
    }

    /// The category to render: the picked one while it still has data, otherwise the first that does.
    private var effectiveOfficialInformationCategory: OfficialStationInformationCategory {
        let categories = officialInformationCategories
        if categories.contains(selectedOfficialInformationCategory) {
            return selectedOfficialInformationCategory
        }
        return categories.first ?? selectedOfficialInformationCategory
    }

    @ViewBuilder
    var officialStationInformationSection: some View {
        if usesNativeStationInformationSurface || viewModel?.officialResourceReview != nil {
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
                        let categories = officialInformationCategories
                        if categories.count > 1 {
                            Picker(
                                AppLocalization.text(
                                    english: "Station information category",
                                    simplified: "车站信息类别",
                                    traditional: "車站資訊類別"
                                ),
                                selection: $selectedOfficialInformationCategory
                            ) {
                                ForEach(categories) { category in
                                    Text(category.title(for: displayedStation.cityID))
                                        .tag(category)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

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
                                english: "Official context, not a dedicated station page.",
                                simplified: "官方背景资料，非本站专属页面。",
                                traditional: "官方背景資料，非本站專屬頁面。"
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
            switch effectiveOfficialInformationCategory {
            case .firstLast:
                officialLineRows(snapshot.lines)
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
                .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            officialCategoryEmptyState
        }
    }

    @ViewBuilder
    private func officialLineRows(_ lines: [OfficialStationLineInformation]) -> some View {
        if displayedStation.cityID == "8100",
           viewModel?.isLoading == true,
           lines.isEmpty {
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
        } else if lines.isEmpty {
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
                    .buttonBorderShape(.capsule)
                }
            }
        } else {
            // One block per line holding every direction it serves, rather than a flat list that
            // repeated the line name and its colour on each direction.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 {
                        Divider()
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(line.lineColorHex.map(Color.init(hex:)) ?? Color.accentColor)
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(line.lineName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            ForEach(line.services) { service in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(AppLocalization.text(
                                        english: "Toward \(service.direction)",
                                        simplified: "开往 \(service.direction)",
                                        traditional: "開往 \(service.direction)"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                    if let liveTime = service.liveTime {
                                        Label(liveTime, systemImage: "wave.3.right")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        HStack(spacing: 16) {
                                            if let firstTrain = service.firstTrain {
                                                trainTimeValue(
                                                    label: AppLocalization.localized("First"),
                                                    value: firstTrain
                                                )
                                            }
                                            if let lastTrain = service.lastTrain {
                                                trainTimeValue(
                                                    label: AppLocalization.localized("Last"),
                                                    value: lastTrain
                                                )
                                            }
                                        }
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
        let category = effectiveOfficialInformationCategory
        let categoryTitle = category.title(for: displayedStation.cityID)
        return Label {
            Text(AppLocalization.text(
                english: "No \(categoryTitle.lowercased()) for this station.",
                simplified: "暂无本站\(categoryTitle)。",
                traditional: "暫無本站\(categoryTitle)。"
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: category.icon)
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
                english: "Cached · \(age)",
                simplified: "已缓存 · \(age)",
                traditional: "已快取 · \(age)"
            )
        }
        return AppLocalization.text(
            english: "Live · saved offline",
            simplified: "实时 · 已离线保存",
            traditional: "即時 · 已離線保存"
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
                english: "Exact official station page available.",
                simplified: "已有本站的精确官方页面。",
                traditional: "已有本站的精確官方頁面。"
            )
        case .officialContextOnly:
            return AppLocalization.text(
                english: "Official line/operator context only — no dedicated station page.",
                simplified: "仅有官方线路或运营背景资料，没有本站专属页面。",
                traditional: "僅有官方路線或營運背景資料，沒有本站專屬頁面。"
            )
        case .notOpenForPassengerService:
            return AppLocalization.text(
                english: "Not yet open for passenger service.",
                simplified: "尚未开放客运服务。",
                traditional: "尚未開放客運服務。"
            )
        case .noCurrentPassengerService:
            return AppLocalization.text(
                english: "Not a current passenger stop.",
                simplified: "非当前客运停靠站。",
                traditional: "非目前客運停靠站。"
            )
        case nil:
            return AppLocalization.text(
                english: "No official station page available.",
                simplified: "暂无官方车站页面。",
                traditional: "暫無官方車站頁面。"
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
                            PlatformHintRow(hint: hint)
                        }
                    }

                }
            }
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
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
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
