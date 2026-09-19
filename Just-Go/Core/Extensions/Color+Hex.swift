import SwiftUI
import UIKit
import Foundation

/// The app's three surface levels: the page, the cards on it, and anything raised above a card.
/// System greys: the neutral the semantic colours were designed against, tracking light, dark and
/// increased contrast, and leaving the theme colour to mark what to tap.
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

    /// Adaptive colour for any hex used as foreground (text, icons, strokes, thin lines). Light
    /// mode uses the exact hex; dark mode lightens it only as far as legibility needs. Use raw
    /// `Color(hex:)` for solid fills, badges and map overlays, where the true colour is required.
    static func adaptive(hex: String) -> Color {
        let (r, g, b) = Color.rgbComponents(hex: hex)
        let base = UIColor(red: r, green: g, blue: b, alpha: 1)
        let dark = base.legibleOnDarkBackground()
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : base })
    }
}

extension Color {
    /// Black or white, whichever contrasts better with a solid `hex` fill by WCAG relative
    /// luminance. Needed for data-driven colours: real line branding runs from pale yellow to
    /// near-black.
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
    /// Brightens the colour to `targetLuminance` for a dark background, keeping its hue **and
    /// saturation**; already-light colours are returned unchanged. Raising HSB brightness keeps the
    /// colour where blending toward white drains it (brand orange keeps 0.90 saturation instead of
    /// 0.54). A saturated blue can top out below the target, so the white blend remains the
    /// fallback.
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
