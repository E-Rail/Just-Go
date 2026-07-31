import SwiftUI
import UIKit
import Foundation

/// The app's three surface levels: the page behind everything, the cards on it, and anything
/// raised above a card.
///
/// These were a hand-mixed forest-green ramp (#0F1F14 page, #172E1F card) that tinted every screen
/// in the app. Two problems, both of which read as "unfinished" rather than "branded": the page and
/// the card were four points of luminance apart, so cards did not look like cards; and a saturated
/// hue under *all* content fought every semantic colour drawn on top of it — a red warning, a blue
/// link and a green badge on a green field share no common ground to sit against.
///
/// The system greys are the right answer, and not only because they match iOS. They are the neutral
/// the semantic colours were designed against, they track light/dark and increased-contrast for
/// free, and they leave the theme colour to do the one job a brand colour should: mark the thing to
/// tap. The green did not go away — it moved to the accent, where it means something.
extension Color {
    static let appBackground = Color(UIColor.systemGroupedBackground)

    static let appSurface = Color(UIColor.secondarySystemGroupedBackground)

    static let appSurfaceSecondary = Color(UIColor.tertiarySystemGroupedBackground)

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

extension Color {
    /// Picks black or white — whichever contrasts better by WCAG relative luminance — for
    /// text drawn on a solid `hex` fill. For data-driven colors (real transit line branding,
    /// which spans everything from pale yellow to near-black) a fixed white/black choice
    /// isn't safe the way it is for this app's own curated theme/status colors.
    static func legibleText(onHex hex: String) -> Color {
        let (r, g, b) = rgbComponents(hex: hex)
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.35 ? .black : .white
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
