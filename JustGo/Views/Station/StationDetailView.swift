import SwiftUI

/// The station sheet's top-level sections. Everything used to stack in one column — ten cards, two
/// of them tall — so reaching the entrance map meant scrolling past the whole page. These group the
/// same content by the question a rider arrived with, and only the tabs that have something to show
/// are offered.
enum StationDetailTab: String, CaseIterable, Identifiable {
    case trains
    case map
    case station

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trains:
            return AppLocalization.text(english: "Trains", simplified: "列车", traditional: "列車")
        case .map:
            return AppLocalization.localized("Map")
        case .station:
            return AppLocalization.text(english: "Station", simplified: "车站", traditional: "車站")
        }
    }

    var icon: String {
        switch self {
        case .trains: return "clock"
        case .map: return "map"
        case .station: return "building.columns"
        }
    }
}

struct StationDetailView: View {
    let station: Station
    /// False only when this screen is a destination on the map's own navigation stack: there,
    /// "Route here" is a *replacement* of this screen by the entry page, and the map performs
    /// both halves in a single write to its path. Popping ourselves as well would make that two
    /// stack mutations in one update, which is what rendered a blank pushed screen on iOS 18.
    /// Everywhere else this view is presented in a sheet, where dismissing is the sheet's own
    /// business and touches no navigation path.
    var dismissesOnRouteSelection = true
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State var viewModel: StationDetailViewModel?
    @State var selectedStationImage: FullScreenStationImage?
    @State var showQuickTagDialog = false
    @State var selectedOfficialInformationCategory: OfficialStationInformationCategory = .firstLast
    @State var selectedTab: StationDetailTab = .trains

    /// Tall, because the map is the whole point of the Map tab — but fixed. This shows one
    /// station's doors; there is nothing further to reveal by making it taller, and a resize
    /// handle on a card inside a scroll view is a gesture competing with the scroll for no gain.
    static let entranceMapHeight: Double = 380

    /// Only tabs with something behind them are offered — an empty tab is worse than no tab. The
    /// station tab is always present: lines and the data-confidence chips do not depend on a pack.
    var availableTabs: [StationDetailTab] {
        StationDetailTab.allCases.filter { tab in
            switch tab {
            case .trains: return hasOfficialStationInformationContent || showsBundledStationSections
            case .map: return hasStationGuideContent
            case .station: return true
            }
        }
    }

    /// The tab to render: the picked one while it still has content, otherwise the first that does.
    /// Content arrives asynchronously, so the selection has to survive a tab appearing or vanishing
    /// under it — the entrance map in particular only exists once the city pack has loaded.
    var effectiveTab: StationDetailTab {
        let tabs = availableTabs
        return tabs.contains(selectedTab) ? selectedTab : (tabs.first ?? .station)
    }

    private var currentQuickTag: StationQuickTag? {
        tripMemoryService.quickTag(stationID: displayedStation.stationID, cityID: displayedStation.cityID)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Identity and the one action worth taking from here stay above the tabs: they are
                // what every visit needs, whichever question brought the rider.
                stationHeader
                planRouteSection

                let tabs = availableTabs
                if tabs.count > 1 {
                    Picker(
                        AppLocalization.text(
                            english: "Station section",
                            simplified: "车站栏目",
                            traditional: "車站欄目"
                        ),
                        selection: $selectedTab
                    ) {
                        ForEach(tabs) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch effectiveTab {
                case .trains:
                    officialStationInformationSection
                    if showsBundledStationSections {
                        arrivalsSection
                    }
                case .map:
                    // Entrance geometry answers a different question from the operator's exit text
                    // — the operator says which streets an exit reaches, the bundled OSM entrances
                    // say where it physically is — so this sits outside the bundled-sections gate.
                    stationGuideSection
                case .station:
                    linesSection
                    if showsBundledStationSections {
                        accessibilitySection
                        stationEssentialsSection
                    }
                    stationMapSection
                    beforeYouGoSection
                }
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
                        title: AppLocalization.localized("Accessibility"),
                        confidence: viewModel?.accessibilityConfidence ?? .unknown,
                        icon: "accessibility"
                    )
                    if viewModel?.showsLiveArrivalConfidence == true {
                        confidenceChip(
                            title: AppLocalization.localized("Live arrivals"),
                            confidence: viewModel?.liveArrivalConfidence ?? .unknown,
                            icon: "wave.3.right"
                        )
                    }
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
                // At accessibility text sizes a name and two chips cannot share one row: the
                // chips get squeezed into single-character columns and the station name breaks
                // mid-syllable. Stack them instead once the type is that large.
                if dynamicTypeSize.isAccessibilitySize {
                    // One chip per row, not two side by side: at this type size a pair still
                    // squeezes the wider label into a four-line stack inside its own capsule.
                    VStack(alignment: .leading, spacing: 8) {
                        headerNames(station)
                        headerChips(station)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        headerNames(station)
                        Spacer()
                        headerChips(station)
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

    @ViewBuilder
    private func headerNames(_ station: Station) -> some View {
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
    }

    @ViewBuilder
    private func headerChips(_ station: Station) -> some View {
        // Service status sits before the transfer chip: whether the station takes passengers at
        // all outranks how you change trains there.
        if let serviceStatus = stationServiceStatusLabel {
            Label(serviceStatus.text, systemImage: serviceStatus.icon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.18), in: Capsule())
                .foregroundStyle(.secondary)
        }

        if station.isTransferStation {
            Label(AppLocalization.localized("Transfer"), systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    /// A station the network draws but riders cannot yet use. The reviewed operator state already
    /// existed — it was only spelled out in prose far down the official-information section, so a
    /// rider planning a trip to 福寿岭 had no way to see it was still a building site. The wording
    /// lives on the status itself, so this header and the route planner's warning can never
    /// disagree about what the same reviewed fact means.
    private var stationServiceStatusLabel: (text: String, icon: String)? {
        viewModel?.officialResourceReview?.stationInformationStatus?.serviceStatusLabel
    }

    private var planRouteSection: some View {
        let station = displayedStation
        let place = TransitPlace(
            name: station.localizedName,
            coordinate: station.coordinate,
            source: .mapKit
        )
        return PlanRouteButtons(place: place, onSelected: {
            if dismissesOnRouteSelection { dismiss() }
        })
    }

    /// Renders nothing when the station carries no resolved lines, rather than a headed card with
    /// an empty grid under it — a card that says only "Lines" costs a screenful of scrolling and
    /// tells a rider nothing.
    @ViewBuilder
    private var linesSection: some View {
        let station = displayedStation
        if !station.uniqueLogicalLines.isEmpty {
            GlassCard {
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
}


/// The one route button shown on a station or place card. It records the place as the trip's
/// *destination* and calls `onSelected` so the presenting card can dismiss itself; the map's
/// navigation stack watches for that record and pushes the entry page.
///
/// This was a pair — "From here" and "To here" — which asked the rider to answer a question they
/// had not been asked yet. Standing in front of a place on a map, "route here" is what you mean
/// essentially always; the entry page then opens with this end filled and the other end defaulted
/// to where you are, and swapping them is one button away if that guess was wrong.
///
/// Colors use `Color.adaptive(hex: selectedThemeHex)` directly rather than the semantic
/// `Color.accentColor`: the latter resolves from the environment `.tint`, which hasn't propagated
/// on a freshly-presented sheet's first frame and momentarily flashes system blue. The adaptive
/// color is a concrete dynamic color with no environment dependency, so it never flashes and still
/// matches the app accent (and lifts for legibility in dark mode).
struct PlanRouteButtons: View {
    let place: TransitPlace
    var onSelected: () -> Void = {}

    @Environment(AppState.self) private var appState
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue

    var body: some View {
        Button {
            appState.pendingRouteInput = AppState.PendingRouteInput(place: place, role: .destination)
            appState.selectedTab = .map
            onSelected()
        } label: {
            Label(
                AppLocalization.text(english: "Route here", simplified: "到这里去", traditional: "到這裡去"),
                systemImage: "arrow.triangle.turn.up.right.circle.fill"
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
