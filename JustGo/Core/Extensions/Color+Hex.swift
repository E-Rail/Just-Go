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

    /// Theme accent that adapts to dark mode by lightening the color, so accent-tinted
    /// text, icons, and controls stay legible on the dark background. Light mode uses the
    /// exact hex; dark mode raises brightness and eases saturation for contrast.
    static func adaptiveAccent(hex: String) -> Color {
        let (r, g, b) = Color.rgbComponents(hex: hex)
        let base = UIColor(red: r, green: g, blue: b, alpha: 1)
        let dark = base.lightenedForDarkMode()
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : base })
    }
}

private extension UIColor {
    func lightenedForDarkMode() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let brightened = min(1.0, b + (1.0 - b) * 0.55)
        let eased = max(0.0, s * 0.82)
        return UIColor(hue: h, saturation: eased, brightness: brightened, alpha: a)
    }
}
