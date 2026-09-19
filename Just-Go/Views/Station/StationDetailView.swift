import SwiftUI

/// The station sheet's sections, grouped by the question a rider arrived with. Only tabs with
/// something to show are offered.
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
    /// False only on the map's own navigation stack, where "Route here" replaces this screen with
    /// the results in one write to the path. Popping as well would make two stack mutations in one
    /// update, which renders a blank pushed screen. In a sheet, dismissing touches no path.
    var dismissesOnRouteSelection = true
    /// How to open one of this station's lines, supplied by the host: this view lives on three
    /// navigation stacks, and registering a destination on each shadows presentations. A host that
    /// cannot show a line passes nothing, and the rows stay plain labels.
    var onSelectLine: ((SubwayLine) -> Void)?
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State var viewModel: StationDetailViewModel?
    @State var showQuickTagDialog = false
    @State var selectedOfficialInformationCategory: OfficialStationInformationCategory = .firstLast
    @State var selectedTab: StationDetailTab = .trains

    /// Tall, because the map is the Map tab's point, but fixed: one station's doors need no more,
    /// and a resize handle inside a scroll view competes with the scroll.
    static let entranceMapHeight: Double = 380

    /// Only tabs with something behind them. The station tab is always present: lines and the
    /// data-confidence chips need no pack.
    var availableTabs: [StationDetailTab] {
        StationDetailTab.allCases.filter { tab in
            switch tab {
            case .trains: return hasOfficialStationInformationContent || showsBundledStationSections
            case .map: return hasStationGuideContent
            case .station: return true
            }
        }
    }

    /// The tab to render: the picked one while it has content, else the first that does. Content
    /// arrives asynchronously, so the selection must survive a tab appearing or vanishing.
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
                // Identity and the one action worth taking stay above the tabs: every visit needs
                // them.
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
                    // (where a door physically is, not which streets it reaches), so it sits
                    // outside the bundled-sections gate.
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
                    Label(
                        AppLocalization.localized(currentQuickTag == nil ? "Add Quick Tag" : "Edit Quick Tag"),
                        systemImage: currentQuickTag == nil ? "tag" : "tag.fill"
                    )
                    .foregroundStyle(currentQuickTag == nil ? .primary : Color.accentColor)
                }
            }
        }
        .task {
            // Only once: `.task` runs again when this page reappears, and rebuilding would discard
            // what loaded and fetch the same station again.
            guard viewModel == nil else { return }
            viewModel = container.makeStationDetailViewModel()
            viewModel?.loadStation(station)
            await viewModel?.loadCityPack()
            await viewModel?.loadRiderInformation()
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

    /// Whether this station's information ships in its city pack (a `bundledDataset` source): it is
    /// then always native and loads with the pack. Asked of the directory, never the city ID.
    var servesBundledStationInformation: Bool {
        container.stationInformationDirectory.servesBundledInformation(forStationID: displayedStation.id)
    }

    /// Whether the train section shows live trains rather than first and last times.
    var servesLiveTrains: Bool {
        container.stationInformationDirectory.servesLiveArrivals(forStationID: displayedStation.id)
    }

    var usesNativeStationInformationSurface: Bool {
        // A station is native when the bundled Station Information directory has a source for it;
        // the directory is synchronous, so asking it directly before the view model exists avoids a
        // first-frame flash.
        if servesBundledStationInformation {
            return true
        }
        if let viewModel {
            return viewModel.usesCategorizedStationInformation
        }
        return container.stationInformationDirectory.onlineEntry(forStationID: displayedStation.id) != nil
    }

    /// The bundled sections return whenever the native online surface has nothing to serve (the
    /// fetch failed and nothing is cached), so an offline rider still gets the official data in the
    /// bundle.
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
        .background(confidence.color.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }

    private var stationHeader: some View {
        let station = displayedStation
        return GlassCard {
            VStack(spacing: 12) {
                // At accessibility sizes a name and two chips cannot share a row, so they stack.
                if dynamicTypeSize.isAccessibilitySize {
                    // One chip per row: at this size two side by side squeeze the wider label into
                    // a tall stack.
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
                        // Not "Fully Accessible Station": nothing publishes that, and a lift and a
                        // ramp listed somewhere at a station are not a step-free route from street
                        // to platform. The two facts are shown; the conclusion is not ours to draw.
                        Text(AppLocalization.text(
                            english: "Lift and step-free entrance listed",
                            simplified: "已列出电梯与无障碍入口",
                            traditional: "已列出電梯與無障礙入口"
                        ))
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
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
            if let subtitle = station.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func headerChips(_ station: Station) -> some View {
        // Whether the station takes passengers outranks how you change trains there.
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

    /// A station the network draws but riders cannot use (福寿岭 is still a building site). The
    /// wording lives on the status, so this header and the planner's warning cannot disagree.
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

    /// Nothing when the station has no resolved lines, rather than a headed card with an empty
    /// grid.
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
                            if let onSelectLine {
                                Button { onSelectLine(line) } label: { lineChip(line, opensLine: true) }
                                    .buttonStyle(.plain)
                            } else {
                                lineChip(line, opensLine: false)
                            }
                        }
                    }
                }
            }
        }
    }

    /// One line row. The chevron appears only when tapping it goes somewhere, so the affordance
    /// never promises a screen the host has not provided.
    private func lineChip(_ line: SubwayLine, opensLine: Bool) -> some View {
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
            if opensLine {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minHeight: Metrics.minimumTapTarget)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .contentShape(Rectangle())
    }
}


/// The route button on a station or place card: records the place as the trip's destination and
/// calls `onSelected` so the card can dismiss; the map's stack pushes the results, with the start
/// defaulted to where the rider is.
///
/// Colours come from `Color.adaptive(hex:)` rather than `Color.accentColor`, which reads the
/// environment `.tint` and flashes system blue on a new sheet's first frame.
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
            // Raw hex, not `themeColor`: a solid fill under white text, which `Color.adaptive`
            // would lighten in dark mode.
            .background(Color(hex: selectedThemeHex), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
