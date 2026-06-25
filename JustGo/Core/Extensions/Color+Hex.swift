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
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255
        let b = Double(rgbValue & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
