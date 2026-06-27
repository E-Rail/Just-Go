import SwiftUI

struct TransitDataView: View {
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var packStatus: [String: CityPackLoadStatus] = [:]
    @State private var downloading: Set<String> = []

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
                            Text(AppLocalization.localized("Apple Maps powers place search, transit routes, and route geometry. Official city packs add verified station details where available."))
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
                        detail: AppLocalization.localized("Apple Maps transit routes")
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
                        title: AppLocalization.localized("Station maps and images"),
                        detail: AppLocalization.localized("Official city-pack assets where collected")
                    )
                } header: {
                    Text(AppLocalization.localized("Essential Rider Information"))
                } footer: {
                    Text(AppLocalization.localized("Unavailable data is shown honestly instead of guessed."))
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
                                CityCapabilityTags(city: city)
                            }
                            Spacer()
                            cityPackControl(for: city)
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
                        english: "Download appears only for cities with an official pack in the current manifest.",
                        simplified: "仅当前清单中已有官方数据包的城市会显示下载。",
                        traditional: "只有目前清單中已有官方資料包的城市會顯示下載。"
                    ))
                }
            }
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
        if downloading.contains(city.id) {
            ProgressView()
        } else if let status = packStatus[city.id] {
            switch status {
            case .available:
                Button(AppLocalization.text(english: "Download", simplified: "下载", traditional: "下載")) {
                    Task { await downloadPack(city) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            case .loaded(let version):
                Label("v\(version)", systemImage: "checkmark.circle.fill")
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
        let cityIDs = cities.map(\.id)
        let statuses = await container.officialStationData.cityPackStatuses(for: cityIDs)
        await MainActor.run {
            packStatus = statuses
        }
    }

    private func downloadPack(_ city: City) async {
        downloading.insert(city.id)
        let status = await container.officialStationData.loadCityPack(for: city.id)
        downloading.remove(city.id)
        packStatus[city.id] = status
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
}

struct CityCapabilityTags: View {
    let city: City

    var body: some View {
        HStack(spacing: 6) {
            capabilityTag(title: AppLocalization.localized("Access"), status: city.dataCapabilities.accessibility)
            capabilityTag(title: AppLocalization.localized("Essentials"), status: city.dataCapabilities.stationEssentials)
            capabilityTag(title: AppLocalization.localized("3D Map"), status: city.dataCapabilities.stationMap)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
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
