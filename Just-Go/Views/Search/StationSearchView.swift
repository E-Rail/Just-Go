import SwiftUI
import MapKit

/// The map's search page: one field over the local station index and Apple's places. Stations come
/// first and instantly; places come on request. Choosing either hands back to the map, which owns
/// navigation: a station pushes its page, a place opens the same card a tapped pin does.
struct SearchPageView: View {
    let onSelectStation: (Station) -> Void
    let onSelectPlace: (TransitPlace) -> Void
    /// Opening a line, supplied by the host because this page is presented by more than one
    /// navigation stack. Without it the section is hidden.
    var onSelectLine: ((StationSearchService.LineResult) -> Void)?
    /// Replaying a whole journey, supplied by the host: planning is the map stack's job. The
    /// endpoint editor passes nothing.
    var onSelectRecentTrip: ((TripRecord) -> Void)?
    /// True when this page exists to return one answer (endpoint editing): station rows then close
    /// the page, as place rows do.
    var dismissesOnSelection = false

    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: StationSearchViewModel?
    // Tracked so a newer selection supersedes an older replay still loading its city.
    @State private var recentReplayTask: Task<Void, Never>?
    @State private var placeResults: [TransitPlace] = []
    @State private var lineResults: [StationSearchService.LineResult] = []
    @State private var lineSearchTask: Task<Void, Never>?
    @State private var placeSearchTask: Task<Void, Never>?
    @State private var isSearchingPlaces = false
    @State private var currentPlaceTask: Task<Void, Never>?
    @State private var isResolvingCurrentPlace = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
            VStack(spacing: 0) {
                searchBar
                // Shown whether or not tags are saved: the current-location chip is the only way in
                // the app to say "here".
                if isIdle {
                    quickTagBar
                }
                stationFilterBar
                resultsList
            }
            .navigationTitle(AppLocalization.localized("Search"))
            // The back button is in the search bar, beside the field, so the field sits where the
            // thumb is.
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.appBackground)
        .onDisappear {
            recentReplayTask?.cancel()
            placeSearchTask?.cancel()
            currentPlaceTask?.cancel()
        }
        .task {
            if viewModel == nil {
                viewModel = container.makeStationSearchViewModel()
            }
            // Focused on arrival: the rider tapped a search field to get here.
            isSearchFocused = true
            await viewModel?.loadInitialStations()
            #if DEBUG
            // A seeded query: this environment can push a screen but cannot type.
            if let seed = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SEARCH"] {
                viewModel?.searchText = seed
                // Exactly what typing does: the station index and the line match, both local.
                viewModel?.scheduleSearch()
                scheduleLineSearch(seed)
                // The online half is a separate seed because it is a separate act that spends a
                // place search.
                if ProcessInfo.processInfo.environment["JUST_GO_DEBUG_SEARCH_ONLINE"] != nil {
                    searchOnline()
                }
            }
            // Filter chips are taps, and taps cannot be injected here. Same handler the chip uses.
            switch ProcessInfo.processInfo.environment["JUST_GO_DEBUG_FILTER"] {
            case "stepFree": viewModel?.updateFilter { $0.accessibleOnly = true }
            case "lift": viewModel?.updateFilter { $0.elevatorOnly = true }
            case "interchange": viewModel?.updateFilter { $0.transferOnly = true }
            default: break
            }
            #endif
        }
        // The map's GCJ-02 correction can land while this page is open, moving the rider ~540 m;
        // re-order against it.
        .onChange(of: container.locationService.mapSpaceLocation?.coordinate.latitude) { _, _ in
            viewModel?.riderPositionChanged()
        }
    }

    /// Lines are matched in memory against the station list the app holds, with a short debounce so
    /// a fast typist does not rebuild the match on every keystroke.
    private func scheduleLineSearch(_ query: String) {
        lineSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lineResults = []
            return
        }
        lineSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let results = await container.stationSearchService.searchLines(
                keyword: trimmed,
                near: viewModel?.riderCoordinate
            )
            guard !Task.isCancelled else { return }
            lineResults = Array(results.prefix(6))
        }
    }

    private func schedulePlaceSearch(_ query: String) {
        placeSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            placeResults = []
            isSearchingPlaces = false
            return
        }
        isSearchingPlaces = true
        placeSearchTask = Task {
            // Runs when the rider asks, once, through the search service, which shares one lookup
            // with the station half. Biased to the rider, the same position the station list is
            // ranked by.
            let found = try? await container.stationSearchService.searchPlaces(
                keyword: trimmed,
                near: container.locationService.mapSpaceLocation?.coordinate
            )
            guard !Task.isCancelled else { return }
            isSearchingPlaces = false
            placeResults = found ?? []
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                isSearchFocused = false
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .tappable()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.text(english: "Back", simplified: "返回", traditional: "返回"))

            searchField
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Step-free, lift, interchange: shown only when there are stations to narrow. The spinner
    /// matters: the first step-free or lift filter fetches official accessibility data for the
    /// whole list.
    @ViewBuilder
    private var stationFilterBar: some View {
        if let viewModel, !viewModel.searchResults.isEmpty || viewModel.filter.isActive {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(
                        title: AppLocalization.text(english: "Step-free", simplified: "无障碍", traditional: "無障礙"),
                        icon: "figure.roll",
                        isOn: viewModel.filter.accessibleOnly
                    ) { $0.accessibleOnly.toggle() }

                    filterChip(
                        title: AppLocalization.text(english: "Lift", simplified: "有电梯", traditional: "有電梯"),
                        icon: "arrow.up.arrow.down.square",
                        isOn: viewModel.filter.elevatorOnly
                    ) { $0.elevatorOnly.toggle() }

                    filterChip(
                        title: AppLocalization.text(english: "Interchange", simplified: "换乘站", traditional: "換乘站"),
                        icon: "arrow.triangle.swap",
                        isOn: viewModel.filter.transferOnly
                    ) { $0.transferOnly.toggle() }

                    if viewModel.isEnrichingForFacility {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private func filterChip(
        title: String,
        icon: String,
        isOn: Bool,
        toggle: @escaping (inout StationFilter) -> Void
    ) -> some View {
        Chip(title: title, icon: icon, isSelected: isOn) {
            isSearchFocused = false
            viewModel?.updateFilter(toggle)
        }
    }

    private var quickTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                currentLocationChip

                ForEach(quickTags) { quickTag in
                    Button {
                        isSearchFocused = false
                        // The coordinate is the whole answer: a Beijing "Home" plans against
                        // Beijing's network because that is where it is.
                        onSelectPlace(quickTag.transitPlace)
                        dismiss()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: quickTag.kind.icon)
                                .font(.caption)
                            Text(quickTag.kind.title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.appSurface, in: Capsule())
                        .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// "Here", as somewhere a trip can start from: the only control that offers the device's
    /// position, for when the automatic fill does not land (GPS timeout, permission, or a start
    /// dropped as another city's).
    private var currentLocationChip: some View {
        Button {
            isSearchFocused = false
            resolveCurrentPlace()
        } label: {
            HStack(spacing: 5) {
                if isResolvingCurrentPlace {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "location.fill")
                        .font(.caption)
                }
                Text(AppLocalization.text(
                    english: "My Location",
                    simplified: "我的位置",
                    traditional: "我的位置"
                ))
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
            .foregroundStyle(isLocationAvailable ? Color.accentColor : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isLocationAvailable || isResolvingCurrentPlace)
        // Says which problem it is: "off" and "not allowed" have different fixes.
        .accessibilityHint(isLocationAvailable ? "" : currentLocationUnavailableReason)
    }

    private var isLocationAvailable: Bool {
        container.locationService.isAuthorized
    }

    private var currentLocationUnavailableReason: String {
        AppLocalization.text(
            english: "Location access is off for Just-Go",
            simplified: "Just-Go 没有定位权限",
            traditional: "Just-Go 沒有定位權限"
        )
    }

    private func resolveCurrentPlace() {
        currentPlaceTask?.cancel()
        isResolvingCurrentPlace = true
        currentPlaceTask = Task {
            defer { isResolvingCurrentPlace = false }
            let resolver = CurrentPlaceResolver(
                locationService: container.locationService,
                placeSearchProvider: container.placeSearchProvider
            )
            guard let place = try? await resolver.place(), !Task.isCancelled else { return }
            // The same hand-back as a quick tag or a place row: it fills an endpoint when editing
            // one and opens a card when browsing.
            onSelectPlace(place)
            dismiss()
        }
    }

    private var quickTags: [StationQuickTag] {
        tripMemoryService.stationQuickTags
    }

    /// Nothing typed: the page offers what the rider has told it matters.
    private var isIdle: Bool {
        viewModel?.searchText.isEmpty ?? true
    }

    private func lineRow(_ line: StationSearchService.LineResult) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: line.colorHex))
                .frame(width: 6, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.isChinese ? AppLocalization.chinese(line.name) : (line.nameEn ?? line.name))
                    .rowTitle()
                // The city is the point: "18号线" matches five lines in five cities, all "Line 18" in
                // English.
                Text(lineSubtitle(line))
                    .rowMeta()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .contentShape(Rectangle())
    }

    private func lineSubtitle(_ line: StationSearchService.LineResult) -> String {
        let stations = AppLocalization.text(
            english: "\(line.stationCount) stations",
            simplified: "\(line.stationCount) 座车站",
            traditional: "\(line.stationCount) 座車站"
        )
        guard let city = container.cityService.getCity(byID: line.cityID) else { return stations }
        return "\(city.localizedName) · \(stations)"
    }

    private var hasAnyResult: Bool {
        !(viewModel?.searchResults.isEmpty ?? true) || !placeResults.isEmpty || isSearchingPlaces
            || !lineResults.isEmpty
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(AppLocalization.text(
                english: "Search places or stations",
                simplified: "搜索地点或车站",
                traditional: "搜尋地點或車站"
            ), text: Binding(
                get: { viewModel?.searchText ?? "" },
                set: { newValue in
                    viewModel?.searchText = newValue
                    // Both local: the bundled station index and an in-memory line match. Place
                    // search is 100 a day for the whole account and runs only on request.
                    viewModel?.scheduleSearch()
                    scheduleLineSearch(newValue)
                    if placeResults.isEmpty == false || isSearchingPlaces {
                        // Results for a query the rider has since edited are worse than none.
                        placeSearchTask?.cancel()
                        placeResults = []
                        isSearchingPlaces = false
                    }
                }
            ))
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .submitLabel(.search)
            .onSubmit { searchOnline() }

            if !(viewModel?.searchText.isEmpty ?? true) {
                Button {
                    viewModel?.clearSearch()
                    placeSearchTask?.cancel()
                    placeResults = []
                    isSearchingPlaces = false
                    Task {
                        await viewModel?.loadInitialStations()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        // The glyph is ~22 pt; the target has to be 44.
                        .tappable()
                }
                .accessibilityLabel(AppLocalization.text(
                    english: "Clear the search",
                    simplified: "清除搜索内容",
                    traditional: "清除搜尋內容"
                ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    /// Apple's places, under the stations. Choosing one hands back to the map, where its card
    /// belongs.
    private var placesSection: some View {
        Section {
            ForEach(placeResults) { place in
                Button {
                    isSearchFocused = false
                    onSelectPlace(place)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            if let address = place.address, !address.isEmpty {
                                Text(address)
                                    .rowMeta()
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack(spacing: 6) {
                Text(AppLocalization.text(english: "Places", simplified: "地点", traditional: "地點"))
                if isSearchingPlaces {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    private var resultsList: some View {
        List {
            // Above the stations, not instead of them: a past trip is often the shortest way to the
            // next one.
            if isIdle, onSelectRecentTrip != nil, !recentTrips.isEmpty {
                recentTripsSection
                    .listRowBackground(Color.clear)
            }

            if isIdle, viewModel?.recentSearches.isEmpty == false {
                recentSearchesSection
                    .listRowBackground(Color.clear)
            }

            Group {
            // Above the stations: a rider who typed a line name wants the line.
            if onSelectLine != nil, !lineResults.isEmpty {
                Section {
                    ForEach(lineResults) { line in
                        Button {
                            isSearchFocused = false
                            onSelectLine?(line)
                            if dismissesOnSelection { dismiss() }
                        } label: {
                            lineRow(line)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(AppLocalization.text(english: "Lines", simplified: "线路", traditional: "線路"))
                }
            }
            if viewModel?.isSearching ?? false {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            } else if let results = viewModel?.searchResults, !results.isEmpty {
                Section {
                    ForEach(results) { station in
                            StationRow(
                                station: station,
                                distanceText: viewModel?.distanceText(for: station)
                            ) {
                                recentReplayTask?.cancel()
                                viewModel?.selectStation(station)
                                isSearchFocused = false
                                onSelectStation(station)
                                if dismissesOnSelection { dismiss() }
                            }
                    }
                } header: {
                    Text(AppLocalization.text(english: "Stations", simplified: "车站", traditional: "車站"))
                }
            } else if !(viewModel?.searchText.isEmpty ?? true) {
                if let message = viewModel?.errorMessage {
                    ContentUnavailableView {
                        Label(
                            AppLocalization.text(english: "Search Unavailable", simplified: "无法搜索", traditional: "無法搜尋"),
                            systemImage: "wifi.exclamationmark"
                        )
                    } description: {
                        Text(message)
                    }
                } else if !hasAnyResult {
                    // "No results" means the whole page found nothing, not just the station half.
                    ContentUnavailableView {
                        Label(AppLocalization.localized("No Results"), systemImage: "magnifyingglass")
                    } description: {
                        Text(AppLocalization.localized("Try a different search term"))
                    }
                }
            } else if let message = viewModel?.errorMessage {
                ContentUnavailableView {
                    Label(
                        AppLocalization.text(
                            english: "Nothing nearby yet",
                            simplified: "暂无附近车站",
                            traditional: "暫無附近車站"
                        ),
                        systemImage: "location.slash"
                    )
                } description: {
                    Text(message)
                }
            }
            }
            .listRowBackground(Color.clear)

            // Outside the if/else: places are an additional answer to the same query, so a query
            // with no station still has somewhere to go.
            if !placeResults.isEmpty {
                placesSection
                    .listRowBackground(Color.clear)
            } else if canSearchOnline {
                SearchOnlineRow(isSearching: false, action: searchOnline)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Whether asking the place-search provider would tell the rider anything new.
    private var canSearchOnline: Bool {
        guard !isSearchingPlaces, placeResults.isEmpty else { return false }
        return (viewModel?.searchText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// Both halves of the online answer, together and once: they ask the same provider the same
    /// question.
    private func searchOnline() {
        isSearchFocused = false
        viewModel?.submitSearch()
        schedulePlaceSearch(viewModel?.searchText ?? "")
    }

    /// The last three journeys with distinct ends, newest first, from the rider's trip history.
    private var recentTrips: [TripRecord] {
        var seen = Set<String>()
        return Array(tripMemoryService.tripRecords.filter {
            seen.insert($0.originName + "\u{1F}" + $0.destinationName).inserted
        }.prefix(3))
    }

    private var recentTripsSection: some View {
        Section(AppLocalization.text(
            english: "Recent trips",
            simplified: "最近的行程",
            traditional: "最近的行程"
        )) {
            ForEach(recentTrips) { trip in
                Button {
                    isSearchFocused = false
                    onSelectRecentTrip?(trip)
                    if dismissesOnSelection { dismiss() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.turn.up.right.circle")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(trip.originName) → \(trip.destinationName)")
                                .lineLimit(1)
                            Text(AppLocalization.minutes(Int(trip.plannedDuration / 60)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentSearchesSection: some View {
        Section(AppLocalization.localized("Recent Searches")) {
            ForEach(viewModel?.recentSearches ?? []) { search in
                Button {
                    isSearchFocused = false
                    recentReplayTask?.cancel()
                    recentReplayTask = Task {
                        // A recent replays in its own city: same-named stations exist across
                        // cities, so re-resolving by name could open the wrong one. Cancellation
                        // checks after each await keep a superseded replay from overwriting a newer
                        // tap.
                        let station = await viewModel?.station(withID: search.stationID, in: search.cityID)
                        guard !Task.isCancelled else { return }
                        if let station {
                            viewModel?.selectStation(station)
                            onSelectStation(station)
                            if dismissesOnSelection { dismiss() }
                        } else {
                            // Station no longer in the pack: fall back to a name search through the
                            // field's own debounced slot.
                            viewModel?.searchText = search.stationName
                            viewModel?.scheduleSearch()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text(search.stationName)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                viewModel?.deleteRecentSearches(at: offsets)
            }
        }
    }
}

/// "Search online for places", as a row rather than only the return key, which most riders never
/// find. Place search is metered, so it runs when asked and not on every keystroke.
struct SearchOnlineRow: View {
    let isSearching: Bool
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                HStack(spacing: 10) {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(AppLocalization.text(
                        english: "Search online for places",
                        simplified: "在线搜索地点",
                        traditional: "線上搜尋地點"
                    ))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
        } footer: {
            Text(AppLocalization.text(
                english: "Stations above come from the offline network and are already complete.",
                simplified: "以上车站来自离线线网，已经完整。",
                traditional: "以上車站來自離線線網，已經完整。"
            ))
        }
    }
}
