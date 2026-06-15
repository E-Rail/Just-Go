import SwiftUI

@main
struct JustGoApp: App {
    @State private var appState = AppState()
    @State private var container: DIContainer

    init() {
        let container = DIContainer.configure()
        _container = State(initialValue: container)
        Self.removeObsoleteRouteCaches()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(container)
                .environment(container.tripMemoryService)
                .environment(container.accessibilityReportService)
                .task {
                    appState.initialize(container: container)
                }
        }
    }

    private static func removeObsoleteRouteCaches() {
        let fileManager = FileManager.default
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: applicationSupport.appendingPathComponent("LineOverlays", isDirectory: true))
        }
    }
}
