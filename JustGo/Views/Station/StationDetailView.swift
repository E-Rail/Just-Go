import SwiftUI

private extension DataConfidence {
    var color: Color {
        switch self {
        case .official, .communityVerified: return .green
        case .mapKit, .estimated: return .blue
        case .personal, .sourcePending: return .orange
        case .unavailable, .unknown: return .gray
        }
    }
}

struct StationDetailView: View {
    let station: Station
    @Environment(DIContainer.self) private var container
    @State var viewModel: StationDetailViewModel?
    @State var selectedStationImage: FullScreenStationImage?
    @State var showStationReport = false
    @State var reportItemType: VerificationItemType = .elevator
    @State var reportStatus: VerificationStatus = .outOfService
    @State var reportSeverity: AccessibilityReportSeverity = .medium
    @State var reportNote = ""
    @Environment(AccessibilityReportService.self) var accessibilityReportService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                stationHeader
                linesSection
                beforeYouGoSection
                accessibilitySection
                stationEssentialsSection
                arrivalsSection
                serviceStatusSection
                stationMapSection
            }
            .padding()
        }
        .navigationTitle(displayedStation.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel = container.makeStationDetailViewModel()
            viewModel?.loadStation(station)
            await viewModel?.loadCityPack()
            await viewModel?.loadTrainTimes()
        }
        .fullScreenCover(item: $selectedStationImage) { image in
            FullScreenStationImageView(image: image)
        }
        .sheet(isPresented: $showStationReport) {
            stationReportSheet
        }
    }

    var displayedStation: Station {
        viewModel?.station ?? station
    }

    private var beforeYouGoSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Before You Go"))
                    .font(.headline)

                Text(AppLocalization.localized("Best data available"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                confidenceRow(
                    title: "Schedule",
                    confidence: viewModel?.scheduleConfidence ?? .unknown,
                    icon: "clock"
                )
                confidenceRow(
                    title: "Station Map",
                    confidence: viewModel?.stationMapConfidence ?? .unknown,
                    icon: "map"
                )
                confidenceRow(
                    title: "Accessibility",
                    confidence: viewModel?.accessibilityConfidence ?? .unknown,
                    icon: "accessibility"
                )
                confidenceRow(
                    title: "Live arrivals",
                    confidence: viewModel?.liveArrivalConfidence ?? .unknown,
                    icon: "wave.3.right"
                )

                if displayedStation.isTransferStation {
                    Label(AppLocalization.localized("Transfer station"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                if !displayedStation.facilities.isEmpty {
                    Label(AppLocalization.localized("Station essentials available"), systemImage: "info.circle.fill")
                        .font(.caption)
                }
                if viewModel?.arrivals.isEmpty == false {
                    Label(AppLocalization.localized("First and last train information available"), systemImage: "clock.fill")
                        .font(.caption)
                }

                Text(AppLocalization.localized("JustGo shows what is known before you enter the station."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func confidenceRow(title: String, confidence: DataConfidence, icon: String) -> some View {
        Label {
            HStack {
                Text(AppLocalization.localized(title))
                Spacer()
                Text(confidence.label)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(confidence.color)
        }
        .font(.subheadline)
    }

    private var stationHeader: some View {
        let station = displayedStation
        return GlassCard {
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
                        Label(AppLocalization.localized("Transfer"), systemImage: "arrow.triangle.2.circlepath")
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
        let station = displayedStation
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Lines"))
                    .font(.headline)

                ForEach(station.uniqueLogicalLines) { line in
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
}
