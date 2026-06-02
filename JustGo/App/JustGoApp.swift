import SwiftUI

@main
struct JustGoApp: App {
    @State private var appState = AppState()
    @State private var container: DIContainer

    init() {
        let container = DIContainer.configure()
        _container = State(initialValue: container)
        AMapConfiguration.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(container)
                .environment(container.tripMemoryService)
                .environment(container.accessibilityReportService)
                .task {
                    await appState.initialize(container: container)
                }
        }
    }
}
