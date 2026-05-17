import SwiftUI

struct StationDetailView: View {
    let station: Station
    @Environment(DIContainer.self) private var container
    @State private var viewModel: StationDetailViewModel?
    @Environment(AccessibilityService.self) private var accessibilityService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                stationHeader
                linesSection
                accessibilitySection
                arrivalsSection
                exitsSection
            }
            .padding()
        }
        .navigationTitle(station.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel = StationDetailViewModel(aMapService: container.aMapService)
            viewModel?.loadStation(station)
            await viewModel?.loadStationExits()
            await viewModel?.loadTrainTimes()
        }
    }

    private var stationHeader: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(station.localizedName)
                            .font(.title)
                            .fontWeight(.bold)
                        if let alternateName = station.alternateLocalizedName {
                            Text(alternateName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if station.isTransferStation {
                        Text(AppLocalization.localized("Transfer"))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                if station.accessibility?.summary == .fullyAccessible {
                    HStack {
                        Image(systemName: "figure.roll")
                            .foregroundStyle(.green)
                        Text(AppLocalization.localized("Fully Accessible Station"))
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var linesSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Lines"))
                    .font(.headline)

                ForEach(station.lines) { line in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: line.colorHex))
                            .frame(width: 12, height: 12)
                        Text(line.localizedName)
                            .font(.body)
                        if let alternateName = line.alternateLocalizedName {
                            Text(alternateName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var accessibilitySection: some View {
        GlassCard {
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
                    } else {
                        accessibilityUnverifiedNote
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
                        subtitle: accessibility.tactilePathAvailability == .available ? AppLocalization.text(
                            english: "Coverage: \(Int(accessibility.tactilePathCoverage * 100))%",
                            chinese: "覆盖率：\(Int(accessibility.tactilePathCoverage * 100))%"
                        ) : accessibility.tactilePathAvailability.localizedStatusText,
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
            Text(AppLocalization.localized("AMap does not provide station accessibility status; no local verification is available."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private var arrivalsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Train Times"))
                    .font(.headline)

                if viewModel?.isLoading == true {
                    ProgressView()
                } else if viewModel?.arrivals.isEmpty ?? true {
                    Text(viewModel?.errorMessage ?? AppLocalization.localized("Schedule unavailable"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel?.arrivals ?? []) { arrival in
                        ArrivalCountdown(arrival: arrival)
                    }

                    if let statusMessage = viewModel?.trainTimeStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel?.arrivals.contains(where: \.hasLiveCountdown) == false {
                        Text(AppLocalization.localized("Shows first/last train times, not live arrival countdowns."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var exitsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Exits"))
                    .font(.headline)

                if viewModel?.isLoadingExits == true {
                    ProgressView()
                } else if displayedExits.isEmpty {
                    Text(viewModel?.exitStatusMessage ?? AppLocalization.localized("Exit information not provided"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedExits) { exit in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(exit.localizedName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let alternateName = exit.alternateLocalizedName {
                                    Text(alternateName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !exit.nearbyLandmarks.isEmpty {
                                    Text(exit.nearbyLandmarks.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if exit.isAccessible {
                                Image(systemName: "figure.roll")
                                    .foregroundStyle(.green)
                            }
                            if exit.hasElevator {
                                Image(systemName: "arrow.up.arrow.down")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }

                    if let exitStatusMessage = viewModel?.exitStatusMessage {
                        Text(exitStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var displayedExits: [StationExit] {
        viewModel?.station?.exits ?? station.exits
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
