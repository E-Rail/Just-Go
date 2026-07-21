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
    /// Optional, and built in the launch task rather than in `init`. Everything `init` does runs
    /// before SwiftUI can draw anything at all, so constructing ~15 services here — two of which
    /// (`CLLocationManager`, `UNUserNotificationCenter`) are synchronous XPC handshakes with
    /// system daemons — kept the launch screen itself off screen for as long as that took.
    @State private var container: DIContainer?

    init() {
        #if DEBUG
        MainThreadHangMonitor.start()
        LaunchClock.mark("app.init")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container, !appState.isLaunching {
                    ContentView()
                        .environment(container)
                        .environment(container.tripMemoryService)
                        .transition(.opacity)
                } else {
                    LaunchStageView(stage: appState.launchStage, progress: appState.launchProgress)
                        .transition(.opacity)
                        // `onAppear`, not `.task`: tasks queue behind the launch task on the
                        // main actor, so a `.task` here would time when the launch work let go
                        // of the main thread rather than when this screen actually appeared.
                        .onAppear { firstFrameDidRender() }
                }
            }
            // On a fast device the essentials finish in a few hundred ms; dissolve rather than
            // snap so that reads as a handoff instead of a flash.
            .animation(.easeInOut(duration: 0.28), value: appState.isLaunching)
            .environment(appState)
            .task { await runLaunchStages() }
        }
    }

    private func firstFrameDidRender() {
        #if DEBUG
        LaunchClock.mark("firstFrame")
        #endif
    }

    /// Loads what the first screen genuinely needs, one stage at a time, and hands off to the
    /// tab UI as soon as those are done. Work nothing on screen is waiting for runs afterwards,
    /// behind the live UI, rather than holding the launch screen up.
    private func runLaunchStages() async {
        guard appState.isLaunching else { return }

        // Let SwiftUI commit the launch screen's first frame before this task occupies the main
        // actor with synchronous service construction. `.task` bodies start running *ahead* of
        // that commit, so without this the screen the user is waiting to see would only appear
        // after the very work it exists to cover — measured, not assumed.
        await Task.yield()

        // Stage 1 — services. Runs here, not in `init`, so the launch screen is already on
        // screen while it happens. The rights-epoch sweep must precede it: it can delete the
        // city-pack tree, and the pack service must not read a tree that is about to vanish.
        Self.applyDataRightsEpochIfNeeded()
        let container = DIContainer.configure()
        self.container = container
        #if DEBUG
        LaunchClock.mark("container.ready")
        #endif

        // Both sweeps walk directories whose size the app doesn't control, and nothing waits on
        // their results.
        Task.detached(priority: .utility) {
            Self.removeObsoleteRouteCaches()
            Self.removeOrphanedPhotoImportTempFiles()
        }

        // Stage 2 — the city capabilities manifest, which the city rows render from.
        appState.advanceLaunch(to: .loadingCities)
        await Task.detached(priority: .userInitiated) {
            CityDataCapabilities.prewarm()
        }.value

        // Stage 3 — resolve the city, then decode its network so the Map tab opens with its
        // geometry already in memory instead of paying for the decode on first appearance.
        // Bounded: a launch screen that never finishes is worse than a slow one, and the decode
        // is a warmup — if it overruns, hand off and let it land in the actor's cache behind us.
        appState.initialize(container: container)
        appState.advanceLaunch(to: .loadingMapData)
        if let cityID = appState.selectedCity?.id {
            let provider = container.metroNetworkProvider
            _ = try? await withDeadline(seconds: 8) {
                LaunchStageTimeout.overran
            } operation: {
                await provider.network(for: cityID)
            }
        }

        // Essentials done — hand off.
        appState.advanceLaunch(to: .ready)

        // Stage 4 — runs after the handoff, so it never holds the first screen. Quick-tag
        // repair touches a network decode and a city-pack load per tag, and the rows it
        // repairs are several taps away.
        await repairQuickTags(container: container)
    }

    private func repairQuickTags(container: DIContainer) async {
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
