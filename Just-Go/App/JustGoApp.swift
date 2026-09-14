import CoreLocation
import SwiftUI

/// Thrown when a gated launch stage outruns its budget, so the app hands off to the UI rather
/// than holding the launch screen on work the first screen can live without.
enum LaunchStageTimeout: Error {
    case overran
}

@main
struct JustGoApp: App {
    @State private var appState = AppState()
    @State private var container: DIContainer
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    init() {
        #if DEBUG
        MainThreadHangMonitor.start()
        #endif
        Self.applyDataRightsEpochIfNeeded()
        let container = DIContainer.configure()
        _container = State(initialValue: container)
        // Off the main thread and not awaited: the sweep's cost grows with whatever has accumulated
        // in the directory.
        Task.detached(priority: .utility) {
            Self.removeObsoleteRouteCaches()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isLaunching {
                    LaunchStageView(stage: appState.launchStage, progress: appState.launchProgress)
                        .transition(.opacity)
                } else {
                    ContentView()
                        .transition(.opacity)
                }
            }
            // Dissolve rather than snap, so a fast launch reads as a handoff instead of a flash.
            .animation(.easeInOut(duration: 0.28), value: appState.isLaunching)
            .environment(appState)
            .environment(container)
            .environment(container.tripMemoryService)
            // On the window's root, so the appearance also covers the launch screen and every sheet
            // and full-screen cover.
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .task { await runLaunchStages() }
        }
    }

    /// Loads what the first screen genuinely needs, one stage at a time, and hands off to the
    /// tab UI as soon as those are done. Work nothing on screen is waiting for runs afterwards,
    /// behind the live UI, rather than holding the launch screen up.
    private func runLaunchStages() async {
        guard appState.isLaunching else { return }

        // Stage 1: the coverage manifest the city rows render from. `DIContainer.configure()`
        // already ran in `init`.
        appState.advanceLaunch(to: .loadingCities)
        // Starts a fix so the map's first centre-on-user lands quickly. A no-op, with no permission
        // prompt, when location has not been granted.
        container.locationService.prewarmLocation()
        await Task.detached(priority: .userInitiated) {
            CityDataCoverage.prewarm()
        }.value

        // Stage 2: decode the network under the camera the rider left, so the map's geometry is
        // already in memory. Bounded: a warmup that overruns lands in the actor's cache after the
        // handoff.
        appState.advanceLaunch(to: .loadingMapData)
        if let camera = appState.lastMapCamera,
           let city = container.cityService.findNearestCity(
               to: CLLocation(latitude: camera.latitude, longitude: camera.longitude)
           ) {
            let provider = container.metroNetworkProvider
            _ = try? await withDeadline(seconds: 8) {
                LaunchStageTimeout.overran
            } operation: {
                await provider.network(for: city.id)
            }
        }

        // Essentials done: hand off.
        appState.advanceLaunch(to: .ready)

        // Stage 3, after the handoff: the nationwide station index (only search needs it) and
        // quick-tag repair. Independent, so they run side by side.
        async let quickTagRepair: Void = repairQuickTags()
        async let stationIndex: Void = warmStationIndex()

        await quickTagRepair
        await stationIndex
    }

    /// Builds the nationwide station list behind the live UI, so the first search does not wait
    /// on it. Idempotent: the provider caches, and the search page calls the same method.
    private func warmStationIndex() async {
        _ = await container.metroNetworkProvider.allStations()
    }

    private func repairQuickTags() async {
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

    private nonisolated static func removeObsoleteRouteCaches() {
        let fileManager = FileManager.default
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: applicationSupport.appendingPathComponent("LineOverlays", isDirectory: true))
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
