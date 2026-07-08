import SwiftUI

struct StationDetailView: View {
    let station: Station
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(AccessibilityReportService.self) var accessibilityReportService
    @State var viewModel: StationDetailViewModel?
    @State var selectedStationImage: FullScreenStationImage?
    @State var showStationReport = false
    @State var reportItemType: VerificationItemType = .elevator
    @State var reportStatus: VerificationStatus = .outOfService
    @State var reportSeverity: AccessibilityReportSeverity = .medium
    @State var reportNote = ""

    private var isFavorited: Bool {
        tripMemoryService.isFavorite(stationID: displayedStation.stationID, cityID: displayedStation.cityID)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                stationHeader
                planRouteSection
                linesSection
                beforeYouGoSection
                accessibilitySection
                stationEssentialsSection
                stationGuideSection
                arrivalsSection
                serviceStatusSection
                stationMapSection
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle(displayedStation.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let s = displayedStation
                    if isFavorited {
                        tripMemoryService.removeFavorite(id: "\(s.cityID)|\(s.stationID)")
                    } else {
                        let city = container.cityService.getCity(byID: s.cityID)
                        tripMemoryService.addFavorite(
                            station: s,
                            cityName: city?.name ?? s.cityID,
                            cityNameEn: city?.nameEn
                        )
                    }
                } label: {
                    Image(systemName: isFavorited ? "star.fill" : "star")
                        .foregroundStyle(isFavorited ? .yellow : .primary)
                }
                .accessibilityLabel(isFavorited
                    ? AppLocalization.localized("Remove from favorites")
                    : AppLocalization.localized("Add to favorites")
                )
            }
        }
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
                    title: AppLocalization.localized("Schedule"),
                    confidence: viewModel?.scheduleConfidence ?? .unknown,
                    icon: "clock"
                )
                confidenceRow(
                    title: AppLocalization.localized("Station Map"),
                    confidence: viewModel?.stationMapConfidence ?? .unknown,
                    icon: "map"
                )
                confidenceRow(
                    title: AppLocalization.localized("Accessibility"),
                    confidence: viewModel?.accessibilityConfidence ?? .unknown,
                    icon: "accessibility"
                )
                confidenceRow(
                    title: AppLocalization.localized("Live arrivals"),
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
                Text(title)
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

    private var planRouteSection: some View {
        let station = displayedStation
        let place = TransitPlace(
            name: station.localizedName,
            coordinate: station.coordinate,
            source: .mapKit
        )
        return PlanRouteButtons(place: place, cityID: station.cityID, onSelected: { dismiss() })
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

/// The "From here" / "To here" route-planning pair shown on a station or place popup.
/// Tapping a button pre-fills the route planner (origin/destination), switches to the Route tab,
/// and calls `onSelected` so the presenting popup can dismiss itself.
///
/// Colors use `Color.adaptive(hex: selectedThemeHex)` directly rather than the semantic
/// `Color.accentColor`: the latter resolves from the environment `.tint`, which hasn't propagated
/// on a freshly-presented sheet's first frame and momentarily flashes system blue. The adaptive
/// color is a concrete dynamic color with no environment dependency, so it never flashes and still
/// matches the app accent (and lifts for legibility in dark mode).
struct PlanRouteButtons: View {
    let place: TransitPlace
    /// Set when the place belongs to a known city (a station detail); nil for map POIs.
    var cityID: String? = nil
    var onSelected: () -> Void = {}

    @Environment(AppState.self) private var appState
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue
    private var themeColor: Color { Color.adaptive(hex: selectedThemeHex) }

    var body: some View {
        HStack(spacing: 10) {
            // "From here" — white (themed surface) with green text + outline.
            Button {
                appState.pendingRouteInput = AppState.PendingRouteInput(place: place, role: .origin, cityID: cityID)
                appState.selectedTab = 1
                onSelected()
            } label: {
                Label(
                    AppLocalization.text(english: "From here", simplified: "从此出发", traditional: "從此出發"),
                    systemImage: "arrow.up.circle.fill"
                )
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(themeColor.opacity(0.4), lineWidth: 1)
                )
                .foregroundStyle(themeColor)
            }
            .buttonStyle(.plain)

            // "To here" — solid theme green with white text.
            Button {
                appState.pendingRouteInput = AppState.PendingRouteInput(place: place, role: .destination, cityID: cityID)
                appState.selectedTab = 1
                onSelected()
            } label: {
                Label(
                    AppLocalization.text(english: "To here", simplified: "到此到达", traditional: "到此到達"),
                    systemImage: "arrow.down.circle.fill"
                )
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(themeColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}
