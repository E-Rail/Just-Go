import SwiftUI

struct StationDetailView: View {
    let station: Station
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State var viewModel: StationDetailViewModel?
    @State var selectedStationImage: FullScreenStationImage?
    @State var showQuickTagDialog = false
    @State var showCustomQuickTagAlert = false
    @State var customQuickTagText = ""
    @State var pendingQuickTagKind: StationQuickTagKind?
    @State var showQuickTagReplacementDialog = false
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
                serviceStatusSection
                stationMapSection
                if let stationKey = PersonalStationMediaKey(
                    cityID: displayedStation.cityID,
                    stationID: displayedStation.stationID
                ) {
                    PersonalStationMediaSection(
                        stationKey: stationKey,
                        stationName: displayedStation.localizedName
                    ) { image in
                        selectedStationImage = image
                    }
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
            showCustom: $showCustomQuickTagAlert,
            customText: $customQuickTagText,
            pendingKind: $pendingQuickTagKind,
            showReplacement: $showQuickTagReplacementDialog,
            station: displayedStation,
            currentQuickTag: currentQuickTag,
            container: container,
            tripMemoryService: tripMemoryService
        )
    }

    var displayedStation: Station {
        viewModel?.station ?? station
    }

    var usesNativeStationInformationSurface: Bool {
        if displayedStation.cityID == "8100" {
            return true
        }
        guard displayedStation.cityID == "1100" else { return false }
        if viewModel == nil || viewModel?.isLoadingCityPack == true {
            return true
        }
        return viewModel?.usesCategorizedStationInformation == true
    }

    /// The bundled sections (schedules, accessibility, essentials, guide) return whenever
    /// the native online surface has nothing to serve — the fetch failed and no snapshot is
    /// cached — so a blocked or offline network still gets the offline official data instead
    /// of only an error card.
    var showsBundledStationSections: Bool {
        guard usesNativeStationInformationSurface else { return true }
        return displayedStation.cityID == "1100" &&
            viewModel?.officialStationInformation == nil &&
            viewModel?.officialStationInformationError != nil
    }

    private var beforeYouGoSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(AppLocalization.localized("Before You Go"))
                        .font(.headline)
                    Spacer()
                    Text(AppLocalization.localized("Best data available"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

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

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if displayedStation.isTransferStation {
                            stationFactChip(AppLocalization.localized("Transfer station"), icon: "arrow.triangle.2.circlepath", tint: .orange)
                        }
                        if !displayedStation.facilities.isEmpty {
                            stationFactChip(AppLocalization.localized("Station essentials available"), icon: "info.circle.fill", tint: .blue)
                        }
                        if viewModel?.arrivals.isEmpty == false {
                            stationFactChip(
                                AppLocalization.text(
                                    english: "Train information available",
                                    simplified: "列车信息可用",
                                    traditional: "列車資訊可用"
                                ),
                                icon: "clock.fill",
                                tint: .green
                            )
                        }
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
        .background(confidence.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stationFactChip(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
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
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

private extension View {
    func quickTagEditor(
        isPresented: Binding<Bool>,
        showCustom: Binding<Bool>,
        customText: Binding<String>,
        pendingKind: Binding<StationQuickTagKind?>,
        showReplacement: Binding<Bool>,
        station: Station,
        currentQuickTag: StationQuickTag?,
        container: DIContainer,
        tripMemoryService: TripMemoryService
    ) -> some View {
        confirmationDialog(
            station.localizedName,
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(StationQuickTagKind.home.title) {
                attemptQuickTagSave(
                    .home,
                    station: station,
                    container: container,
                    tripMemoryService: tripMemoryService,
                    pendingKind: pendingKind,
                    showReplacement: showReplacement
                )
            }
            Button(StationQuickTagKind.work.title) {
                attemptQuickTagSave(
                    .work,
                    station: station,
                    container: container,
                    tripMemoryService: tripMemoryService,
                    pendingKind: pendingKind,
                    showReplacement: showReplacement
                )
            }
            Button(AppLocalization.text(english: "Custom…", simplified: "自定义…", traditional: "自訂…")) {
                customText.wrappedValue = currentQuickTag?.kind.customLabel ?? ""
                showCustom.wrappedValue = true
            }
            if let currentQuickTag {
                Button(AppLocalization.localized("Delete Quick Tag"), role: .destructive) {
                    tripMemoryService.deleteQuickTag(id: currentQuickTag.id)
                }
            }
        } message: {
            Text(AppLocalization.localized("Quick Tags appear as one-tap chips in Route Planner."))
        }
        .alert(
            AppLocalization.text(english: "Custom Tag", simplified: "自定义标签", traditional: "自訂標籤"),
            isPresented: showCustom
        ) {
            TextField(
                AppLocalization.text(english: "Tag name", simplified: "标签名称", traditional: "標籤名稱"),
                text: customText
            )
            Button(AppLocalization.localized("Save")) {
                let label = customText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return }
                attemptQuickTagSave(
                    .custom(label),
                    station: station,
                    container: container,
                    tripMemoryService: tripMemoryService,
                    pendingKind: pendingKind,
                    showReplacement: showReplacement
                )
            }
            Button(AppLocalization.localized("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            AppLocalization.text(
                english: "Replace a Quick Tag?",
                simplified: "替换一个快捷标签？",
                traditional: "取代一個快捷標籤？"
            ),
            isPresented: showReplacement,
            titleVisibility: .visible,
            presenting: pendingKind.wrappedValue
        ) { kind in
            ForEach(tripMemoryService.stationQuickTags) { quickTag in
                Button("\(quickTag.kind.title) · \(quickTag.displayName)") {
                    attemptQuickTagSave(
                        kind,
                        station: station,
                        container: container,
                        tripMemoryService: tripMemoryService,
                        pendingKind: pendingKind,
                        showReplacement: showReplacement,
                        replacing: quickTag.id
                    )
                }
            }
            Button(AppLocalization.localized("Cancel"), role: .cancel) {
                pendingKind.wrappedValue = nil
            }
        } message: { _ in
            Text(AppLocalization.text(
                english: "You can keep up to three Quick Tags. Choose one to replace.",
                simplified: "最多可保留三个快捷标签。请选择要替换的标签。",
                traditional: "最多可保留三個快捷標籤。請選擇要取代的標籤。"
            ))
        }
    }

    func attemptQuickTagSave(
        _ kind: StationQuickTagKind,
        station: Station,
        container: DIContainer,
        tripMemoryService: TripMemoryService,
        pendingKind: Binding<StationQuickTagKind?>,
        showReplacement: Binding<Bool>,
        replacing replacementID: String? = nil
    ) {
        let city = container.cityService.getCity(byID: station.cityID)
        let result = tripMemoryService.setQuickTag(
            station: station,
            cityName: city?.name ?? station.cityID,
            cityNameEn: city?.nameEn,
            kind: kind,
            replacing: replacementID
        )
        switch result {
        case .saved:
            pendingKind.wrappedValue = nil
            showReplacement.wrappedValue = false
        case .replacementRequired:
            pendingKind.wrappedValue = kind
            Task { @MainActor in
                await Task.yield()
                showReplacement.wrappedValue = true
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
