import SwiftUI

struct OfflineDataView: View {
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    private var cities: [City] {
        container.cityService.getAllCities()
    }

    var body: some View {
        NavigationStack {
            List {
                storageSection
                installedSection
                availableSection
            }
            .navigationTitle("Offline Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var storageSection: some View {
        Section {
            let totalMB = Double(container.offlineDataManager.getTotalStorageUsed()) / 1024 / 1024
            HStack {
                Text("Total Storage")
                Spacer()
                Text(String(format: "%.1f MB", totalMB))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Download city data to use the app without internet connection")
        }
    }

    private var installedSection: some View {
        Section("Installed") {
            let installed = cities.filter { container.offlineDataManager.isAvailable(cityID: $0.id) }

            if installed.isEmpty {
                Text("No cities downloaded")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(installed) { city in
                    installedCityRow(city)
                }
            }
        }
    }

    private var availableSection: some View {
        Section("Available") {
            let available = cities.filter { !container.offlineDataManager.isAvailable(cityID: $0.id) }

            ForEach(available) { city in
                availableCityRow(city)
            }
        }
    }

    private func installedCityRow(_ city: City) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(city.nameEn)
                    .font(.body)
                    .fontWeight(.medium)
                Text("\(city.stationCount) stations • \(city.lineCount) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Delete") {
                Task {
                    try? container.offlineDataManager.deletePack(cityID: city.id)
                }
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

    private func availableCityRow(_ city: City) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(city.nameEn)
                    .font(.body)
                    .fontWeight(.medium)
                Text("\(city.stationCount) stations • \(String(format: "%.1f", city.offlinePackSizeMB)) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if container.offlineDataManager.downloadStates[city.id]?.isDownloading == true {
                ProgressView(value: container.offlineDataManager.downloadStates[city.id]?.progress ?? 0)
                    .frame(width: 60)
            } else {
                Button("Download") {
                    Task {
                        try? await container.offlineDataManager.downloadPack(cityID: city.id) { _ in }
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
    }
}
