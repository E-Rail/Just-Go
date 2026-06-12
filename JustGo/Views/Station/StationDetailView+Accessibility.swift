import SwiftUI

extension StationDetailView {
    var accessibilitySection: some View {
        let station = displayedStation
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Accessibility"))
                    .font(.headline)

                if let accessibility = station.accessibility {
                    accessibilitySummary(accessibility)

                    if accessibility.hasVerifiedAccessibilityData {
                        verifiedAccessibilitySections(accessibility)

                        if accessibility.hasUnverifiedCoreAccessibilityData {
                            Text(AppLocalization.localized("Some facilities are not verified"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if accessibility.dataSource == "beijing_official" {
                            accessibilitySourceNote(accessibility)
                        }
                    } else {
                        accessibilitySourceNote(accessibility)
                    }
                } else {
                    accessibilityUnverifiedNote
                }
            }
        }
    }

    @ViewBuilder
    private func verifiedAccessibilitySections(_ accessibility: StationAccessibility) -> some View {
        if accessibility.hasMobilityRows {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Mobility"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if accessibility.elevatorAvailability != .unknown || !accessibility.elevatorLocations.isEmpty {
                    accessibilityRow(
                        icon: "arrow.up.arrow.down.circle.fill",
                        title: "Elevator",
                        subtitle: detailText(accessibility.elevatorLocations, fallback: accessibility.elevatorAvailability.localizedStatusText),
                        status: AccessibilityStatus(accessibility.elevatorAvailability)
                    )
                }

                if accessibility.wheelchairRampAvailability != .unknown || !accessibility.accessibleEntrances.isEmpty {
                    accessibilityRow(
                        icon: "figure.roll",
                        title: "Wheelchair Ramp",
                        subtitle: detailText(accessibility.accessibleEntrances, fallback: accessibility.wheelchairRampAvailability.localizedStatusText),
                        status: AccessibilityStatus(accessibility.wheelchairRampAvailability)
                    )
                }

                if accessibility.escalatorAvailability != .unknown {
                    accessibilityRow(
                        icon: "arrow.up.to.line",
                        title: "Escalator",
                        subtitle: accessibility.escalatorAvailability.localizedStatusText,
                        status: AccessibilityStatus(accessibility.escalatorAvailability)
                    )
                }
            }
        }

        if accessibility.hasVisionRows {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Vision"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if accessibility.tactilePathAvailability != .unknown {
                    accessibilityRow(
                        icon: "hand.raised.fill",
                        title: "Tactile Path",
                        subtitle: tactilePathDetail(accessibility),
                        status: AccessibilityStatus(accessibility.tactilePathAvailability)
                    )
                }

                if accessibility.audioAnnouncementAvailability != .unknown {
                    accessibilityRow(
                        icon: "speaker.wave.2.fill",
                        title: "Audio Announcement",
                        subtitle: accessibility.audioAnnouncementAvailability.localizedStatusText,
                        status: AccessibilityStatus(accessibility.audioAnnouncementAvailability)
                    )
                }
            }
        }

        if accessibility.accessibleRestroomAvailability != .unknown {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Station Facilities"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                accessibilityRow(
                    icon: "figure.roll",
                    title: "Accessible Restroom",
                    subtitle: accessibility.accessibleRestroomAvailability.localizedStatusText,
                    status: AccessibilityStatus(accessibility.accessibleRestroomAvailability)
                )
            }
        }

        if accessibility.hasHearingRows {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Hearing"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if accessibility.visualAnnouncementAvailability != .unknown {
                    accessibilityRow(
                        icon: "eye.fill",
                        title: "Visual Display",
                        subtitle: accessibility.visualAnnouncementAvailability.localizedStatusText,
                        status: AccessibilityStatus(accessibility.visualAnnouncementAvailability)
                    )
                }
            }
        }
    }

    private var accessibilityUnverifiedNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.localized("Accessibility not verified"))
                .font(.subheadline)
                .fontWeight(.medium)
            Text(AppLocalization.localized("Official accessibility data is not available for this station yet."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accessibilitySourceNote(_ accessibility: StationAccessibility) -> some View {
        let message: String
        if accessibility.dataSource == "beijing_official" {
            message = AppLocalization.localized("Accessibility information from official Beijing Subway data.")
        } else if accessibility.dataSource?.contains("_official") == true ||
            accessibility.dataSource?.contains("official") == true {
            message = AppLocalization.localized("Accessibility information from official city data.")
        } else {
            message = AppLocalization.localized("Official accessibility data is not available for this station yet.")
        }
        return Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func accessibilitySummary(_ accessibility: StationAccessibility) -> some View {
        HStack(spacing: 10) {
            Image(systemName: accessibility.summary.iconName)
                .foregroundStyle(accessibility.summary.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.localized(accessibility.summary.titleKey))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(AppLocalization.localized(accessibility.summary.descriptionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func accessibilityRow(icon: String, title: String, subtitle: String, status: AccessibilityStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(status.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.localized(title))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(AppLocalization.localized(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
        }
    }

    private func detailText(_ details: [String], fallback: String) -> String {
        let text = details.joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    private func tactilePathDetail(_ accessibility: StationAccessibility) -> String {
        guard accessibility.tactilePathAvailability == .available else {
            return accessibility.tactilePathAvailability.localizedStatusText
        }
        guard accessibility.tactilePathCoverage > 0 else {
            return AppLocalization.localized("Tactile path available")
        }
        return AppLocalization.text(
            english: "Coverage: \(Int(accessibility.tactilePathCoverage * 100))%",
            chinese: "覆盖率：\(Int(accessibility.tactilePathCoverage * 100))%"
        )
    }
}

enum AccessibilityStatus {
    case available
    case unavailable
    case unknown

    init(_ availability: AccessibilityAvailability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable:
            self = .unavailable
        case .unknown:
            self = .unknown
        }
    }

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

private extension StationAccessibility {
    var hasMobilityRows: Bool {
        elevatorAvailability != .unknown ||
            !elevatorLocations.isEmpty ||
            wheelchairRampAvailability != .unknown ||
            !accessibleEntrances.isEmpty ||
            escalatorAvailability != .unknown
    }

    var hasVisionRows: Bool {
        tactilePathAvailability != .unknown ||
            audioAnnouncementAvailability != .unknown
    }

    var hasHearingRows: Bool {
        visualAnnouncementAvailability != .unknown
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

    var descriptionKey: String {
        switch self {
        case .fullyAccessible:
            return "Station accessibility data is verified"
        case .partial:
            return "Some accessibility features are verified"
        case .notVerified:
            return "Station accessibility data is missing"
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
