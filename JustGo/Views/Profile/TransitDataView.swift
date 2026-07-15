import SwiftUI

@MainActor
private final class TransitDataState: ObservableObject {
    @Published var packStatus: [String: CityPackLoadStatus] = [:]
    @Published var coverage: [String: CityDataCoverage] = [:]
    @Published var cityResources: [String: [ExternalTransitResource]] = [:]
    @Published var downloading: Set<String> = []
    @Published var opCompletedCityIDs: Set<String> = []
}

struct TransitDataView: View {
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = TransitDataState()

    private var cities: [City] {
        container.cityService.getAllCities()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLocalization.localized("Transit Data Sources"))
                                .font(.headline)
                            Text(AppLocalization.text(
                                english: "Included metro networks power rail routes. Apple Maps supplies place search and walking legs; reviewed city packs add station details.",
                                simplified: "内置地铁网络用于轨道路线；Apple 地图提供地点搜索和步行路段，已审核城市包补充车站详情。",
                                traditional: "內置地鐵網絡用於軌道路線；Apple 地圖提供地點搜尋和步行路段，已審核城市包補充車站詳情。"
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    dataCapabilityRow(
                        icon: "map.fill",
                        title: AppLocalization.localized("Map, station search, and routes"),
                        detail: AppLocalization.text(
                            english: "Included metro routing; Apple Maps place search and walking legs",
                            simplified: "内置地铁路线；Apple 地图地点搜索与步行路段",
                            traditional: "內置地鐵路線；Apple 地圖地點搜尋與步行路段"
                        )
                    )
                    dataCapabilityRow(
                        icon: "point.bottomleft.forward.to.point.topright.scurvepath",
                        title: AppLocalization.localized("Metro track geometry"),
                        detail: AppLocalization.localized("OpenStreetMap physical track geometry")
                    )
                    dataCapabilityRow(
                        icon: "accessibility",
                        title: AppLocalization.localized("Accessibility and station facilities"),
                        detail: AppLocalization.localized("Official city packs when public sources exist")
                    )
                    dataCapabilityRow(
                        icon: "clock.fill",
                        title: AppLocalization.localized("Train times"),
                        detail: AppLocalization.localized("Official first/last schedules; live countdown only when an official provider exists")
                    )
                    dataCapabilityRow(
                        icon: "photo.fill",
                        title: AppLocalization.text(
                            english: "Station layouts and media",
                            simplified: "车站布局与媒体",
                            traditional: "車站佈局與媒體"
                        ),
                        detail: AppLocalization.text(
                            english: "Official landing links, licensed media, and private on-device photos are kept separate",
                            simplified: "官方页面链接、许可媒体与设备上的私人照片分别管理",
                            traditional: "官方頁面連結、授權媒體與裝置上的私人照片分別管理"
                        )
                    )
                } header: {
                    Text(AppLocalization.localized("Essential Rider Information"))
                } footer: {
                    Text(AppLocalization.localized("Unavailable data is shown honestly instead of guessed."))
                }

                Section {
                    attributionLink(
                        title: AppLocalization.text(
                            english: "OpenStreetMap contributors",
                            simplified: "OpenStreetMap 贡献者",
                            traditional: "OpenStreetMap 貢獻者"
                        ),
                        detail: "ODbL 1.0",
                        url: URL(string: "https://www.openstreetmap.org/copyright")!
                    )
                    attributionLink(
                        title: "MTR Corporation Limited · DATA.GOV.HK",
                        detail: AppLocalization.text(
                            english: "Hong Kong data reuse terms",
                            simplified: "香港数据重用条款",
                            traditional: "香港資料重用條款"
                        ),
                        url: URL(string: "https://data.gov.hk/en/terms-and-conditions")!
                    )
                } header: {
                    Text(AppLocalization.text(
                        english: "Data Attribution",
                        simplified: "数据署名",
                        traditional: "資料署名"
                    ))
                }

                Section {
                    ForEach(cities) { city in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(city.localizedName)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(AppLocalization.cityLineSummary(stations: city.stationCount, lines: city.lineCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                CityCapabilityTags(
                                    coverage: state.coverage[city.id] ?? city.dataCapabilities.coverage
                                )
                                ForEach(state.cityResources[city.id] ?? []) { resource in
                                    cityResourceLink(resource)
                                }
                            }
                            Spacer()
                            cityPackControl(for: city)
                        }
                        .swipeActions {
                            if isDownloadedStatus(state.packStatus[city.id]),
                               !state.downloading.contains(city.id) {
                                Button(role: .destructive) {
                                    Task { await deletePack(city) }
                                } label: {
                                    Label(AppLocalization.localized("Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text(AppLocalization.text(
                        english: "City Data Packs",
                        simplified: "城市数据包",
                        traditional: "城市資料包"
                    ))
                } footer: {
                    Text(AppLocalization.text(
                        english: "Included baselines work offline. Deleting a downloaded update restores the included version.",
                        simplified: "内置基础数据可离线使用。删除下载的更新后会恢复内置版本。",
                        traditional: "內置基礎資料可離線使用。刪除下載的更新後會恢復內置版本。"
                    ))
                }
            }
            .listStyle(.plain)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.localized("Transit Data"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
            .task {
                await refreshPackStatuses()
            }
        }
    }

    @ViewBuilder
    private func cityPackControl(for city: City) -> some View {
        if state.downloading.contains(city.id) {
            ProgressView()
        } else if let status = state.packStatus[city.id] {
            switch status {
            case .available:
                Button(AppLocalization.text(english: "Download", simplified: "下载", traditional: "下載")) {
                    Task { await downloadPack(city) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .updateAvailable:
                Button(AppLocalization.text(english: "Update", simplified: "更新", traditional: "更新")) {
                    Task { await downloadPack(city) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .included:
                Label(
                    AppLocalization.text(english: "Included", simplified: "已内置", traditional: "已內置"),
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption2)
                .foregroundStyle(.green)
            case .loaded(let version):
                Label(
                    AppLocalization.text(
                        english: "Downloaded v\(version)",
                        simplified: "已下载 v\(version)",
                        traditional: "已下載 v\(version)"
                    ),
                    systemImage: "arrow.down.circle.fill"
                )
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .failed:
                Button(AppLocalization.text(english: "Retry", simplified: "重试", traditional: "重試")) {
                    Task { await downloadPack(city) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .notConfigured, .notAvailable, .sourcePending:
                Text(AppLocalization.text(english: "Not available", simplified: "暂不可用", traditional: "暫不可用"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            EmptyView()
        }
    }

    private func refreshPackStatuses() async {
        state.opCompletedCityIDs = []
        let cityIDs = cities.map(\.id)
        let statuses = await container.officialStationData.cityPackStatuses(for: cityIDs)
        let coverage = await container.officialStationData.cityDataCoverage(for: cityIDs)
        let resources = await container.officialStationData.cityExternalResources(for: cityIDs)
        // Merge per city, skipping any the user operated on while this snapshot was in
        // flight (completed ops wrote fresher statuses; in-flight ones will).
        var updatedStatuses = state.packStatus
        for (cityID, status) in statuses
            where !state.opCompletedCityIDs.contains(cityID) &&
                !state.downloading.contains(cityID) {
            updatedStatuses[cityID] = status
        }
        state.packStatus = updatedStatuses
        state.coverage = coverage
        state.cityResources = resources
    }

    private func isDownloadedStatus(_ status: CityPackLoadStatus?) -> Bool {
        switch status {
        case .loaded:
            return true
        case .updateAvailable(_, let installedVersion):
            return installedVersion != nil
        default:
            return false
        }
    }

    private func downloadPack(_ city: City) async {
        state.downloading.insert(city.id)
        let status = await container.officialStationData.downloadCityPack(for: city.id)
        state.downloading.remove(city.id)
        state.opCompletedCityIDs.insert(city.id)
        state.packStatus[city.id] = status
        let coverage = await container.officialStationData.cityDataCoverage(for: [city.id])
        state.coverage.merge(coverage, uniquingKeysWith: { _, fresh in fresh })
    }

    private func deletePack(_ city: City) async {
        state.downloading.insert(city.id)
        let status = await container.officialStationData.deleteCityPack(for: city.id)
        state.downloading.remove(city.id)
        state.opCompletedCityIDs.insert(city.id)
        state.packStatus[city.id] = status
        let coverage = await container.officialStationData.cityDataCoverage(for: [city.id])
        state.coverage.merge(coverage, uniquingKeysWith: { _, fresh in fresh })
    }

    private func dataCapabilityRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func cityResourceLink(_ resource: ExternalTransitResource) -> some View {
        if let url = resource.url {
            Link(destination: url) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(resource.title)
                            .font(.caption)
                        Text(resource.provider)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "safari")
                }
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func attributionLink(title: String, detail: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }
}

struct CityCapabilityTags: View {
    let coverage: CityDataCoverage

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 86), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            coverageTag(
                title: AppLocalization.text(english: "Matched", simplified: "匹配", traditional: "匹配"),
                metric: coverage.matchedStations
            )
            coverageTag(
                title: AppLocalization.localized("Access"),
                metric: coverage.accessibility
            )
            coverageTag(
                title: AppLocalization.text(english: "Live", simplified: "实时", traditional: "即時"),
                metric: coverage.liveArrivals
            )
            coverageTag(
                title: AppLocalization.text(english: "Layout links", simplified: "布局链接", traditional: "佈局連結"),
                metric: coverage.externalLayouts
            )
            coverageTag(
                title: AppLocalization.text(english: "Media", simplified: "媒体", traditional: "媒體"),
                metric: coverage.licensedMedia
            )
            coverageTag(
                title: AppLocalization.text(english: "Indoor", simplified: "站内", traditional: "站內"),
                metric: coverage.verifiedTransferContexts
            )
        }
        .padding(.top, 2)
    }

    private func coverageTag(title: String, metric: CityCoverageMetric) -> some View {
        capabilityTag(title: "\(title) \(metric.displayText)", status: metric.status())
    }

    private func capabilityTag(title: String, status: CityDataCapabilityStatus) -> some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: status.iconName)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2)
        .foregroundStyle(tagColor(for: status))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tagColor(for: status).opacity(0.12), in: Capsule())
        .accessibilityLabel("\(title): \(accessibilityText(for: status))")
    }

    private func tagColor(for status: CityDataCapabilityStatus) -> Color {
        switch status {
        case .available:
            return .green
        case .partial:
            return .orange
        case .pending:
            return .secondary
        }
    }

    private func accessibilityText(for status: CityDataCapabilityStatus) -> String {
        switch status {
        case .available:
            return AppLocalization.localized("Available")
        case .partial:
            return AppLocalization.localized("Partial")
        case .pending:
            return AppLocalization.localized("Pending")
        }
    }
}
