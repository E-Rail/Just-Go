import SwiftUI
import UIKit
import Foundation

extension Color {
    static let appAccent = Color(hex: "#2D7055")

    static let appBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.06, green: 0.12, blue: 0.08, alpha: 1)   // #0F1F14 dark forest
            : UIColor(red: 0.92, green: 0.96, blue: 0.92, alpha: 1)   // #EBF5EC light sage
    })

    static let appSurface = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.09, green: 0.18, blue: 0.12, alpha: 1)   // #172E1F dark card
            : UIColor.systemBackground
    })

    static let appSurfaceSecondary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.23, blue: 0.15, alpha: 1)   // #1E3B26 elevated card
            : UIColor.systemBackground
    })

    init(hex: String) {
        let (r, g, b) = Color.rgbComponents(hex: hex)
        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }

    static func rgbComponents(hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        return (
            CGFloat((value & 0xFF0000) >> 16) / 255,
            CGFloat((value & 0x00FF00) >> 8) / 255,
            CGFloat(value & 0x0000FF) / 255
        )
    }

    /// Universal adaptive brand color: any hex used for foreground (text, icons, strokes,
    /// thin lines) should pass through this so it stays legible in both appearances.
    /// Light mode uses the exact hex. Dark mode lightens the color toward white only as
    /// much as needed to clear a legibility threshold against the dark background — so a
    /// dark forest green lifts a lot, while an already-bright color is left untouched.
    /// Works for any hue, so every theme and line color is handled by one rule. Use the
    /// raw `Color(hex:)` for solid fills/badges/map overlays where the true brand color
    /// is required.
    static func adaptive(hex: String) -> Color {
        let (r, g, b) = Color.rgbComponents(hex: hex)
        let base = UIColor(red: r, green: g, blue: b, alpha: 1)
        let dark = base.legibleOnDarkBackground()
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : base })
    }
}

private extension UIColor {
    /// Blends the color toward white just enough to reach `targetLuminance`, leaving
    /// already-light colors unchanged. Perceptual luma keeps the lift even across hues.
    func legibleOnDarkBackground(targetLuminance: CGFloat = 0.62) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        guard luma < targetLuminance else { return self }
        let t = (targetLuminance - luma) / (1 - luma) // blend factor toward white, 0...1
        return UIColor(
            red: r + (1 - r) * t,
            green: g + (1 - g) * t,
            blue: b + (1 - b) * t,
            alpha: a
        )
    }
}
