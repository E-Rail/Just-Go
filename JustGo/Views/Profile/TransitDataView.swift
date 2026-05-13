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
                            Text(AppLocalization.localized("AMap Live Transit"))
                                .font(.headline)
                            Text(AppLocalization.localized("Stations, metro lines, and public transit routes are loaded from AMap."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(AppLocalization.localized("Supported Cities")) {
                    ForEach(cities) { city in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(city.localizedName)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(AppLocalization.cityLineSummary(stations: city.stationCount, lines: city.lineCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
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
}
