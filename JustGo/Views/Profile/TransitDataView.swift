import SwiftUI

struct TransitDataView: View {
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

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
                            Text(AppLocalization.localized("AMap powers search, route planning, line geometry, and POIs. Official city packs add verified station details where available."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    dataCapabilityRow(
                        icon: "map.fill",
                        title: "Map, station search, and routes",
                        detail: "AMap plus bundled subway data"
                    )
                    dataCapabilityRow(
                        icon: "accessibility",
                        title: "Accessibility and station facilities",
                        detail: "Official city packs when public sources exist"
                    )
                    dataCapabilityRow(
                        icon: "clock.fill",
                        title: "Train times",
                        detail: "Official first/last schedules; live countdown only when an official provider exists"
                    )
                    dataCapabilityRow(
                        icon: "photo.fill",
                        title: "Station maps and images",
                        detail: "Official city-pack assets where collected"
                    )
                } header: {
                    Text(AppLocalization.localized("Essential Rider Information"))
                } footer: {
                    Text(AppLocalization.localized("Unavailable data is shown honestly instead of guessed."))
                }

                Section {
                    ForEach(cities) { city in
                        HStack {
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
                        }
                    }
                } header: {
                    Text(AppLocalization.localized("Supported Cities"))
                }
            }
            .navigationTitle(AppLocalization.localized("Transit Data"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
    }

    private func dataCapabilityRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.localized(title))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(AppLocalization.localized(detail))
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

    private let columns = [
        GridItem(.adaptive(minimum: 106), spacing: 6, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            capabilityTag(title: "Access", status: city.dataCapabilities.accessibility)
            capabilityTag(title: "Essentials", status: city.dataCapabilities.stationEssentials)
            capabilityTag(title: "3D Map", status: city.dataCapabilities.stationMap)
        }
        .padding(.top, 2)
    }

    private func capabilityTag(title: String, status: CityDataCapabilityStatus) -> some View {
        Label {
            Text(AppLocalization.localized(title))
                .lineLimit(1)
        } icon: {
            Image(systemName: status.iconName)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2)
        .foregroundStyle(tagColor(for: status))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(tagColor(for: status).opacity(0.12), in: Capsule())
        .accessibilityLabel("\(AppLocalization.localized(title)): \(accessibilityText(for: status))")
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
