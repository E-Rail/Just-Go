import SwiftUI

struct StationDetailView: View {
    let station: Station
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State var viewModel: StationDetailViewModel?
    @State var selectedStationImage: FullScreenStationImage?
    @State var showQuickTagDialog = false
    @State var selectedOfficialInformationCategory: OfficialStationInformationCategory = .firstLast

    private var currentQuickTag: StationQuickTag? {
        tripMemoryService.quickTag(stationID: displayedStation.stationID, cityID: displayedStation.cityID)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                stationHeader
                planRouteSection
                linesSection
                beforeYouGoSection
                officialStationInformationSection
                if showsBundledStationSections {
                    accessibilitySection
                    stationEssentialsSection
                    stationGuideSection
                    arrivalsSection
                }
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
                    showQuickTagDialog = true
                } label: {
                    Image(systemName: currentQuickTag == nil ? "tag" : "tag.fill")
                        .foregroundStyle(currentQuickTag == nil ? .primary : Color.accentColor)
                }
                .accessibilityLabel(currentQuickTag == nil
                    ? AppLocalization.localized("Add Quick Tag")
                    : AppLocalization.localized("Edit Quick Tag")
                )
            }
        }
        .task {
            viewModel = container.makeStationDetailViewModel()
            viewModel?.loadStation(station)
            await viewModel?.loadCityPack()
            await viewModel?.loadRiderInformation()
        }
        .fullScreenCover(item: $selectedStationImage) { image in
            FullScreenStationImageView(image: image)
        }
        .quickTagEditor(
            isPresented: $showQuickTagDialog,
            title: displayedStation.localizedName,
            currentQuickTag: currentQuickTag,
            onSave: { kind in
                let station = displayedStation
                let city = container.cityService.getCity(byID: station.cityID)
                tripMemoryService.setQuickTag(
                    station: station,
                    cityName: city?.name ?? station.cityID,
                    cityNameEn: city?.nameEn,
                    kind: kind
                )
            },
            onDelete: {
                if let currentQuickTag {
                    tripMemoryService.deleteQuickTag(id: currentQuickTag.id)
                }
            }
        )
    }

    var displayedStation: Station {
        viewModel?.station ?? station
    }

    var usesNativeStationInformationSurface: Bool {
        // Hong Kong ships its station data in the bundle, so it is always native. Every other
        // city is native exactly when the bundled Station Information directory routes the station
        // to an online source — Beijing, Shanghai, Guangzhou, Hangzhou today, and any city added with
        // no code change here. The directory is synchronous, so this is stable once the view model
        // exists; before that, ask the directory directly to avoid a first-frame flash.
        if displayedStation.cityID == "8100" {
            return true
        }
        if let viewModel {
            return viewModel.usesCategorizedStationInformation
        }
        return container.stationInformationDirectory.onlineEntry(forStationID: displayedStation.id) != nil
    }

    /// The bundled sections (schedules, accessibility, essentials, guide) return whenever
    /// the native online surface has nothing to serve — the fetch failed and no snapshot is
    /// cached — so a blocked or offline network still gets the offline official data instead
    /// of only an error card.
    /// Applies to every live-fetch city, not just Beijing: the directory lookup used to miss for
    /// map-opened stations, so Shanghai and Guangzhou always fell into the non-native branch above
    /// and kept their bundled sections by accident. Now that they reach the native surface too,
    /// they need the same offline fallback Beijing had.
    var showsBundledStationSections: Bool {
        guard usesNativeStationInformationSurface else { return true }
        return viewModel?.officialStationInformation == nil &&
            viewModel?.officialStationInformationError != nil
    }

    private var beforeYouGoSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Before You Go"))
                    .font(.headline)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 8)], alignment: .leading, spacing: 8) {
                    confidenceChip(
                        title: AppLocalization.localized("Schedule"),
                        confidence: viewModel?.scheduleConfidence ?? .unknown,
                        icon: "clock"
                    )
                    confidenceChip(
                        title: AppLocalization.text(
                            english: "Layout link",
                            simplified: "布局链接",
                            traditional: "佈局連結"
                        ),
                        confidence: viewModel?.stationMapConfidence ?? .unknown,
                        icon: "map"
                    )
                    confidenceChip(
                        title: AppLocalization.localized("Accessibility"),
                        confidence: viewModel?.accessibilityConfidence ?? .unknown,
                        icon: "accessibility"
                    )
                    confidenceChip(
                        title: AppLocalization.localized("Live arrivals"),
                        confidence: viewModel?.liveArrivalConfidence ?? .unknown,
                        icon: "wave.3.right"
                    )
                }
            }
        }
    }

    private func confidenceChip(title: String, confidence: DataConfidence, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(confidence.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(confidence.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(confidence.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(station.uniqueLogicalLines) { line in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color(hex: line.colorHex))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.localizedName)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                if let alternateName = line.alternateLocalizedName {
                                    Text(alternateName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.appSurface, in: Capsule())
                .overlay(
                    Capsule()
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
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                // Raw hex, not `themeColor`: this is a solid fill under white text, and
                // `Color.adaptive` lightens toward white in dark mode specifically for
                // *foreground* legibility — used as a fill it collapses contrast instead.
                .background(Color(hex: selectedThemeHex), in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}
