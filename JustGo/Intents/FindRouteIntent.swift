import AppIntents

struct FindRouteIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Subway Route"
    static var description = IntentDescription("Finds the best subway route between two stations")

    @Parameter(title: "Origin Station")
    var origin: String

    @Parameter(title: "Destination Station")
    var destination: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find route from \(\.$origin) to \(\.$destination)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Searching for routes from \(origin) to \(destination)")
    }
}

struct NearbyStationIntent: AppIntent {
    static var title: LocalizedStringResource = "Nearest Station"
    static var description = IntentDescription("Finds the nearest subway station")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Finding nearest station...")
    }
}

struct CheckAccessibilityIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Station Accessibility"
    static var description = IntentDescription("Checks if a station is accessible")

    @Parameter(title: "Station Name")
    var station: String

    static var parameterSummary: some ParameterSummary {
        Summary("Check if \(\.$station) is accessible")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Checking accessibility for \(station)...")
    }
}

struct JustGoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FindRouteIntent(),
            phrases: [
                "Find subway route in \(.applicationName)",
                "Get directions in \(.applicationName)",
                "Navigate subway with \(.applicationName)"
            ],
            shortTitle: "Find Route",
            systemImageName: "tram.fill"
        )

        AppShortcut(
            intent: NearbyStationIntent(),
            phrases: [
                "Find nearest station in \(.applicationName)",
                "What's the closest station in \(.applicationName)"
            ],
            shortTitle: "Nearest Station",
            systemImageName: "location.fill"
        )

        AppShortcut(
            intent: CheckAccessibilityIntent(),
            phrases: [
                "Check accessibility in \(.applicationName)",
                "Is station accessible in \(.applicationName)"
            ],
            shortTitle: "Check Accessibility",
            systemImageName: "accessibility"
        )
    }
}
