import SwiftUI

extension StationDetailView {
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
        let resources = viewModel?.externalResources ?? []
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
