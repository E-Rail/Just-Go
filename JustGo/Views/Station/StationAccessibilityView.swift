import SwiftUI

struct StationAccessibilityView: View {
    let station: Station

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                accessibilityOverview
                mobilitySection
                visionSection
                hearingSection
                cognitiveSection
                communitySection
            }
            .padding()
        }
        .navigationTitle(AppLocalization.localized("Accessibility Info"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var accessibilityOverview: some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: station.accessibility?.summary.iconName ?? "questionmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(station.accessibility?.summary.color ?? .gray)

                Text(AppLocalization.localized(station.accessibility?.summary.titleKey ?? "Accessibility not verified"))
                    .font(.headline)

                if let rating = station.accessibility?.communityRating {
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= Int(rating) ? "star.fill" : "star")
                                .foregroundStyle(.yellow)
                        }
                        Text(String(format: "%.1f", rating))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var mobilitySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(AppLocalization.localized("Mobility"), systemImage: "figure.roll")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    AccessibleFeatureRow(
                        icon: "arrow.up.arrow.down.circle.fill",
                        title: AppLocalization.localized("Elevator"),
                        availability: accessibility.elevatorAvailability,
                        details: accessibility.elevatorLocations
                    )

                    AccessibleFeatureRow(
                        icon: "figure.roll",
                        title: AppLocalization.localized("Wheelchair Ramp"),
                        availability: accessibility.wheelchairRampAvailability,
                        details: accessibility.accessibleEntrances
                    )

                    AccessibleFeatureRow(
                        icon: "arrow.up.to.line",
                        title: AppLocalization.localized("Escalator"),
                        availability: accessibility.escalatorAvailability,
                        details: []
                    )
                }
            }
        }
    }

    private var visionSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(AppLocalization.localized("Vision"), systemImage: "eye.slash")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    AccessibleFeatureRow(
                        icon: "hand.raised.fill",
                        title: AppLocalization.localized("Tactile Path"),
                        availability: accessibility.tactilePathAvailability,
                        details: accessibility.tactilePathAvailability == .available ? [AppLocalization.text(
                            english: "Coverage: \(Int(accessibility.tactilePathCoverage * 100))%",
                            chinese: "覆盖率：\(Int(accessibility.tactilePathCoverage * 100))%"
                        )] : []
                    )

                    AccessibleFeatureRow(
                        icon: "textformat.abc",
                        title: AppLocalization.localized("Braille Signs"),
                        availability: accessibility.brailleSignsAvailability,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "speaker.wave.2.fill",
                        title: AppLocalization.localized("Audio Announcement"),
                        availability: accessibility.audioAnnouncementAvailability,
                        details: []
                    )
                }
            }
        }
    }

    private var hearingSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(AppLocalization.localized("Hearing"), systemImage: "ear.badge.waveform")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    AccessibleFeatureRow(
                        icon: "eye.fill",
                        title: AppLocalization.localized("Visual Display"),
                        availability: accessibility.visualAnnouncementAvailability,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "ear.badge.waveform",
                        title: AppLocalization.localized("Hearing Loop"),
                        availability: accessibility.hearingLoopAvailability,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "hand.thumbsup.fill",
                        title: AppLocalization.localized("Sign Language"),
                        availability: accessibility.signLanguageDisplayAvailability,
                        details: []
                    )
                }
            }
        }
    }

    private var cognitiveSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(AppLocalization.localized("Cognitive"), systemImage: "brain.head.profile")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    AccessibleFeatureRow(
                        icon: "textformat.size",
                        title: AppLocalization.localized("Simplified Signage"),
                        availability: accessibility.simplifiedSignageAvailability,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "paintpalette.fill",
                        title: AppLocalization.localized("Color Coding"),
                        availability: accessibility.colorCodingAvailability,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "photo",
                        title: AppLocalization.localized("Pictograms"),
                        availability: accessibility.pictogramsAvailability,
                        details: []
                    )
                }
            }
        }
    }

    private var communitySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(AppLocalization.localized("Community"), systemImage: "person.3.fill")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    HStack {
                        Text(AppLocalization.localized("Reports"))
                        Spacer()
                        Text("\(accessibility.reportCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(AppLocalization.localized("Last Verified"))
                        Spacer()
                        if let date = accessibility.lastVerifiedDate {
                            Text(date.formatted())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(AppLocalization.localized("Not verified"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(AppLocalization.localized("Report Issue")) {
                        // Navigate to report view
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

struct AccessibleFeatureRow: View {
    let icon: String
    let title: String
    let availability: AccessibilityAvailability
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(availability.color)
                    .frame(width: 24)
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                Text(availability.localizedStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(availability.color)
                    .frame(width: 8, height: 8)
            }

            if !details.isEmpty {
                ForEach(details, id: \.self) { detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }
            }
        }
    }
}

private extension AccessibilityAvailability {
    var color: Color {
        switch self {
        case .available:
            return .green
        case .unavailable:
            return .red
        case .unknown:
            return .gray
        }
    }
}

private extension StationAccessibilitySummary {
    var titleKey: String {
        switch self {
        case .fullyAccessible:
            return "Fully Accessible"
        case .partial:
            return "Partial Accessibility"
        case .notVerified:
            return "Accessibility not verified"
        }
    }

    var iconName: String {
        switch self {
        case .fullyAccessible:
            return "checkmark.circle.fill"
        case .partial:
            return "info.circle.fill"
        case .notVerified:
            return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .fullyAccessible:
            return .green
        case .partial:
            return .orange
        case .notVerified:
            return .gray
        }
    }
}
