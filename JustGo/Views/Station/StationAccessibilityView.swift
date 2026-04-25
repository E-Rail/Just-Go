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
        .navigationTitle("Accessibility Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var accessibilityOverview: some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: station.accessibility?.isFullyAccessible == true ? "figure.roll" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(station.accessibility?.isFullyAccessible == true ? .green : .orange)

                Text(station.accessibility?.isFullyAccessible == true ? "Fully Accessible" : "Partial Accessibility")
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
                Label("Mobility", systemImage: "figure.roll")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    AccessibleFeatureRow(
                        icon: "arrow.up.arrow.down.circle.fill",
                        title: "Elevator",
                        isAvailable: accessibility.hasElevator,
                        details: accessibility.elevatorLocations
                    )

                    AccessibleFeatureRow(
                        icon: "figure.roll",
                        title: "Wheelchair Ramp",
                        isAvailable: accessibility.hasWheelchairRamp,
                        details: accessibility.accessibleEntrances
                    )

                    AccessibleFeatureRow(
                        icon: "arrow.up.to.line",
                        title: "Escalator",
                        isAvailable: accessibility.hasEscalator,
                        details: []
                    )
                }
            }
        }
    }

    private var visionSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Vision", systemImage: "eye.slash")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    AccessibleFeatureRow(
                        icon: "hand.raised.fill",
                        title: "Tactile Path",
                        isAvailable: accessibility.hasTactilePath,
                        details: ["Coverage: \(Int(accessibility.tactilePathCoverage * 100))%"]
                    )

                    AccessibleFeatureRow(
                        icon: "textformat.abc",
                        title: "Braille Signs",
                        isAvailable: accessibility.hasBrailleSigns,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "speaker.wave.2.fill",
                        title: "Audio Announcement",
                        isAvailable: accessibility.hasAudioAnnouncement,
                        details: []
                    )
                }
            }
        }
    }

    private var hearingSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Hearing", systemImage: "ear.badge.waveform")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    AccessibleFeatureRow(
                        icon: "eye.fill",
                        title: "Visual Display",
                        isAvailable: accessibility.hasVisualAnnouncement,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "ear.badge.waveform",
                        title: "Hearing Loop",
                        isAvailable: accessibility.hasHearingLoop,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "hand.thumbsup.fill",
                        title: "Sign Language",
                        isAvailable: accessibility.hasSignLanguageDisplay,
                        details: []
                    )
                }
            }
        }
    }

    private var cognitiveSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Cognitive", systemImage: "brain.head.profile")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    AccessibleFeatureRow(
                        icon: "textformat.size",
                        title: "Simplified Signage",
                        isAvailable: accessibility.hasSimplifiedSignage,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "paintpalette.fill",
                        title: "Color Coding",
                        isAvailable: accessibility.hasColorCoding,
                        details: []
                    )

                    AccessibleFeatureRow(
                        icon: "photo",
                        title: "Pictograms",
                        isAvailable: accessibility.hasPictograms,
                        details: []
                    )
                }
            }
        }
    }

    private var communitySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Community", systemImage: "person.3.fill")
                    .font(.headline)

                if let accessibility = station.accessibility {
                    HStack {
                        Text("Reports")
                        Spacer()
                        Text("\(accessibility.reportCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Last Verified")
                        Spacer()
                        if let date = accessibility.lastVerifiedDate {
                            Text(date.formatted())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not verified")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Report Issue") {
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
    let isAvailable: Bool
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(isAvailable ? .green : .red)
                    .frame(width: 24)
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                Circle()
                    .fill(isAvailable ? Color.green : Color.red)
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
