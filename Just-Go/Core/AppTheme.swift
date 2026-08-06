import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    /// The app's own colour, taken from the icon.
    ///
    /// Not the icon's orange exactly. `#E58216` measures 2.79:1 against white — below the 3:1 the
    /// smallest tinted things in this app need, let alone the 4.5:1 a tab-bar label wants — so a
    /// tinted label in light mode would have been decoration rather than text. This is the same
    /// hue (31°) at the same saturation, darkened until it clears **4.51:1 on white** — #B06411
    /// shipped first and measured 4.49:1, because 8-bit rounding ate the last hundredth. Dark mode
    /// lifts it back to roughly the icon's own orange (see `legibleOnDarkBackground`), so the two
    /// appearances read as one colour and both are legible.
    case brandOrange  = "#AF6411"
    case forestGreen  = "#2D7055"
    case oceanBlue    = "#1D6FA5"
    case royalPurple  = "#6B3AC7"

    /// Four, and these four. Every remaining pair is at least 48° apart on the hue wheel and every
    /// one clears 4.5:1 on white, so no two are confusable and none is unreadable. Dropped:
    /// `skyTeal` sat 11° from `oceanBlue` — the same colour to a rider; `rubyRed` sat at hue 0°,
    /// the red this app already spends on errors, warnings and the destination pin; `roseGold` was
    /// 28° off that same red. A palette whose entries collide with each other, or with the
    /// semantics of the UI drawn on top of them, is a longer list rather than a better one.
    ///
    /// What the app uses until a rider picks something else. Declared once: this was written out
    /// as `AppTheme.default.rawValue` in eight separate `@AppStorage` defaults, which is eight
    /// places to miss when the answer changes.
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
