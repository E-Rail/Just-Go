import SwiftUI

/// Where the app's data comes from, how it stays current, and the cities it covers. Pushed from
/// Settings, so it owns no navigation stack of its own.
///
/// Updates come first because they are the one thing here a rider acts on; what each city carries,
/// the official links and the attributions are reference below them.
struct TransitDataView: View {
    @Environment(DIContainer.self) private var container
    @Environment(\.openURL) private var openURL
    @State private var coverage: [String: CityDataCoverage] = [:]
    @State private var officialResourceCities: [OfficialTransitResourceCity] = []
    @State private var didLoadOfficialResources = false
    @State private var showClearCacheConfirmation = false
    @State private var didClearCache = false

    /// Only the cities whose pack holds station data (14 of 53). Every city keeps its network for
    /// routing and search; listing an empty pack would put a row in front of nothing.
    private var stationDataCities: [City] {
        container.cityService.getAllCities().filter { city in
            (coverage[city.id] ?? city.dataCoverage).hasStationData
        }
    }

    var body: some View {
        List {
            if let updater = container.cityDataUpdater {
                CityDataUpdatesSection(updater: updater)
                DownloadedCityDataSection(updater: updater, cityService: container.cityService)
            }
            stationDataSection
            officialResourcesSection
            includedSection
            attributionSection
            onThisDeviceSection
        }
        .navigationTitle(AppLocalization.localized("Transit Data"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: container.cityDataUpdater?.revision) {
            await container.cityDataUpdater?.refreshDownloaded()
            let cityIDs = container.cityService.getAllCities().map(\.id)
            async let coverageLoad = container.officialStationData.cityDataCoverage(for: cityIDs)
            async let resourceLoad = container.officialStationData.officialResourceCatalogCities()
            officialResourceCities = await resourceLoad
            didLoadOfficialResources = true
            coverage = await coverageLoad
        }
    }

    // MARK: - Station data

    private var stationDataSection: some View {
        Section {
            ForEach(stationDataCities) { city in
                VStack(alignment: .leading, spacing: 4) {
                    Text(city.localizedName)
                        .font(.body)
                        .fontWeight(.medium)
                    CityCapabilityTags(
                        coverage: coverage[city.id] ?? city.dataCoverage,
                        hasOfficialOnlineStationInformation:
                            container.stationInformationDirectory.servesStationInformation(cityID: city.id)
                    )
                    .equatable()
                }
                .padding(.vertical, 2)
                // The row leads with the city's name but carries icon-and-text chips; unguided,
                // its separator would start under a chip.
                .listSeparatorAtRowLeading()
            }
        } header: {
            Text(AppLocalization.text(
                english: "Station Data by City",
                simplified: "各城市车站数据",
                traditional: "各城市車站資料"
            ))
        } footer: {
            Text(AppLocalization.text(
                english: "Stations matched to official records, with accessibility facts, and with live trains. Every other city routes and searches from its metro network alone.",
                simplified: "与官方记录匹配的车站、有无障碍信息的车站、有实时列车的车站。其他城市仅用线网规划和搜索。",
                traditional: "與官方記錄匹配的車站、有無障礙資訊的車站、有即時列車的車站。其他城市僅用線網規劃和搜尋。"
            ))
        }
    }

    // MARK: - Official resources

    private var officialResourcesSection: some View {
        Section {
            if officialResourceCities.isEmpty && !didLoadOfficialResources {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if officialResourceCities.isEmpty {
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
                    OfficialResourcesDirectoryView(cities: officialResourceCities)
                } label: {
                    detailRow(
                        icon: "link",
                        title: AppLocalization.text(
                            english: "Official Resources",
                            simplified: "官方资源",
                            traditional: "官方資源"
                        ),
                        detail: AppLocalization.text(
                            english: "Official links for 58 reviewed cities. 43 have at least one. Maps and accessibility pages are rarer.",
                            simplified: "58 个已审核城市的官方链接，其中 43 个至少有一条。地图与无障碍页面较少。",
                            traditional: "58 個已審核城市的官方連結，其中 43 個至少有一條。地圖與無障礙頁面較少。"
                        )
                    )
                }
            }
        }
    }

    // MARK: - What's included

    private var includedSection: some View {
        Section {
            detailRow(
                icon: "map.fill",
                title: AppLocalization.localized("Map, station search, and routes"),
                detail: AppLocalization.text(
                    english: "Included metro routing; Apple Maps place search and walking legs",
                    simplified: "内置地铁路线；Apple 地图地点搜索与步行路段",
                    traditional: "內置地鐵路線；Apple 地圖地點搜尋與步行路段"
                )
            )
            detailRow(
                icon: "point.bottomleft.forward.to.point.topright.scurvepath",
                title: AppLocalization.localized("Metro track geometry"),
                detail: AppLocalization.localized("OpenStreetMap physical track geometry")
            )
            detailRow(
                icon: "accessibility",
                title: AppLocalization.localized("Accessibility and station facilities"),
                detail: AppLocalization.localized("Official city packs when public sources exist")
            )
            detailRow(
                icon: "clock.fill",
                title: AppLocalization.localized("Train times"),
                // No bundled pack carries a timetable: operator schedule content must not be
                // committed. First and last trains exist only as a device-side fetch, in the cities
                // that publish one.
                detail: AppLocalization.text(
                    english: "First and last trains fetched from the operator, in cities that publish them",
                    simplified: "在公布数据的城市，首末班车信息从运营方获取",
                    traditional: "在公布資料的城市，首末班車資訊從營運方取得"
                )
            )
        } header: {
            Text(AppLocalization.localized("Essential Rider Information"))
        }
    }

    // MARK: - Attribution

    private var attributionSection: some View {
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
            // The Open Government Data License requires naming the providing agency and linking the
            // licence; the grant is void without it.
            attributionLink(
                title: "臺北大眾捷運股份有限公司 · data.taipei",
                detail: AppLocalization.text(
                    english: "Open Government Data License, Taiwan, v1.0",
                    simplified: "政府资料开放授权条款第 1 版",
                    traditional: "政府資料開放授權條款第 1 版"
                ),
                url: URL(string: "https://data.gov.tw/license")!
            )
        } header: {
            Text(AppLocalization.text(
                english: "Data Attribution",
                simplified: "数据署名",
                traditional: "資料署名"
            ))
        }
    }

    // MARK: - On this device

    /// Last, so scrolling past the reference above never means scrolling through a delete button.
    private var onThisDeviceSection: some View {
        Section {
            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                // Tinted by hand: a destructive `Button` colours its title red but leaves the
                // `Label`'s icon on the accent.
                Label {
                    Text(clearCacheTitle)
                } icon: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
            }
            .alert(clearCacheTitle, isPresented: $showClearCacheConfirmation) {
                Button(clearCacheTitle, role: .destructive) {
                    Task {
                        await container.clearAllCaches()
                        didClearCache = true
                    }
                }
                Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            } message: {
                // What goes and what stays, with no promises about the app's future behaviour.
                Text(AppLocalization.text(
                    english: "Goes: downloaded updates, station information, cached pages. Stays: your saved places, trips and settings.",
                    simplified: "清除：已下载的更新、车站信息、网页缓存。保留：常用地点、行程和设置。",
                    traditional: "清除：已下載的更新、車站資訊、網頁快取。保留：常用地點、行程和設定。"
                ))
            }
        } header: {
            Text(AppLocalization.text(english: "On this device", simplified: "本机数据", traditional: "本機資料"))
        } footer: {
            if didClearCache {
                Text(AppLocalization.text(
                    english: "Cache cleared.",
                    simplified: "缓存已清除。",
                    traditional: "快取已清除。"
                ))
            }
        }
    }

    private var clearCacheTitle: String {
        AppLocalization.text(english: "Clear Cache", simplified: "清除缓存", traditional: "清除快取")
    }

    // MARK: - Rows

    private func detailRow(icon: String, title: String, detail: String) -> some View {
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

    /// A plain-styled `Button`, not a `Link`, for the reason in `SettingsView.linkRow`: these
    /// licence-mandatory attributions must look like the rows around them.
    private func attributionLink(title: String, detail: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
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
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Updates

/// Whether the city data is current, the rider's way to check now, and the automatic switch.
private struct CityDataUpdatesSection: View {
    @Bindable var updater: CityDataUpdater

    var body: some View {
        Section {
            CityDataUpdateStatusRow(updater: updater)
            Button {
                Task { await updater.checkNow() }
            } label: {
                Label(
                    AppLocalization.text(english: "Check for Updates", simplified: "检查更新", traditional: "檢查更新"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(updater.activity == .checking)
            Toggle(
                AppLocalization.text(english: "Update Automatically", simplified: "自动更新", traditional: "自動更新"),
                isOn: $updater.updatesAutomatically
            )
        } header: {
            Text(AppLocalization.text(english: "Updates", simplified: "更新", traditional: "更新"))
        } footer: {
            Text(AppLocalization.text(
                english: "New lines and stations come from Just-Go's open data on GitHub, through mirrors that work in mainland China. Automatic checks run at most every six hours, never in Low Data Mode or during a trip.",
                simplified: "新线路和车站来自 Just-Go 在 GitHub 上的开放数据，经由中国大陆可访问的镜像获取。自动检查最多每六小时一次，低数据模式下或出行途中不会进行。",
                traditional: "新路線和車站來自 Just-Go 在 GitHub 上的開放資料，經由中國大陸可存取的鏡像取得。自動檢查最多每六小時一次，低數據模式下或出行途中不會進行。"
            ))
        }
    }
}

/// One line on where things stand, in the words of the last check.
struct CityDataUpdateStatusRow: View {
    let updater: CityDataUpdater

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if updater.activity == .checking {
                    ProgressView()
                } else {
                    Image(systemName: icon.name)
                        .foregroundStyle(icon.color)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var icon: (name: String, color: Color) {
        switch updater.lastOutcome?.status {
        case .upToDate?:
            return ("checkmark.circle.fill", .green)
        case .checked?:
            return updater.lastOutcome?.failedCityIDs.isEmpty == false
                ? ("exclamationmark.circle.fill", .orange)
                : ("checkmark.circle.fill", .green)
        case .unreachable?:
            return ("wifi.exclamationmark", .orange)
        case .notConfigured?, nil:
            return ("clock", .secondary)
        }
    }

    private var title: String {
        if updater.activity == .checking {
            return AppLocalization.text(english: "Checking for updates…", simplified: "正在检查更新…", traditional: "正在檢查更新…")
        }
        guard let outcome = updater.lastOutcome else {
            return AppLocalization.text(english: "Not checked yet", simplified: "尚未检查", traditional: "尚未檢查")
        }
        switch outcome.status {
        case .upToDate:
            return AppLocalization.text(english: "Up to date", simplified: "已是最新", traditional: "已是最新")
        case .checked:
            let count = outcome.updates.count
            if count == 0 {
                return AppLocalization.text(
                    english: "Some cities could not be updated",
                    simplified: "部分城市未能更新",
                    traditional: "部分城市未能更新"
                )
            }
            return AppLocalization.text(
                english: count == 1 ? "Updated 1 city" : "Updated \(count) cities",
                simplified: "已更新 \(count) 个城市",
                traditional: "已更新 \(count) 個城市"
            )
        case .unreachable:
            return AppLocalization.text(
                english: "Couldn't reach the update server",
                simplified: "无法连接更新服务器",
                traditional: "無法連線更新伺服器"
            )
        case .notConfigured:
            return AppLocalization.text(
                english: "Updates aren't available in this build",
                simplified: "此版本不提供更新",
                traditional: "此版本不提供更新"
            )
        }
    }

    private var detail: String? {
        guard updater.activity != .checking, let outcome = updater.lastOutcome else { return nil }
        let checked = outcome.checkedAt.formatted(.relative(presentation: .named))
        var parts = [AppLocalization.text(english: "Checked \(checked)", simplified: "检查于\(checked)", traditional: "檢查於\(checked)")]
        let failed = outcome.failedCityIDs.count
        if failed > 0 {
            parts.append(AppLocalization.text(
                english: failed == 1 ? "1 city will be tried again next time" : "\(failed) cities will be tried again next time",
                simplified: "\(failed) 个城市将在下次重试",
                traditional: "\(failed) 個城市將在下次重試"
            ))
        }
        return parts.joined(separator: AppLocalization.isChinese ? "。" : ". ")
    }
}

/// One row for the cities running on downloaded data, which can be all 53 after a first update:
/// listed inline they would push everything else on the page out of reach.
private struct DownloadedCityDataSection: View {
    let updater: CityDataUpdater
    let cityService: CityService

    var body: some View {
        if !updater.downloaded.isEmpty {
            Section {
                NavigationLink {
                    UpdatedCitiesView(updater: updater, cityService: cityService)
                } label: {
                    LabeledContent(
                        AppLocalization.text(english: "Updated Cities", simplified: "已更新的城市", traditional: "已更新的城市")
                    ) {
                        Text(verbatim: "\(updater.downloaded.count)")
                    }
                }
            }
        }
    }
}

/// The cities running on downloaded data, what each holds, and what the last update added, cities
/// with new lines first. Swipe to go back to the data that came with the app.
private struct UpdatedCitiesView: View {
    let updater: CityDataUpdater
    let cityService: CityService

    private var cities: [DownloadedCityData] {
        let added = Set(updater.lastOutcome?.updates.filter { !$0.addedLines.isEmpty }.map(\.cityID) ?? [])
        return updater.downloaded.sorted { lhs, rhs in
            let lhsAdded = added.contains(lhs.cityID), rhsAdded = added.contains(rhs.cityID)
            if lhsAdded != rhsAdded { return lhsAdded }
            return lhs.cityID < rhs.cityID
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(cities) { city in
                    row(city)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await updater.restoreIncluded(city.cityID) }
                            } label: {
                                Label(
                                    AppLocalization.text(english: "Use Included", simplified: "改用内置", traditional: "改用內置"),
                                    systemImage: "arrow.uturn.backward"
                                )
                            }
                            .disabled(updater.activity == .checking)
                        }
                }
            } footer: {
                Text(AppLocalization.text(
                    english: "Swipe a city to go back to the data that came with the app until the next update.",
                    simplified: "左滑城市可改用应用内置的数据，直到下次更新。",
                    traditional: "左滑城市可改用 App 內置的資料，直到下次更新。"
                ))
            }
        }
        .navigationTitle(AppLocalization.text(english: "Updated Cities", simplified: "已更新的城市", traditional: "已更新的城市"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ city: DownloadedCityData) -> some View {
        let lastUpdate = updater.lastOutcome?.updates.first { $0.cityID == city.cityID }
        return VStack(alignment: .leading, spacing: 3) {
            Text(cityService.getCity(byID: city.cityID)?.localizedName ?? city.cityID)
                .font(.body)
                .fontWeight(.medium)
            Text(summary(city))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let added = lastUpdate?.addedLines, !added.isEmpty {
                let names = added.map(\.localized).joined(separator: AppLocalization.isChinese ? "、" : ", ")
                Text(AppLocalization.text(english: "New: \(names)", simplified: "新增：\(names)", traditional: "新增：\(names)"))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func summary(_ city: DownloadedCityData) -> String {
        let counts = AppLocalization.cityLineSummary(stations: city.stationCount, lines: city.lineCount)
        guard let date = city.snapshot.flatMap(Self.snapshotDate) else { return counts }
        var dayStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)
        dayStyle.timeZone = Self.utc
        let day = date.formatted(dayStyle)
        return AppLocalization.text(
            english: "OpenStreetMap, \(day) · \(counts)",
            simplified: "OpenStreetMap，\(day) · \(counts)",
            traditional: "OpenStreetMap，\(day) · \(counts)"
        )
    }

    /// `YYYY-MM-DD`, a calendar day with no zone: read and shown in UTC so it is the same day
    /// everywhere.
    private static func snapshotDate(_ value: String) -> Date? {
        var strategy = Date.ISO8601FormatStyle().year().month().day()
        strategy.timeZone = utc
        return try? Date(value, strategy: strategy)
    }

    private static let utc = TimeZone(identifier: "UTC") ?? .current
}

struct OfficialResourcesDirectoryView: View {
    let cities: [OfficialTransitResourceCity]
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?

    private var filteredCities: [OfficialTransitResourceCity] {
        let query = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cities }
        // Folded like station search, so 中环 finds Hong Kong's 中環.
        let needle = searchFoldedName(query)
        func matches(_ text: String) -> Bool { searchFoldedName(text).contains(needle) }
        return cities.filter { city in
            matches(city.localizedName) ||
                matches(city.name) ||
                matches(city.nameEn) ||
                city.allResources.contains { resource in
                    matches(resource.provider) || matches(resource.kind.localizedTitle)
                } ||
                city.stationResources.contains { station in
                    matches(station.localizedName) ||
                        matches(station.stationName) ||
                        matches(station.stationNameEn)
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
                // A name over a row of icon-and-count badges: the city-pack row's shape, and the
                // same separator guide.
                .listSeparatorAtRowLeading()
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
        .onChange(of: searchText) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                debouncedQuery = newValue
            }
        }
    }

    private func resourceCountBadge(icon: String, count: Int) -> some View {
        Label("\(count)", systemImage: icon)
            .font(.caption2)
            .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
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
                    english: "Checked \(city.verifiedAt). These are the operator's own maps. Just-Go adds no station layouts or door positions.",
                    simplified: "核对于 \(city.verifiedAt)。这些是运营方自己的地图，我们不会另行标注站内路线或车门位置。",
                    traditional: "核對於 \(city.verifiedAt)。這些是營運方自己的地圖，我們不會另行標註站內路線或車門位置。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(city.localizedName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CityCapabilityTags: View, Equatable {
    let coverage: CityDataCoverage
    /// True where accessibility and facility facts come live from the operator (Beijing): the
    /// bundled metric reads 0 there, which would contradict every station page.
    var hasOfficialOnlineStationInformation: Bool = false

    private struct Tag: Identifiable {
        let id: String
        let title: String
        let status: CityDataCapabilityStatus
    }

    /// Three tags: a city row is a compact summary, and the full table lives on the city's page.
    private var tags: [Tag] {
        let access = hasOfficialOnlineStationInformation
            ? Tag(
                id: "access",
                title: AppLocalization.text(english: "Access · Online", simplified: "无障碍 · 在线", traditional: "無障礙 · 線上"),
                status: .available
            )
            : Tag(
                id: "access",
                title: coverageTitle(AppLocalization.localized("Access"), metric: coverage.accessibility),
                status: coverage.accessibility.status()
            )
        return [
            Tag(
                id: "matched",
                title: coverageTitle(
                    AppLocalization.text(english: "Matched", simplified: "匹配", traditional: "匹配"),
                    metric: coverage.matchedStations
                ),
                status: coverage.matchedStations.status()
            ),
            access,
            Tag(
                id: "live",
                title: coverageTitle(
                    AppLocalization.text(english: "Live", simplified: "实时", traditional: "即時"),
                    metric: coverage.liveArrivals
                ),
                status: coverage.liveArrivals.status()
            )
        ]
    }

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(tags) { tag in
                capabilityTag(title: tag.title, status: tag.status)
            }
        }
        .padding(.top, 2)
    }

    private func coverageTitle(_ title: String, metric: CityCoverageMetric) -> String {
        "\(title) \(metric.displayText)"
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
