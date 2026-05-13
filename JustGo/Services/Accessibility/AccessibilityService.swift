import Foundation
import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@Observable
final class AccessibilityService {
    var isVoiceOverRunning: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    #if canImport(UIKit)
    private var audioSession: AVAudioSession { AVAudioSession.sharedInstance() }
    #endif

    init() {
        checkAccessibilitySettings()
    }

    func checkAccessibilitySettings() {
        #if canImport(UIKit)
        isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        #else
        isVoiceOverRunning = false
        #endif
    }

    // MARK: - Voice Announcements

    func announce(_ text: String, priority: AnnouncementPriority = .normal) {
        guard isVoiceOverRunning else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = priority == .high ? 0.5 : 0.4

        #if canImport(UIKit)
        try? audioSession.setCategory(.playback, mode: .spokenAudio)
        try? audioSession.setActive(true)
        synthesizer.speak(utterance)
        #else
        synthesizer.speak(utterance)
        #endif
    }

    // MARK: - Haptic Feedback

    func playHaptic(_ type: HapticType) {
        #if canImport(UIKit)
        switch type {
        case .stationArrival:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        case .transfer:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        case .warning:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        case .navigation:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
        #endif
    }

    // MARK: - Accessibility Labels

    func stationAccessibilityLabel(_ station: Station) -> String {
        var label = station.localizedName
        if let alternateName = station.alternateLocalizedName { label += ", \(alternateName)" }

        if station.isTransferStation {
            label += AppLocalization.text(english: ", transfer station", chinese: "，换乘站")
        }

        if let accessibility = station.accessibility {
            if accessibility.hasElevator {
                label += AppLocalization.text(english: ", has elevator", chinese: "，有电梯")
            }
            if accessibility.hasWheelchairRamp {
                label += AppLocalization.text(english: ", wheelchair accessible", chinese: "，轮椅可通行")
            }
            if accessibility.isFullyAccessible {
                label += AppLocalization.text(english: ", fully accessible", chinese: "，完全无障碍")
            }
        }

        return label
    }

}

enum AnnouncementPriority {
    case low
    case normal
    case high
}

enum HapticType {
    case stationArrival
    case transfer
    case warning
    case navigation
}
