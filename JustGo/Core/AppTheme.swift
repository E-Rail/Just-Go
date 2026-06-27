import SwiftUI

extension Notification.Name {
    static let quickPlacesDidReset = Notification.Name("quickPlacesDidReset")
}

enum AppTheme: String, CaseIterable, Identifiable {
    case forestGreen  = "#2D7055"
    case oceanBlue    = "#1D6FA5"
    case royalPurple  = "#6B3AC7"
    case sunsetOrange = "#C45C1A"
    case rubyRed      = "#B82828"
    case skyTeal      = "#0E7490"
    case roseGold     = "#A8336A"

    var id: String { rawValue }
    var accent: Color { Color.adaptiveAccent(hex: rawValue) }

    var name: String {
        switch self {
        case .forestGreen:  return AppLocalization.text(english: "Forest", simplified: "森林绿", traditional: "森林綠")
        case .oceanBlue:    return AppLocalization.text(english: "Ocean", simplified: "海洋蓝", traditional: "海洋藍")
        case .royalPurple:  return AppLocalization.text(english: "Purple", simplified: "紫罗兰", traditional: "紫羅蘭")
        case .sunsetOrange: return AppLocalization.text(english: "Sunset", simplified: "日落橙", traditional: "日落橙")
        case .rubyRed:      return AppLocalization.text(english: "Ruby", simplified: "红宝石", traditional: "紅寶石")
        case .skyTeal:      return AppLocalization.text(english: "Teal", simplified: "青绿", traditional: "青綠")
        case .roseGold:     return AppLocalization.text(english: "Rose", simplified: "玫瑰金", traditional: "玫瑰金")
        }
    }
}
