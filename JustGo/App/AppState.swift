import SwiftUI

/// The launch work the app does before it can show a usable UI, in order. Each case is real
/// work with a real completion point — the launch screen names the stage it is on, so a slow
/// launch on a real device reports *which* stage is slow instead of just feeling slow.
enum LaunchStage: Int, CaseIterable, Comparable {
    case preparing
    case loadingCities
    case loadingMapData
    case ready

    static func < (lhs: LaunchStage, rhs: LaunchStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var caption: String {
        switch self {
        case .preparing:
            return AppLocalization.text(
                english: "Initializing",
                simplified: "正在初始化",
                traditional: "正在初始化"
            )
        case .loadingCities:
            return AppLocalization.text(
                english: "Loading cities",
                simplified: "正在载入城市",
                traditional: "正在載入城市"
            )
        case .loadingMapData:
            return AppLocalization.text(
                english: "Loading map data",
                simplified: "正在载入地图数据",
                traditional: "正在載入地圖資料"
            )
        case .ready:
            return AppLocalization.text(
                english: "Ready",
                simplified: "已就绪",
                traditional: "已就緒"
            )
        }
    }

    /// Fraction of the gated launch that is complete once this stage *finishes*.
    var completedFraction: Double {
        Double(rawValue + 1) / Double(LaunchStage.allCases.count)
    }
}

@MainActor
@Observable
final class AppState {
    private let userDefaults: UserDefaults
    private let accessibilityPreferenceKey = "accessibilityPreference"

    var selectedCity: City?
    #if DEBUG
    // Lets a headless diagnostic launch open straight onto a given tab, since this
    // environment has no way to inject a tap.
    var selectedTab: Int = ProcessInfo.processInfo.environment["JUSTGO_START_TAB"].flatMap(Int.init) ?? 1
    #else
    var selectedTab: Int = 1
    #endif

    struct PendingRouteInput: Equatable {
        let place: TransitPlace
        let role: RouteInputField
        /// The place's home city when the sender knows it (station-originated inputs);
        /// nil for map POIs, which carry no city. The planner switches to this city on
        /// apply so a cross-city quick tag doesn't plan against the wrong network.
        let cityID: String?
    }
    var pendingRouteInput: PendingRouteInput?

    var accessibilityPreference: AccessibilityPreference {
        didSet {
            userDefaults.setCodable(accessibilityPreference, forKey: accessibilityPreferenceKey)
        }
    }
    private(set) var hasInitialized = false

    /// The stage currently running. `launchProgress` reports the work already behind it, so the
    /// bar shows progress made rather than progress promised.
    private(set) var launchStage: LaunchStage = .preparing
    var isLaunching: Bool { launchStage < .ready }
    var launchProgress: Double {
        guard launchStage != .preparing else { return 0 }
        return LaunchStage(rawValue: launchStage.rawValue - 1)?.completedFraction ?? 0
    }

    func advanceLaunch(to stage: LaunchStage) {
        guard stage > launchStage else { return }
        launchStage = stage
        #if DEBUG
        MainThreadHangMonitor.mark("launch.\(stage)")
        #endif
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.accessibilityPreference = userDefaults.codableValue(
            forKey: accessibilityPreferenceKey,
            as: AccessibilityPreference.self,
            default: .default
        )
    }

    func initialize(container: DIContainer) {
        guard !hasInitialized else { return }

        defer {
            hasInitialized = true
        }

        let nearestCity: City?
        if let location = container.locationService.currentLocation {
            nearestCity = container.cityService.findNearestCity(to: location)
        } else {
            nearestCity = nil
        }

        selectedCity = nearestCity
            ?? container.cityService.getCity(byID: "1100")
            ?? container.cityService.getAllCities().first
    }
}
