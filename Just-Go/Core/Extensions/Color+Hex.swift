import SwiftUI
import UIKit
import Foundation

/// The app's three surface levels: the page behind everything, the cards on it, and anything
/// raised above a card.
///
/// These were a hand-mixed forest-green ramp (#0F1F14 page, #172E1F card) that tinted every screen
/// in the app. Two problems, both of which read as "unfinished" rather than "branded": the page and
/// the card were four points of luminance apart, so cards did not look like cards; and a saturated
/// hue under *all* content fought every semantic colour drawn on top of it. A red warning, a blue
/// link and a green badge on a green field share no common ground to sit against.
///
/// The system greys are the right answer, and not only because they match iOS. They are the neutral
/// the semantic colours were designed against, they track light/dark and increased-contrast for
/// free, and they leave the theme colour to do the one job a brand colour should: mark the thing to
/// tap. The green did not go away: it moved to the accent, where it means something.
extension Color {
    static let appBackground = Color(UIColor.systemGroupedBackground)

    static let appSurface = Color(UIColor.secondarySystemGroupedBackground)

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
    /// much as needed to clear a legibility threshold against the dark background, so a
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
    /// Picks black or white: whichever contrasts better by WCAG relative luminance. For
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
    /// Brightens the color to `targetLuminance` for use on a dark background, keeping its hue
    /// **and its saturation**. Already-light colors are returned unchanged.
    ///
    /// This used to blend toward white, which reaches the target but drains the colour on the way:
    /// the brand orange arrived as #C9955C, a bronze at 0.54 saturation, and forest green arrived
    /// as a grey-green at 0.23. Raising brightness in HSB instead keeps the hue *and* the
    /// saturation, and measured across all seven themes it is better on both counts every time.
    /// Brand orange #C9955C -> #F68C18 (sat 0.54 -> 0.90, contrast 6.43 -> 7.01 on #1C1C1E),
    /// teal 0.40 -> 0.90, forest 0.23 -> 0.60. No theme lost contrast.
    ///
    /// Brightness alone cannot always get there. A saturated blue tops out darker than the target
    ///, so the white blend stays as the fallback for that case rather than being deleted.
    func legibleOnDarkBackground(targetLuminance: CGFloat = 0.62) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        func luma(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat {
            0.299 * red + 0.587 * green + 0.114 * blue
        }
        guard luma(r, g, b) < targetLuminance else { return self }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        if getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &a) {
            // Binary search the brightness that lands on the target: luma is monotonic in
            // brightness at fixed hue/saturation, but not linear in it.
            var low = brightness, high: CGFloat = 1
            for _ in 0..<24 {
                let mid = (low + high) / 2
                let candidate = UIColor(hue: hue, saturation: saturation, brightness: mid, alpha: a)
                var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
                candidate.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
                if luma(cr, cg, cb) < targetLuminance { low = mid } else { high = mid }
            }
            let lifted = UIColor(hue: hue, saturation: saturation, brightness: high, alpha: a)
            var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
            lifted.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
            if luma(lr, lg, lb) >= targetLuminance - 0.005 { return lifted }
            r = lr; g = lg; b = lb
        }

        // Full brightness still too dark for the target. Finish toward white.
        let shortfall = luma(r, g, b)
        let t = (targetLuminance - shortfall) / (1 - shortfall)
        return UIColor(
            red: r + (1 - r) * t,
            green: g + (1 - g) * t,
            blue: b + (1 - b) * t,
            alpha: a
        )
    }
}
