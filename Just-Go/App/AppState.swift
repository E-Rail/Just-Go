import SwiftUI

/// The launch work the app does before it can show a usable UI, in order. Each case is real
/// work with a real completion point. The launch screen names the stage it is on, so a slow
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
    private let lastMapCameraKey = "lastMapCamera"

    /// Where the map was last looking.
    ///
    /// This is what is left of "the selected city". The app used to hold one city as a mode.
    /// Gating what was loaded, searched, drawn and routed, and every screen had to agree about
    /// it. What a rider actually wants on relaunch is the view they left, so that is the only
    /// thing kept: a camera, not a mode. Nothing is gated on it.
    var lastMapCamera: MapCamera? {
        didSet { userDefaults.setCodable(lastMapCamera, forKey: lastMapCameraKey) }
    }

    struct MapCamera: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let spanDelta: Double
    }

    /// Named rather than an Int, because the tags moved when the Route and Search tabs folded into
    /// the map and a bare `selectedTab = 1` silently means something different afterwards.
    enum Tab: Hashable {
        case map
        case profile
    }

    #if DEBUG
    // Lets a headless diagnostic launch open straight onto a given tab, since this environment has
    // no way to inject a tap: confirmed, not assumed: this Xcode install ships no Simulator.app,
    // so the device is booted headlessly and there is no GUI to click.
    var selectedTab: Tab = ProcessInfo.processInfo.environment["JUST_GO_START_TAB"] == "profile"
        ? .profile
        : .map
    #else
    var selectedTab: Tab = .map
    #endif

    struct PendingRouteInput: Equatable {
        let place: TransitPlace
        let role: RouteInputField
    }
    var pendingRouteInput: PendingRouteInput?

    var accessibilityPreference: AccessibilityPreference {
        didSet {
            userDefaults.setCodable(accessibilityPreference, forKey: accessibilityPreferenceKey)
        }
    }
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
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.accessibilityPreference = userDefaults.codableValue(
            forKey: accessibilityPreferenceKey,
            as: AccessibilityPreference.self,
            default: .default
        )
        self.lastMapCamera = userDefaults.codableValue(
            forKey: lastMapCameraKey,
            as: AppState.MapCamera?.self,
            default: nil
        )
    }
}
