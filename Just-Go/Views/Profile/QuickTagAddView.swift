import SwiftUI
import MapKit
import CoreLocation

/// Search-and-tag without leaving tag management: stations from the selected city's network
/// and arbitrary map places, each saving through the shared quick-tag editor.
struct QuickTagAddView: View {
    @Environment(DIContainer.self) private var container
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var stationResults: [Station] = []
    @State private var placeResults: [TransitPlace] = []
    @State private var onlineSearchTask: Task<Void, Never>?
    @State private var isSearchingOnline = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    // Held separately from the editor's presentation flag: the custom-label alert outlives
    // the kind-picker dialog, so the target must survive the dialog's dismissal.
    @State private var pendingTarget: PendingTarget?
    @State private var showEditor = false

    private enum PendingTarget {
        case station(Station)
        case place(TransitPlace)
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    if !stationResults.isEmpty {
                        Section {
                            ForEach(stationResults, id: \.stationID) { station in
                                resultRow(
                                    title: station.localizedName,
                                    caption: station.lines.map(\.localizedName).joined(separator: " • "),
                                    icon: "tram.fill",
                                    isTagged: tripMemoryService.isQuickTagged(
                                        stationID: station.stationID,
                                        cityID: station.cityID
                                    )
                                ) {
                                    pendingTarget = .station(station)
                                    showEditor = true
                                }
                            }
                        } header: {
                            Text(AppLocalization.text(english: "Stations", simplified: "车站", traditional: "車站"))
                        }
                    }
                    if !placeResults.isEmpty {
                        Section {
                            ForEach(placeResults) { place in
                                resultRow(
                                    title: place.name,
                                    caption: place.address ?? "",
                                    icon: "mappin.circle.fill",
                                    isTagged: tripMemoryService.quickTag(place: place) != nil
                                ) {
                                    pendingTarget = .place(place)
                                    showEditor = true
                                }
                            }
                        } header: {
                            Text(AppLocalization.text(english: "Places", simplified: "地点", traditional: "地點"))
                        }
                    }
                    if canSearchOnline {
                        searchOnlineRow
                    }
                    if stationResults.isEmpty && placeResults.isEmpty && !canSearchOnline {
                        Section {
                            Text(emptyStateText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.text(english: "Add Tag", simplified: "添加标签", traditional: "新增標籤"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: AppLocalization.text(
                    english: "Station or place name",
                    simplified: "车站或地点名称",
                    traditional: "車站或地點名稱"
                )
            )
            .onChange(of: searchText) { _, keyword in
                runSearch(keyword: keyword)
            }
            .onSubmit(of: .search) { searchOnline() }
            .quickTagEditor(
                isPresented: $showEditor,
                title: pendingTargetTitle,
                currentQuickTag: pendingCurrentQuickTag,
                onSave: { kind in savePendingTarget(kind: kind) },
                onDelete: {
                    if let existing = pendingCurrentQuickTag {
                        tripMemoryService.deleteQuickTag(id: existing.id)
                    }
                }
            )
        }
        .onDisappear {
            searchTask?.cancel()
            onlineSearchTask?.cancel()
        }
    }

    private var emptyStateText: String {
        if isSearching {
            return AppLocalization.text(english: "Searching…", simplified: "搜索中…", traditional: "搜尋中…")
        }
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppLocalization.text(
                english: "Search for a station or a place to tag it.",
                simplified: "搜索车站或地点即可添加标签。",
                traditional: "搜尋車站或地點即可新增標籤。"
            )
        }
        return AppLocalization.text(english: "No results", simplified: "没有结果", traditional: "沒有結果")
    }

    private func resultRow(
        title: String,
        caption: String,
        icon: String,
        isTagged: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: isTagged ? "tag.fill" : "tag")
                    .foregroundStyle(isTagged ? Color.accentColor : Color.secondary)
            }
        }
    }

    /// Typing answers from the bundled network and nothing else.
    ///
    /// This fired two place searches on every 300 ms pause — one through `searchStations`, which
    /// omitted `includingPlaces:` and so took its `true` default, and a second through
    /// `searchMapPlaces` with a different `limit`, which is a different URL and so not even
    /// coalesced. A six-character query could cost twelve of the day's hundred. The search page
    /// was moved off this pattern when the budget work was done; this screen was missed, and it is
    /// the one a rider uses while browsing rather than while going somewhere.
    ///
    /// The bundled index holds every station in every supported city, which is what someone
    /// tagging a place is usually reaching for. Everything else is one tap away below.
    /// Two characters, matching the search page. A single character is almost never a place name
    /// and is the query most likely to be a rider still typing.
    private var canSearchOnline: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// A capability that only responds to the return key is one most riders never find, so it gets
    /// a row. The wording names what it does rather than what it costs: the daily allowance is our
    /// problem, not the rider's.
    private var searchOnlineRow: some View {
        Section {
            Button {
                searchOnline()
            } label: {
                HStack(spacing: 10) {
                    if isSearchingOnline {
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
            .disabled(isSearchingOnline)
        } footer: {
            Text(AppLocalization.text(
                english: "Stations above come from the offline network and are already complete.",
                simplified: "以上车站来自离线线网，已经完整。",
                traditional: "以上車站來自離線線網，已經完整。"
            ))
        }
    }

    private func runSearch(keyword: String) {
        searchTask?.cancel()
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // Results for a query the rider has since edited are worse than none.
        placeResults = []
        guard !trimmed.isEmpty else {
            stationResults = []
            isSearching = false
            return
        }
        isSearching = true
        // Biased to the rider rather than to a selected city. A quick tag is almost always
        // somewhere they have been, and there is no selected city to fall back to.
        let here = container.locationService.mapSpaceLocation?.coordinate
        searchTask = Task {
            let stations = await searchStations(keyword: trimmed, near: here)
            guard !Task.isCancelled,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            stationResults = stations
            isSearching = false
        }
    }

    /// The place search that used to run on every keystroke, made deliberate and visible.
    private func searchOnline() {
        onlineSearchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        isSearchingOnline = true
        let here = container.locationService.mapSpaceLocation?.coordinate
        onlineSearchTask = Task {
            let places = await searchMapPlaces(keyword: trimmed, near: here)
            // MKLocalSearch ignores task cancellation, so guard on the live query text
            // instead of trusting Task.isCancelled alone.
            guard !Task.isCancelled,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            placeResults = places
            isSearchingOnline = false
        }
    }

    private func searchStations(keyword: String, near coordinate: CLLocationCoordinate2D?) async -> [Station] {
        let matches = (try? await container.stationSearchService.search(
            keyword: keyword,
            near: coordinate,
            includingPlaces: false
        )) ?? []
        return await container.stationSearchService.enrichStations(Array(matches.prefix(6)))
    }

    private func searchMapPlaces(keyword: String, near coordinate: CLLocationCoordinate2D?) async -> [TransitPlace] {
        let region = coordinate.map {
            MKCoordinateRegion(center: $0, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        let places = (try? await container.placeSearchProvider.searchPlaces(
            keyword: keyword,
            region: region,
            limit: 8
        )) ?? []
        return places
    }

    private var pendingTargetTitle: String {
        switch pendingTarget {
        case .station(let station):
            return station.localizedName
        case .place(let place):
            return place.name
        case nil:
            return ""
        }
    }

    private var pendingCurrentQuickTag: StationQuickTag? {
        switch pendingTarget {
        case .station(let station):
            return tripMemoryService.quickTag(stationID: station.stationID, cityID: station.cityID)
        case .place(let place):
            return tripMemoryService.quickTag(place: place)
        case nil:
            return nil
        }
    }

    private func savePendingTarget(kind: StationQuickTagKind) {
        switch pendingTarget {
        case .station(let station):
            let city = container.cityService.getCity(byID: station.cityID)
            tripMemoryService.setQuickTag(
                station: station,
                cityName: city?.name ?? station.cityID,
                cityNameEn: city?.nameEn,
                kind: kind
            )
        case .place(let place):
            let location = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
            guard let city = container.cityService.findNearestCity(to: location) else { return }
            tripMemoryService.setQuickTag(
                place: place,
                cityID: city.id,
                cityName: city.name,
                cityNameEn: city.nameEn,
                kind: kind
            )
        case nil:
            break
        }
    }
}
