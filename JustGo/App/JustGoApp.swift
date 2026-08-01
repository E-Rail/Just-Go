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

    init() {
        #if DEBUG
        MainThreadHangMonitor.start()
        LaunchClock.mark("app.init")
        #endif
        Self.applyDataRightsEpochIfNeeded()
        #if DEBUG
        LaunchClock.mark("dataRightsEpoch.done")
        #endif
        let container = DIContainer.configure()
        #if DEBUG
        LaunchClock.mark("container.ready")
        #endif
        _container = State(initialValue: container)
        // The sweep walks a directory whose size the app doesn't control, and nothing waits
        // on its result — keep it off the main thread, which is otherwise blocked here
        // until the first frame. Measured at 8ms on an empty container but 82ms with 4,200
        // temp entries, i.e. bounded only by how much junk has accumulated.
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
                        .onAppear {
                            #if DEBUG
                            LaunchClock.mark("firstFrame")
                            #endif
                        }
                } else {
                    ContentView()
                        .transition(.opacity)
                }
            }
            // On a fast device the essentials finish in a few hundred ms; dissolve rather than
            // snap so that reads as a handoff instead of a flash.
            .animation(.easeInOut(duration: 0.28), value: appState.isLaunching)
            .environment(appState)
            .environment(container)
            .environment(container.tripMemoryService)
            .task { await runLaunchStages() }
        }
    }

    /// Loads what the first screen genuinely needs, one stage at a time, and hands off to the
    /// tab UI as soon as those are done. Work nothing on screen is waiting for runs afterwards,
    /// behind the live UI, rather than holding the launch screen up.
    private func runLaunchStages() async {
        guard appState.isLaunching else { return }

        // Stage 1 — services. `DIContainer.configure()` already ran in `init`; the city
        // capabilities manifest is the remaining piece, and it is what the city rows render from.
        appState.advanceLaunch(to: .loadingCities)
        // Ask for a fix before `appState.initialize` below reads one. Without this its
        // nearest-city branch was dead code — `currentLocation` is always nil this early, so
        // every launch seeded Beijing and a rider in Shanghai opened the app on the wrong city.
        // A no-op (and no permission prompt) when location has not been granted; the Map tab
        // asks for that at the moment it can explain why.
        container.locationService.prewarmLocation()
        await Task.detached(priority: .userInitiated) {
            CityDataCapabilities.prewarm()
        }.value

        // Stage 2 — resolve the city, then decode its network so the Map tab opens with its
        // geometry already in memory instead of paying for the decode on first appearance.
        // Bounded: a launch screen that never finishes is worse than a slow one, and the decode
        // is a warmup — if it overruns, hand off and let it land in the actor's cache behind us.
        #if DEBUG
        LaunchClock.mark("stage1.capabilities.done")
        #endif
        appState.initialize(container: container)
        #if DEBUG
        LaunchClock.mark("stage2.initialize.done")
        #endif
        appState.advanceLaunch(to: .loadingMapData)
        if let cityID = appState.selectedCity?.id {
            let provider = container.metroNetworkProvider
            _ = try? await withDeadline(seconds: 8) {
                LaunchStageTimeout.overran
            } operation: {
                await provider.network(for: cityID)
            }
        }

        #if DEBUG
        LaunchClock.mark("stage2.networkDecode.done")
        #endif
        // Essentials done — hand off.
        appState.advanceLaunch(to: .ready)

        // Then correct the city, rather than making the launch screen wait on GPS. `prewarm`
        // above only *starts* the fix; it cannot land before this point, so `initialize` always
        // seeded the fallback and a rider in Shanghai opened the app on Beijing. Waiting for the
        // fix before handing off would trade a wrong city for a slow launch — do it behind the
        // live UI instead, and only when the rider is clearly outside the seeded city.
        await realignCityToDevice()
        #if DEBUG
        LaunchClock.mark("stage3.realignCity.done")
        #endif

        // Stage 3 — runs after the handoff, so it never holds the first screen. Quick-tag
        // repair touches a network decode and a city-pack load per tag, and the rows it
        // repairs are several taps away.
        await repairQuickTags()
    }

    /// Adopts the city the device is actually in, once a fix arrives. No-op without location
    /// permission, and deliberately silent: this is a correction, not something to announce.
    private func realignCityToDevice() async {
        guard container.locationService.isAuthorized else { return }
        guard let location = try? await container.locationService.requestCurrentLocation() else { return }
        guard let city = container.cityService.cityToAdopt(
            for: location,
            whileSelecting: appState.selectedCity
        ) else { return }
        appState.selectedCity = city
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
