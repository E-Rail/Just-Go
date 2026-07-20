import CoreLocation
import SwiftUI

@main
struct JustGoApp: App {
    @State private var appState = AppState()
    @State private var container: DIContainer

    init() {
        #if DEBUG
        MainThreadHangMonitor.start()
        #endif
        Self.applyDataRightsEpochIfNeeded()
        let container = DIContainer.configure()
        _container = State(initialValue: container)
        Self.removeObsoleteRouteCaches()
        Self.removeOrphanedPhotoImportTempFiles()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(container)
                .environment(container.tripMemoryService)
                .task {
                    appState.initialize(container: container)
                    // The city-capabilities manifest is a lazily-decoded static that SwiftUI
                    // city-list rows touch during render — decode it here, off the main thread,
                    // rather than letting the first row pay for it mid-render.
                    Task.detached(priority: .utility) {
                        CityDataCapabilities.prewarm()
                    }
                    await container.tripMemoryService.repairQuickTagStationData { quickTag in
                        guard let network = await container.metroNetworkProvider.network(
                            for: quickTag.cityID
                        ) else { return nil }
                        let coordinate = CLLocationCoordinate2D(
                            latitude: quickTag.latitude,
                            longitude: quickTag.longitude
                        )
                        guard let match = network.matchingStation(named: quickTag.name, near: coordinate)
                            ?? quickTag.nameEn.flatMap({
                                network.matchingStation(named: $0, near: coordinate)
                            }) else { return nil }
                        return await container.stationSearchService.enrichStation(
                            network.displayStation(match)
                        )
                    }
                }
        }
    }

    private static func removeObsoleteRouteCaches() {
        let fileManager = FileManager.default
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: applicationSupport.appendingPathComponent("LineOverlays", isDirectory: true))
        }
    }

    /// `PersonalMediaPhotoFile.transferRepresentation` copies an import's original, unsanitized
    /// bytes (GPS/EXIF intact) into the temp directory before stripping metadata. That copy is
    /// only ever meant to live for the duration of one import; if the process is killed mid-import
    /// it's otherwise never cleaned up, so sweep any leftovers unconditionally on next launch.
    private static func removeOrphanedPhotoImportTempFiles() {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("JustGoPhotoImport-") {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func applyDataRightsEpochIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "cityPackDataRightsEpoch"
        let currentEpoch = 2
        guard defaults.integer(forKey: key) < currentEpoch else { return }

        let fileManager = FileManager.default
        let cityPacks = CityPackStorageLocation.rootURL(fileManager: fileManager)
        var cleanupSucceeded = true
        if fileManager.fileExists(atPath: cityPacks.path) {
            do {
                try fileManager.removeItem(at: cityPacks)
                cleanupSucceeded = !fileManager.fileExists(atPath: cityPacks.path)
            } catch {
                cleanupSucceeded = false
                AppLog.data.error("Data-rights cleanup failed: \(error)")
            }
        }
        guard cleanupSucceeded else { return }
        // The station-information cache holds fetched official data, so a rights-epoch
        // bump must sweep it together with the city packs.
        try? fileManager.removeItem(at: StationInformationCacheLocation.rootURL(fileManager: fileManager))
        URLCache.shared.removeAllCachedResponses()
        defaults.set(currentEpoch, forKey: key)
    }
}
