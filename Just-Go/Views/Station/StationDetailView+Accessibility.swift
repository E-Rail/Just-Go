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
                        title: AppLocalization.localized("Elevator"),
                        subtitle: detailText(accessibility.elevatorLocations, fallback: accessibility.elevatorAvailability.localizedStatusText),
                        status: AccessibilityStatus(accessibility.elevatorAvailability)
                    )
                }

                if accessibility.wheelchairRampAvailability != .unknown {
                    accessibilityRow(
                        icon: "figure.roll",
                        title: AppLocalization.localized("Wheelchair Ramp"),
                        subtitle: detailText(accessibility.accessibleEntrances, fallback: accessibility.wheelchairRampAvailability.localizedStatusText),
                        status: AccessibilityStatus(accessibility.wheelchairRampAvailability)
                    )
                } else if !accessibility.accessibleEntrances.isEmpty {
                    // An exit letter, under its own heading, claiming nothing.
                    //
                    // 484 of the 582 bundled accessibility records are OpenStreetMap entrance data:
                    // hasElevator null, hasWheelchairRamp null, accessibleEntrances ["D"]. That was
                    // rendered as "♿ Wheelchair Ramp / D" under a "Partial Accessibility — Some
                    // accessibility features are verified" header, above a note saying the data was
                    // not available. OSM says a door exists there. It does not say it is step-free,
                    // and for the rider this section is written for, the difference between those
                    // two is the difference between reaching the platform and being stranded at the
                    // concourse. The letter is still worth showing; the wheelchair claim is not.
                    accessibilityRow(
                        icon: "door.left.hand.open",
                        title: AppLocalization.text(
                            english: "Station exits",
                            simplified: "车站出入口",
                            traditional: "車站出入口"
                        ),
                        subtitle: detailText(accessibility.accessibleEntrances, fallback: ""),
                        status: .unknown
                    )
                }

                if accessibility.escalatorAvailability != .unknown {
                    accessibilityRow(
                        icon: "arrow.up.to.line",
                        title: AppLocalization.localized("Escalator"),
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
                        title: AppLocalization.localized("Tactile Path"),
                        subtitle: tactilePathDetail(accessibility),
                        status: AccessibilityStatus(accessibility.tactilePathAvailability)
                    )
                }

                if accessibility.audioAnnouncementAvailability != .unknown {
                    accessibilityRow(
                        icon: "speaker.wave.2.fill",
                        title: AppLocalization.localized("Audio Announcement"),
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
                    title: AppLocalization.localized("Accessible Restroom"),
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
                        title: AppLocalization.localized("Visual Display"),
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

    /// Where this station's accessibility data actually came from.
    ///
    /// The branches here were `dataSource == "beijing_official"` and `contains("official")`, and no
    /// pack has ever shipped either. The only three values that exist are
    /// `openstreetmap/subway-entrances` (366 stations), `data.taipei/taipei-metro-station-exits`
    /// (118) and `data.gov.hk/mtr-barrier-free-facilities` (98) — none containing the substring
    /// "official" — so every station fell through to "not available yet", including Hong Kong's
    /// fully surveyed barrier-free records. Matched against the values that ship.
    private func accessibilitySourceNote(_ accessibility: StationAccessibility) -> some View {
        let source = accessibility.dataSource ?? ""
        let message: String
        if source.hasPrefix("data.gov.hk") || source.hasPrefix("data.taipei") {
            message = AppLocalization.localized("Accessibility information from official city data.")
        } else if source.hasPrefix("openstreetmap") {
            message = AppLocalization.text(
                english: "Entrances mapped by OpenStreetMap contributors. Step-free access is not recorded.",
                simplified: "出入口来自 OpenStreetMap 社区测绘，未记录无障碍通行信息。",
                traditional: "出入口來自 OpenStreetMap 社群測繪，未記錄無障礙通行資訊。"
            )
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
                Text(accessibility.summary.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(accessibility.summary.description)
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
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(subtitle)
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
    var title: String {
        switch self {
        case .fullyAccessible:
            return AppLocalization.localized("Fully Accessible")
        case .partial:
            return AppLocalization.localized("Partial Accessibility")
        case .notVerified:
            return AppLocalization.localized("Accessibility not verified")
        }
    }

    var description: String {
        switch self {
        case .fullyAccessible:
            return AppLocalization.localized("Station accessibility data is verified")
        case .partial:
            return AppLocalization.localized("Some accessibility features are verified")
        case .notVerified:
            return AppLocalization.localized("Station accessibility data is missing")
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
