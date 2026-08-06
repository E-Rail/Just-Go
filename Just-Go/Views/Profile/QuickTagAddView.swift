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
                    if stationResults.isEmpty && placeResults.isEmpty {
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

    private func runSearch(keyword: String) {
        searchTask?.cancel()
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stationResults = []
            placeResults = []
            isSearching = false
            return
        }
        isSearching = true
        // Both halves are biased to the rider rather than to a selected city — a quick tag is
        // almost always somewhere they have been, and there is no selected city to fall back to.
        let here = container.locationService.mapSpaceLocation?.coordinate
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            async let stationsFound = searchStations(keyword: trimmed, near: here)
            async let placesFound = searchMapPlaces(keyword: trimmed, near: here)
            let (stations, places) = await (stationsFound, placesFound)
            // MKLocalSearch ignores task cancellation, so guard on the live query text
            // instead of trusting Task.isCancelled alone.
            guard !Task.isCancelled,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            stationResults = stations
            placeResults = places
            isSearching = false
        }
    }

    private func searchStations(keyword: String, near coordinate: CLLocationCoordinate2D?) async -> [Station] {
        let matches = (try? await container.stationSearchService.search(keyword: keyword, near: coordinate)) ?? []
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
