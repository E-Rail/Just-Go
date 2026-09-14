import Foundation
import CoreLocation

/// `@MainActor`: it publishes SwiftUI-observed state and reads `LocationService`, which lives on
/// the main actor.
@MainActor
@Observable
final class StationSearchViewModel {
    var searchText: String = ""
    var searchResults: [Station] = []
    var recentSearches: [SearchHistory] = []
    var isSearching = false
    var errorMessage: String?
    private var unfilteredResults: [Station] = []
    /// Distance from the rider to each listed station, measured once when the list was ordered.
    private var distanceByStationID: [String: CLLocationDistance] = [:]
    private var hasEnrichedUnfilteredResultsForFacilities = false

    var filter = StationFilter()

    var isEnrichingForFacility = false
    @ObservationIgnored nonisolated(unsafe) private var facilityEnrichmentTask: Task<Void, Never>?

    private let stationSearchService: StationSearchService
    private let locationService: LocationService

    /// Where the rider is, in the map's coordinate frame. Exposed so the search page ranks lines by
    /// the same position this ranks stations by.
    var riderCoordinate: CLLocationCoordinate2D? { locationService.mapSpaceLocation?.coordinate }
    private let recentSearchesKey = "recentStationSearches"
    private var hasRequestedSearchLocation = false
    private var stationLoadID = UUID()
    @ObservationIgnored nonisolated(unsafe) private var searchTask: Task<Void, Never>?

    init(
        stationSearchService: StationSearchService,
        locationService: LocationService
    ) {
        self.stationSearchService = stationSearchService
        self.locationService = locationService
        recentSearches = UserDefaults.standard.codableValue(forKey: recentSearchesKey, as: [SearchHistory].self, default: [])
    }

    // `nonisolated` on the two task handles above is what lets this run, exactly as in
    // `MapViewModel`: `deinit` cannot touch main-actor state, and `cancel()` is thread-safe.
    deinit {
        searchTask?.cancel()
        facilityEnrichmentTask?.cancel()
    }

    /// The no-query list: the stations closest to the rider, wherever they are.
    func loadInitialStations() async {
        let loadID = UUID()
        stationLoadID = loadID
        // A new token supersedes any in-flight keyword search and facility enrichment, whose
        // stale-token guards then refuse to publish, so this owns clearing both flags.
        isSearching = false
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Keyword results stay listed; the entry cancel above killed any in-flight
            // enrichment, so restart it under the fresh token if filters still need it.
            enrichForActiveFacilityFiltersIfNeeded()
            return
        }
        await refreshLocationIfAlreadyAllowed()
        guard stationLoadID == loadID else { return }
        guard let here = locationService.mapSpaceLocation?.coordinate else {
            unfilteredResults = []
            hasEnrichedUnfilteredResultsForFacilities = false
            searchResults = []
            // Without a position "nearby" means nothing, and typing a name still works; say which
            // is missing rather than show some city's stations.
            errorMessage = AppLocalization.text(
                english: "Turn on location to see stations near you, or search by name.",
                simplified: "开启定位以查看附近车站，或直接搜索名称。",
                traditional: "開啟定位以查看附近車站，或直接搜尋名稱。"
            )
            return
        }
        errorMessage = nil
        let stations = await stationSearchService.nearestStations(
            to: here,
            limit: stationSearchService.nearbyStationLimit
        )
        guard stationLoadID == loadID else { return }
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        unfilteredResults = stations
        hasEnrichedUnfilteredResultsForFacilities = false
        applyFilters()
        let enrichedStations = await stationSearchService.enrichStations(unfilteredResults)
        guard stationLoadID == loadID else { return }
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        unfilteredResults = enrichedStations
        hasEnrichedUnfilteredResultsForFacilities = true
        applyFilters()
    }

    func search(includingPlaces: Bool = true) async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            await loadInitialStations()
            return
        }

        // Generation token, so a superseded query, or one returning after the field was cleared,
        // cannot overwrite current results. `MKLocalSearch` ignores task cancellation, so the call
        // still completes and the token discards it. A stale search can return inside the next
        // search's 180 ms debounce, before a new token exists, hence the captured-query check too.
        let loadID = UUID()
        stationLoadID = loadID
        // The new token supersedes in-flight facility enrichment, so this owns clearing its flag.
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        isSearching = true
        // Clears the spinner on every exit, the stale-token returns included.
        defer {
            if stationLoadID == loadID {
                isSearching = false
            }
        }
        errorMessage = nil
        await refreshLocationIfAlreadyAllowed()

        do {
            let results = try await stationSearchService.search(
                keyword: query,
                near: locationService.mapSpaceLocation?.coordinate,
                includingPlaces: includingPlaces
            )
            guard stationLoadID == loadID,
                  searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            replaceUnfilteredResults(results, loadID: loadID)
        } catch {
            guard stationLoadID == loadID,
                  searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            errorMessage = AppLocalization.localized("Place search requires a network connection")
        }
    }

    /// Typing: answered from the bundled station index only, so it costs nothing. Place search runs
    /// on an explicit submit; see `StationSearchService.search(keyword:near:includingPlaces:)`.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.search(includingPlaces: false)
        }
    }

    /// The rider asked. This is the one that spends a place search.
    func submitSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.search(includingPlaces: true)
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        isSearching = false
        // Invalidate any in-flight search so a late network result can't repopulate the list.
        stationLoadID = UUID()
        searchText = ""
        unfilteredResults = []
        hasEnrichedUnfilteredResultsForFacilities = false
        searchResults = []
        errorMessage = nil
    }

    func distanceText(for station: Station) -> String? {
        // The distance this row was ordered by, not a fresh measurement. See `applyFilters`.
        guard let meters = distanceByStationID[station.stationID] else { return nil }
        return AppLocalization.text(
            english: "\(AppLocalization.distance(meters)) from here",
            simplified: "距当前位置 \(AppLocalization.distance(meters))",
            traditional: "距目前位置 \(AppLocalization.distance(meters))"
        )
    }

    /// The exact stored station for a recent-search row. Replay must not re-resolve by
    /// name, since same-named stations exist across cities.
    func station(withID stationID: String, in city: String) async -> Station? {
        guard !city.isEmpty else { return nil }
        return await stationSearchService.stations(in: city).first { $0.stationID == stationID }
    }

    func selectStation(_ station: Station) {
        var recent = recentSearches.filter { $0.stationID != station.stationID }
        recent.insert(SearchHistory(
            stationID: station.stationID,
            stationName: station.localizedName,
            cityID: station.cityID
        ), at: 0)
        recentSearches = Array(recent.prefix(10))
        UserDefaults.standard.setCodable(recentSearches, forKey: recentSearchesKey)
    }

    func deleteRecentSearches(at offsets: IndexSet) {
        recentSearches.remove(atOffsets: offsets)
        UserDefaults.standard.setCodable(recentSearches, forKey: recentSearchesKey)
    }

    /// The only way a view should change the filter. Filtering is applied when results are
    /// replaced, and the fields the filters read are loaded only once a filter needs them, so both
    /// follow the change, in this order.
    func updateFilter(_ transform: (inout StationFilter) -> Void) {
        transform(&filter)
        applyFilters()
        enrichForActiveFacilityFiltersIfNeeded()
    }

    func riderPositionChanged() {
        guard !unfilteredResults.isEmpty else { return }
        applyFilters()
    }

    private func applyFilters() {
        let filtered = stationSearchService.filterStations(unfilteredResults, by: filter)
        guard let origin = locationService.mapSpaceLocation?.coordinate else {
            distanceByStationID = [:]
            // Transform the localized name (a Hans→Hant StringTransform in zh-Hant) once per
            // element instead of on every comparison.
            searchResults = filtered
                .map { (station: $0, key: $0.localizedName) }
                .sorted { $0.key < $1.key }
                .map(\.station)
            return
        }
        // One distance per station, kept and used for both the order and the printed label.
        // Measured twice, a map-space correction landing in between would sort by one origin and
        // label from another.
        var distances: [String: CLLocationDistance] = [:]
        distances.reserveCapacity(filtered.count)
        searchResults = filtered
            .map { station -> (station: Station, distance: CLLocationDistance) in
                let distance = station.coordinate.distance(to: origin)
                distances[station.stationID] = distance
                return (station, distance)
            }
            .sorted { $0.distance < $1.distance }
            .map(\.station)
        distanceByStationID = distances
    }

    private func replaceUnfilteredResults(_ stations: [Station], loadID: UUID) {
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        unfilteredResults = stations
        hasEnrichedUnfilteredResultsForFacilities = false
        applyFilters()
        enrichForActiveFacilityFiltersIfNeeded(loadID: loadID)
    }

    private var activeFiltersNeedOfficialData: Bool {
        filter.accessibleOnly || filter.elevatorOnly || filter.facilityType != nil
    }

    private func enrichForActiveFacilityFiltersIfNeeded(loadID: UUID? = nil) {
        guard activeFiltersNeedOfficialData else {
            facilityEnrichmentTask?.cancel()
            isEnrichingForFacility = false
            return
        }
        guard !hasEnrichedUnfilteredResultsForFacilities,
              !unfilteredResults.isEmpty else { return }

        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = true
        let expectedLoadID = loadID ?? stationLoadID
        let stationsToEnrich = unfilteredResults
        facilityEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            let enriched = await stationSearchService.enrichStations(stationsToEnrich)
            // Identity check (`Station` is a class): publish only while the list this task enriched
            // is still the one displayed.
            guard !Task.isCancelled, stationLoadID == expectedLoadID,
                  unfilteredResults.elementsEqual(stationsToEnrich, by: ===) else { return }
            unfilteredResults = enriched
            hasEnrichedUnfilteredResultsForFacilities = true
            applyFilters()
            isEnrichingForFacility = false
        }
    }

    private func refreshLocationIfAlreadyAllowed() async {
        guard locationService.isAuthorized else { return }
        guard !hasRequestedSearchLocation || locationService.currentLocation == nil else { return }
        hasRequestedSearchLocation = true
        _ = try? await locationService.requestCurrentLocation()
    }
}
