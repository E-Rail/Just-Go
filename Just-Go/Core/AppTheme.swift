import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    /// The app's own colour: the icon's hue (31°) and saturation, darkened to 4.51:1 on white so
    /// tinted text is legible in light mode. The icon's own `#E58216` is 2.79:1. Dark mode lifts it
    /// back to roughly the icon's orange (see `legibleOnDarkBackground`).
    case brandOrange  = "#AF6411"
    case forestGreen  = "#2D7055"
    case oceanBlue    = "#1D6FA5"
    case royalPurple  = "#6B3AC7"

    /// Four themes, each at least 48° apart on the hue wheel and each clearing 4.5:1 on white, none
    /// on the red the app uses for errors and the destination pin. `default` is what the app uses
    /// until a rider picks another; declare it once.
    static let `default` = AppTheme.brandOrange

    var id: String { rawValue }
    var accent: Color { Color.adaptive(hex: rawValue) }

    var name: String {
        switch self {
        case .brandOrange:  return AppLocalization.text(english: "Signal", simplified: "信号橙", traditional: "訊號橙")
        case .forestGreen:  return AppLocalization.text(english: "Forest", simplified: "森林绿", traditional: "森林綠")
        case .oceanBlue:    return AppLocalization.text(english: "Ocean", simplified: "海洋蓝", traditional: "海洋藍")
        case .royalPurple:  return AppLocalization.text(english: "Purple", simplified: "紫罗兰", traditional: "紫羅蘭")
        }
    }
}

/// Light, dark, or the phone's setting. Separate from `AppTheme`, which picks the accent hue and is
/// already appearance-agnostic, so the two settings compose. Forcing an appearance needs no new
/// colours: the palette is system semantic colours or passes through `Color.adaptive(hex:)`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return AppLocalization.text(english: "System", simplified: "跟随系统", traditional: "跟隨系統")
        case .light:  return AppLocalization.text(english: "Light", simplified: "浅色", traditional: "淺色")
        case .dark:   return AppLocalization.text(english: "Dark", simplified: "深色", traditional: "深色")
        }
    }

    /// `nil` is how SwiftUI spells "do not override", which is exactly what `.system` means.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
