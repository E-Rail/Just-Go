import Foundation
import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@Observable
final class AccessibilityService {
    var isVoiceOverRunning: Bool = false
    var isReduceMotionEnabled: Bool = false
    var preferredContentSizeCategory: ContentSizeCategory = .medium

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
        isReduceMotionEnabled = UIAccessibility.isReduceMotionEnabled
        #else
        isVoiceOverRunning = false
        isReduceMotionEnabled = false
        #endif
    }

    // MARK: - Voice Announcements

    func announce(_ text: String, priority: AnnouncementPriority = .normal) {
        guard isVoiceOverRunning else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = priority == .high ? 0.5 : 0.4

        #if canImport(UIKit)
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
            synthesizer.speak(utterance)
        } catch {
            print("Audio session error: \(error)")
        }
        #else
        synthesizer.speak(utterance)
        #endif
    }

    func announceStation(_ stationName: String, lineName: String) {
        let text = "Now arriving at \(stationName), \(lineName)"
        announce(text, priority: .high)
    }

    func announceTransfer(from: String, to: String) {
        let text = "Transfer from \(from) to \(to)"
        announce(text, priority: .high)
    }

    func announceNextStop(_ stationName: String, stopsAway: Int) {
        if stopsAway == 1 {
            announce("Next stop: \(stationName)", priority: .high)
        } else {
            announce("\(stopsAway) stops until \(stationName)")
        }
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

    // MARK: - Visual Alerts

    func flashScreen() {
        // Screen flash for deaf users
        // Implemented via SwiftUI overlay
    }

    // MARK: - Accessibility Labels

    func stationAccessibilityLabel(_ station: Station) -> String {
        var label = station.name
        if let en = station.nameEn { label += ", \(en)" }

        if station.isTransferStation {
            label += ", transfer station"
        }

        if let accessibility = station.accessibility {
            if accessibility.hasElevator { label += ", has elevator" }
            if accessibility.hasWheelchairRamp { label += ", wheelchair accessible" }
            if accessibility.isFullyAccessible { label += ", fully accessible" }
        }

        return label
    }

    func routeAccessibilityLabel(_ route: Route) -> String {
        var label = "Route from \(route.origin) to \(route.destination)"
        label += ", \(route.formattedDuration)"
        label += ", \(route.formattedStops)"
        label += ", \(route.formattedTransfers)"

        if route.isFullyAccessible {
            label += ", fully accessible"
        }

        if !route.warnings.isEmpty {
            label += ", has accessibility warnings"
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
