import SwiftUI

@MainActor
private final class TransitDataState: ObservableObject {
    @Published var packStatus: [String: CityPackLoadStatus] = [:]
    @Published var coverage: [String: CityDataCoverage] = [:]
    @Published var officialResourceCities: [OfficialTransitResourceCity] = []
    @Published var didLoadOfficialResources = false
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
                    if state.officialResourceCities.isEmpty && !state.didLoadOfficialResources {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if state.officialResourceCities.isEmpty {
                        Label(
                            AppLocalization.text(
                                english: "Official resource catalog unavailable",
                                simplified: "官方资源目录不可用",
                                traditional: "官方資源目錄不可用"
                            ),
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            OfficialResourcesDirectoryView(cities: state.officialResourceCities)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "link")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(AppLocalization.text(
                                        english: "Official Resources",
                                        simplified: "官方资源",
                                        traditional: "官方資源"
                                    ))
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(AppLocalization.text(
                                        english: "Maps, travel information, accessibility, and help for 58 reviewed cities",
                                        simplified: "58 个已审核城市的地图、出行信息、无障碍服务与帮助",
                                        traditional: "58 個已審核城市的地圖、出行資訊、無障礙服務與協助"
                                    ))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(AppLocalization.text(
                        english: "Official pages open inside JustGo after you tap. The temporary viewer does not retain browsing data, and operator files are not treated as verified indoor guidance.",
                        simplified: "点按后，官方页面会在 JustGo 内打开。临时查看器不会保留浏览数据，运营方文件也不会被视为已核实的站内指引。",
                        traditional: "點按後，官方頁面會在 JustGo 內開啟。臨時檢視器不會保留瀏覽資料，營運方檔案也不會被視為已核實的站內指引。"
                    ))
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
                            english: "In-app official resources, licensed media, and private on-device photos are kept separate",
                            simplified: "应用内官方资源、许可媒体与设备上的私人照片分别管理",
                            traditional: "App 內官方資源、授權媒體與裝置上的私人照片分別管理"
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
                                    coverage: state.coverage[city.id] ?? city.dataCapabilities.coverage,
                                    hasOfficialOnlineStationInformation:
                                        BeijingStationInformationProvider.servesStationInformation(forCityID: city.id)
                                )
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
        async let statusLoad = container.officialStationData.cityPackStatuses(for: cityIDs)
        async let coverageLoad = container.officialStationData.cityDataCoverage(for: cityIDs)
        async let resourceLoad = container.officialStationData.officialResourceCatalogCities()
        state.officialResourceCities = await resourceLoad
        state.didLoadOfficialResources = true
        let statuses = await statusLoad
        let coverage = await coverageLoad
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

struct OfficialResourcesDirectoryView: View {
    let cities: [OfficialTransitResourceCity]
    @State private var searchText = ""

    private var filteredCities: [OfficialTransitResourceCity] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cities }
        return cities.filter { city in
            city.localizedName.localizedCaseInsensitiveContains(query) ||
                city.name.localizedCaseInsensitiveContains(query) ||
                city.nameEn.localizedCaseInsensitiveContains(query) ||
                city.allResources.contains { resource in
                    resource.provider.localizedCaseInsensitiveContains(query) ||
                        resource.kind.localizedTitle.localizedCaseInsensitiveContains(query)
                } ||
                city.stationResources.contains { station in
                    station.localizedName.localizedCaseInsensitiveContains(query) ||
                        station.stationName.localizedCaseInsensitiveContains(query) ||
                        station.stationNameEn.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        List {
            ForEach(filteredCities) { city in
                NavigationLink {
                    OfficialResourceCityView(city: city)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(city.localizedName)
                            .font(.body)
                            .fontWeight(.medium)
                        HStack(spacing: 6) {
                            resourceCountBadge(
                                icon: "map",
                                count: city.coverage.maps
                            )
                            resourceCountBadge(
                                icon: "tram.fill",
                                count: city.coverage.travel
                            )
                            resourceCountBadge(
                                icon: "accessibility",
                                count: city.coverage.accessibility
                            )
                            resourceCountBadge(
                                icon: "questionmark.circle",
                                count: city.coverage.help
                            )
                        }
                        if city.reviewStatus == .noVerifiedOfficialResource {
                            Text(AppLocalization.text(
                                english: "No verified official rider resource found in the latest review",
                                simplified: "最近一次审核未找到可核实的官方乘客资源",
                                traditional: "最近一次審核未找到可核實的官方乘客資源"
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .overlay {
            if filteredCities.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle(AppLocalization.text(
            english: "Official Resources",
            simplified: "官方资源",
            traditional: "官方資源"
        ))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            prompt: AppLocalization.text(
                english: "City, station, or provider",
                simplified: "城市、车站或运营方",
                traditional: "城市、車站或營運方"
            )
        )
    }

    private func resourceCountBadge(icon: String, count: Int) -> some View {
        Label("\(count)", systemImage: icon)
            .font(.caption2)
            .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct OfficialResourcePresentation: Identifiable {
    let resource: ExternalTransitResource
    let stationName: String?

    var id: String { "\(stationName ?? "city")|\(resource.id)" }
}

private struct OfficialResourceCityView: View {
    let city: OfficialTransitResourceCity

    private var presentations: [OfficialResourcePresentation] {
        city.resources.map { OfficialResourcePresentation(resource: $0, stationName: nil) } +
            city.stationResources.flatMap { station in
                station.resources.map {
                    OfficialResourcePresentation(resource: $0, stationName: station.localizedName)
                }
            }
    }

    var body: some View {
        List {
            if city.reviewStatus == .noVerifiedOfficialResource {
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(
                            english: "No Verified Official Links",
                            simplified: "暂无已核实的官方链接",
                            traditional: "暫無已核實的官方連結"
                        ),
                        systemImage: "link.badge.plus"
                    )
                } description: {
                    Text(city.reviewNote ?? "")
                }
            } else {
                ForEach(ExternalTransitResourceKind.Group.allCases) { group in
                    let items = presentations
                        .filter { $0.resource.kind.group == group }
                        .sorted {
                            ($0.stationName ?? $0.resource.title).localizedStandardCompare(
                                $1.stationName ?? $1.resource.title
                            ) == .orderedAscending
                        }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { item in
                                OfficialTransitResourceButton(
                                    resource: item.resource,
                                    stationName: item.stationName
                                )
                            }
                        }
                    }
                }
            }

            Section {
                Text(AppLocalization.text(
                    english: "Reviewed \(city.verifiedAt). External maps remain operator content and do not establish a verified indoor path or door position in JustGo.",
                    simplified: "审核日期：\(city.verifiedAt)。外部地图仍属于运营方内容，并不代表 JustGo 已核实站内路径或车门位置。",
                    traditional: "審核日期：\(city.verifiedAt)。外部地圖仍屬於營運方內容，並不代表 JustGo 已核實站內路徑或車門位置。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(city.localizedName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CityCapabilityTags: View {
    let coverage: CityDataCoverage
    /// True for cities whose accessibility/facility facts are served live from the official
    /// operator (Beijing) — the bundled coverage metric honestly reads 0 there, but showing
    /// "0" would contradict the online facilities every station page renders.
    var hasOfficialOnlineStationInformation: Bool = false

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
            if hasOfficialOnlineStationInformation {
                capabilityTag(
                    title: AppLocalization.text(
                        english: "Access · Online",
                        simplified: "无障碍 · 在线",
                        traditional: "無障礙 · 線上"
                    ),
                    status: .available
                )
            } else {
                coverageTag(
                    title: AppLocalization.localized("Access"),
                    metric: coverage.accessibility
                )
            }
            coverageTag(
                title: AppLocalization.text(english: "Live", simplified: "实时", traditional: "即時"),
                metric: coverage.liveArrivals
            )
            coverageTag(
                title: AppLocalization.text(english: "Offline maps", simplified: "离线地图", traditional: "離線地圖"),
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
