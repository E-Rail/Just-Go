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

    /// Where the map was last looking. The only thing restored on relaunch: a camera, not a city
    /// mode, and nothing is gated on it.
    var lastMapCamera: MapCamera? {
        didSet { userDefaults.setCodable(lastMapCamera, forKey: lastMapCameraKey) }
    }

    struct MapCamera: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let spanDelta: Double
    }

    /// Named rather than an Int, so a tag that moves cannot silently change what `selectedTab = 1`
    /// means.
    enum Tab: Hashable {
        case map
        case trips
        case profile
    }

    #if DEBUG
    // Lets a headless diagnostic launch open on a given tab: this environment has no tap injection.
    var selectedTab: Tab = {
        switch ProcessInfo.processInfo.environment["JUST_GO_START_TAB"] {
        case "profile": return .profile
        case "trips": return .trips
        default: return .map
        }
    }()
    #else
    var selectedTab: Tab = .map
    #endif

    struct PendingRouteInput: Equatable {
        let place: TransitPlace
        let role: RouteInputField
    }
    var pendingRouteInput: PendingRouteInput?

    /// A trip the rider asked to plan again from the Trips tab, which cannot plan. One-shot, like
    /// `pendingRouteInput`: the map reads it once and clears it.
    var pendingTripReplay: TripRecord?

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
