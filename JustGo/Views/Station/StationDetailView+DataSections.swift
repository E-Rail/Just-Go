import SwiftUI

extension StationDetailView {
    /// "Station Guide" — the specific entrance/exit guidance riders ask for, plus any authored
    /// platform hints, labeled with a confidence chip. Sits above Train Times.
    var stationGuideSection: some View {
        let exits = viewModel?.accessPoints ?? []
        let platformHints = viewModel?.platformHints ?? []
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(AppLocalization.text(english: "Station Guide", simplified: "进出站指引", traditional: "進出站指引"))
                        .font(.headline)
                    Spacer()
                    DataConfidenceChip(confidence: viewModel?.guideConfidence ?? .unknown, compact: true)
                }

                Text(AppLocalization.text(english: "Exits & entrances", simplified: "出入口", traditional: "出入口"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if viewModel?.isLoadingCityPack == true {
                    ProgressView()
                } else if exits.isEmpty {
                    Text(AppLocalization.text(
                        english: "Specific exit data is not available yet — see the station map below.",
                        simplified: "暂无具体出入口数据，请参考下方站内图。",
                        traditional: "暫無具體出入口資料，請參考下方站內圖。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
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
                    Divider()
                    Text(AppLocalization.text(english: "On the platform", simplified: "站台提示", traditional: "月台提示"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    ForEach(Array(platformHints.enumerated()), id: \.offset) { _, hint in
                        platformHintRow(hint)
                    }
                }

                Text(AppLocalization.text(
                    english: "Tap the station map below for the full layout.",
                    simplified: "点按下方站内图查看完整布局。",
                    traditional: "點按下方站內圖查看完整佈局。"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        let timetableAssets = viewModel?.timetableAssets ?? []
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Train Times"))
                    .font(.headline)

                if viewModel?.isLoading == true {
                    ProgressView()
                } else if arrivals.isEmpty && timetableAssets.isEmpty {
                    Text(viewModel?.errorMessage ?? AppLocalization.localized("Schedule unavailable"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(arrivals) { arrival in
                        ArrivalCountdown(arrival: arrival)
                    }

                    if timetableAssets.isEmpty == false {
                        Text(AppLocalization.localized("Official Timetable Images"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        ForEach(timetableAssets, id: \.assetURL) { asset in
                            stationAssetContent(
                                asset,
                                defaultTitle: AppLocalization.localized("Official timetable image")
                            )
                        }
                    }

                    if let statusMessage = viewModel?.trainTimeStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if arrivals.contains(where: \.hasLiveCountdown) == false {
                        Text(AppLocalization.localized("Shows first/last train times, not live arrival countdowns."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var stationEssentialsSection: some View {
        let station = displayedStation
        let facilities = station.facilities.deduplicatedForDisplay()
        let personalReports = accessibilityReportService.reports(for: station)
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(AppLocalization.localized("Station Essentials"))
                        .font(.headline)
                    Spacer()
                    Button {
                        reportItemType = .elevator
                        reportStatus = .outOfService
                        reportSeverity = .medium
                        reportNote = ""
                        showStationReport = true
                    } label: {
                        Image(systemName: "exclamationmark.bubble")
                            .imageScale(.medium)
                    }
                    .accessibilityLabel(AppLocalization.localized("Report station issue"))
                }

                if !facilities.isEmpty {
                    ForEach(facilities) { facility in
                        facilityRow(facility)
                    }
                } else {
                    Text(AppLocalization.localized("Official station facilities are pending for this station."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !personalReports.isEmpty {
                    Divider()
                    Text(AppLocalization.localized("Your Reports"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    ForEach(personalReports.prefix(3)) { report in
                        Label("\(report.itemType.title): \(report.displayNote)", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(report.status.isProblem ? .orange : .secondary)
                    }
                }

                Text(facilities.isEmpty ? AppLocalization.localized("Source pending") : AppLocalization.localized("Official city data"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    var stationMapSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Station Map"))
                    .font(.headline)

                if viewModel?.isLoadingCityPack == true {
                    ProgressView()
                } else if let stationMap = viewModel?.stationMap {
                    stationMapContent(stationMap)
                } else {
                    Text(AppLocalization.localized("Official 3D station map not collected yet"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let statusMessage = viewModel?.stationMapStatusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                    Text(AppLocalization.localized("Status data is from Beijing Subway official web map, not train arrival countdowns."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func stationMapContent(_ stationMap: CityPackStationMap) -> some View {
        if stationMap.isImage, let url = stationMap.resolvedURL {
            remoteImage(
                url: url,
                title: stationMap.title ?? AppLocalization.localized("Station Map")
            )

            Link(stationMap.title ?? AppLocalization.localized("Open station map"), destination: url)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        } else if let url = stationMap.resolvedURL {
            Link(stationMap.title ?? AppLocalization.localized("Open station map"), destination: url)
                .font(.subheadline)
        } else {
            Text(AppLocalization.localized("Station map could not be loaded"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stationAssetContent(_ asset: CityPackStationAsset, defaultTitle: String) -> some View {
        if asset.isImage, let url = asset.resolvedURL {
            VStack(alignment: .leading, spacing: 6) {
                Text(asset.title ?? defaultTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                remoteImage(
                    url: url,
                    title: asset.title ?? defaultTitle
                )
                Link(AppLocalization.localized("Open official timetable image"), destination: url)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func remoteImage(url: URL, title: String) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
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
            case .failure:
                Text(AppLocalization.localized("Station map could not be loaded"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            @unknown default:
                EmptyView()
            }
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

    var stationReportSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(AppLocalization.localized("Facility"), selection: $reportItemType) {
                        ForEach(VerificationItemType.allCases.filter { $0 != .routeConcern }, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Picker(AppLocalization.localized("Status"), selection: $reportStatus) {
                        ForEach(VerificationStatus.allCases.filter { $0 != .note }, id: \.self) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    Picker(AppLocalization.localized("Severity"), selection: $reportSeverity) {
                        ForEach(AccessibilityReportSeverity.allCases, id: \.self) { severity in
                            Text(severity.title).tag(severity)
                        }
                    }
                    TextEditor(text: $reportNote)
                        .frame(minHeight: 120)
                } header: {
                    Text(AppLocalization.localized("Personal Station Report"))
                } footer: {
                    Text(AppLocalization.localized("This stays on your device and is not shown as official data."))
                }
            }
            .navigationTitle(AppLocalization.localized("Report Station Issue"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { showStationReport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Save")) {
                        accessibilityReportService.createStationReport(
                            cityID: displayedStation.cityID,
                            station: displayedStation,
                            itemType: reportItemType,
                            status: reportStatus,
                            severity: reportSeverity,
                            note: reportNote
                        )
                        showStationReport = false
                    }
                }
            }
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
