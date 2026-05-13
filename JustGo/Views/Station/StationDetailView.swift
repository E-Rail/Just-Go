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
            await viewModel?.loadRealTimeArrivals()
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

                if station.accessibility?.isFullyAccessible == true {
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
                    // Mobility
                    if accessibility.hasElevator || accessibility.hasWheelchairRamp {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AppLocalization.localized("Mobility"))
                                .font(.subheadline)
                                .fontWeight(.medium)

                            if accessibility.hasElevator {
                                accessibilityRow(
                                    icon: "arrow.up.arrow.down.circle.fill",
                                    title: "Elevator",
                                    subtitle: accessibility.elevatorLocations.joined(separator: ", "),
                                    status: accessibility.elevatorStatusEnum == .operational ? .available : .unavailable
                                )
                            }

                            if accessibility.hasWheelchairRamp {
                                accessibilityRow(
                                    icon: "figure.roll",
                                    title: "Wheelchair Ramp",
                                    subtitle: accessibility.accessibleEntrances.joined(separator: ", "),
                                    status: .available
                                )
                            }
                        }
                    }

                    // Vision
                    if accessibility.hasTactilePath || accessibility.hasBrailleSigns || accessibility.hasAudioAnnouncement {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AppLocalization.localized("Vision"))
                                .font(.subheadline)
                                .fontWeight(.medium)

                            if accessibility.hasTactilePath {
                                accessibilityRow(
                                    icon: "hand.raised.fill",
                                    title: "Tactile Path",
                                    subtitle: AppLocalization.text(
                                        english: "Coverage: \(Int(accessibility.tactilePathCoverage * 100))%",
                                        chinese: "覆盖率：\(Int(accessibility.tactilePathCoverage * 100))%"
                                    ),
                                    status: .available
                                )
                            }

                            if accessibility.hasBrailleSigns {
                                accessibilityRow(
                                    icon: "textformat.abc",
                                    title: "Braille Signs",
                                    subtitle: AppLocalization.localized("Available"),
                                    status: .available
                                )
                            }

                            if accessibility.hasAudioAnnouncement {
                                accessibilityRow(
                                    icon: "speaker.wave.2.fill",
                                    title: "Audio Announcement",
                                    subtitle: AppLocalization.localized("Available"),
                                    status: .available
                                )
                            }
                        }
                    }

                    // Hearing
                    if accessibility.hasVisualAnnouncement || accessibility.hasHearingLoop {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AppLocalization.localized("Hearing"))
                                .font(.subheadline)
                                .fontWeight(.medium)

                            if accessibility.hasVisualAnnouncement {
                                accessibilityRow(
                                    icon: "eye.fill",
                                    title: "Visual Display",
                                    subtitle: AppLocalization.localized("Available"),
                                    status: .available
                                )
                            }

                            if accessibility.hasHearingLoop {
                                accessibilityRow(
                                    icon: "ear.badge.waveform",
                                    title: "Hearing Loop",
                                    subtitle: AppLocalization.localized("Available"),
                                    status: .available
                                )
                            }
                        }
                    }
                } else {
                    Text(AppLocalization.localized("No accessibility information available"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func accessibilityRow(icon: String, title: String, subtitle: String, status: AccessibilityStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(status == .available ? .green : .red)
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
                .fill(status == .available ? Color.green : Color.red)
                .frame(width: 8, height: 8)
        }
    }

    private var arrivalsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Real-Time Arrivals"))
                    .font(.headline)

                if viewModel?.arrivals.isEmpty ?? true {
                    Text(viewModel?.errorMessage ?? AppLocalization.localized("No real-time data available"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel?.arrivals ?? []) { arrival in
                        ArrivalCountdown(arrival: arrival)
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

                ForEach(station.exits) { exit in
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
            }
        }
    }
}

enum AccessibilityStatus {
    case available
    case unavailable
    case unknown
}
