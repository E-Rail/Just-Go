import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    /// The app's own colour, taken from the icon.
    ///
    /// Not the icon's orange exactly. `#E58216` measures 2.79:1 against white — below the 3:1 the
    /// smallest tinted things in this app need, let alone the 4.5:1 a tab-bar label wants — so a
    /// tinted label in light mode would have been decoration rather than text. This is the same
    /// hue (31°) at the same saturation, darkened until it clears **4.50:1 on white**. Dark mode
    /// lifts it back to roughly the icon's own orange (see `legibleOnDarkBackground`), so the two
    /// appearances read as one colour and both are legible.
    case brandOrange  = "#B06411"
    case forestGreen  = "#2D7055"
    case oceanBlue    = "#1D6FA5"
    case royalPurple  = "#6B3AC7"
    case rubyRed      = "#B82828"
    case skyTeal      = "#0E7490"
    case roseGold     = "#A8336A"

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
        case .rubyRed:      return AppLocalization.text(english: "Ruby", simplified: "红宝石", traditional: "紅寶石")
        case .skyTeal:      return AppLocalization.text(english: "Teal", simplified: "青绿", traditional: "青綠")
        case .roseGold:     return AppLocalization.text(english: "Rose", simplified: "玫瑰金", traditional: "玫瑰金")
        }
    }
}
