import Foundation
import CoreLocation

@Observable
final class StationSearchViewModel {
    var searchText: String = ""
    var searchResults: [Station] = []
    var recentSearches: [SearchHistory] = []
    var isSearching = false
    var errorMessage: String?
    private var unfilteredResults: [Station] = []
    private var hasEnrichedUnfilteredResultsForFacilities = false

    var filter = StationFilter()

    var isEnrichingForFacility = false
    private var facilityEnrichmentTask: Task<Void, Never>?

    private let stationSearchService: StationSearchService
    private let locationService: LocationService
    private let recentSearchesKey = "recentStationSearches"
    private var hasRequestedSearchLocation = false
    private var stationLoadID = UUID()
    private var searchTask: Task<Void, Never>?
    private var currentCityID: String?

    init(
        stationSearchService: StationSearchService,
        locationService: LocationService
    ) {
        self.stationSearchService = stationSearchService
        self.locationService = locationService
        recentSearches = UserDefaults.standard.codableValue(forKey: recentSearchesKey, as: [SearchHistory].self, default: [])
    }

    deinit {
        searchTask?.cancel()
        facilityEnrichmentTask?.cancel()
    }

    func loadInitialStations(city: String) async {
        let loadID = UUID()
        stationLoadID = loadID
        // Minting a new token supersedes any in-flight keyword search AND facility
        // enrichment, whose stale-token guards then (correctly) refuse to publish — so
        // this mint owns clearing both flags, or a re-appearance mid-work leaves a
        // spinner stuck true with nothing left to reset it.
        isSearching = false
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        if city != currentCityID {
            currentCityID = city
            filter = StationFilter()
            // A real city switch also invalidates the previous city's query: without this,
            // a non-empty searchText returns at the guard below and leaves the old city's
            // results listed under the new one — with a still-pending debounced searchTask
            // that would reload the OLD city once its 180ms sleep elapses.
            searchTask?.cancel()
            searchText = ""
            unfilteredResults = []
            hasEnrichedUnfilteredResultsForFacilities = false
            searchResults = []
            errorMessage = nil
        }
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Keyword results stay listed; the entry cancel above killed any in-flight
            // enrichment, so restart it under the fresh token if filters still need it.
            enrichForActiveFacilityFiltersIfNeeded()
            return
        }
        guard !city.isEmpty else {
            unfilteredResults = []
            hasEnrichedUnfilteredResultsForFacilities = false
            searchResults = []
            errorMessage = AppLocalization.localized("Choose a city to browse stations")
            return
        }
        await refreshLocationIfAlreadyAllowed()
        errorMessage = nil
        let stations = await stationSearchService.stations(in: city)
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

    func search(city: String) async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            await loadInitialStations(city: city)
            return
        }

        // Generation token so a superseded query — or one that returns after the field is
        // cleared — can't stomp the current results. MKLocalSearch ignores Swift task
        // cancellation, so the in-flight network call still completes; the token discards it.
        // The token alone isn't enough: after the text changes, the NEXT search doesn't mint
        // a new token until its 180ms debounce elapses, so a stale search returning inside
        // that window would still pass — hence the captured-query check on publish too.
        let loadID = UUID()
        stationLoadID = loadID
        // Minting the token supersedes any in-flight facility enrichment (its stale-token
        // guard will refuse to publish) — so this mint owns clearing its flag, or a search
        // that errors out leaves "Checking station details…" spinning forever.
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        isSearching = true
        // defer guarantees the spinner clears on EVERY exit, including the stale-token early
        // returns below — otherwise a cleared/superseded search leaves isSearching stuck true
        // and the results list spins forever even after loadInitialStations repopulates it.
        defer {
            if stationLoadID == loadID {
                isSearching = false
            }
        }
        errorMessage = nil
        await refreshLocationIfAlreadyAllowed()

        do {
            let results = try await stationSearchService.search(keyword: query, city: city)
            guard stationLoadID == loadID,
                  searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            replaceUnfilteredResults(results, loadID: loadID)
        } catch {
            guard stationLoadID == loadID,
                  searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            errorMessage = AppLocalization.localized("Place search requires a network connection")
        }
    }

    func scheduleSearch(city: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.search(city: city)
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

    func toggleAccessibleFilter() {
        filter.accessibleOnly.toggle()
        applyFilters()
        enrichForActiveFacilityFiltersIfNeeded()
    }

    func toggleElevatorFilter() {
        filter.elevatorOnly.toggle()
        applyFilters()
        enrichForActiveFacilityFiltersIfNeeded()
    }

    func toggleTransferFilter() {
        filter.transferOnly.toggle()
        applyFilters()
    }

    func clearFilters() {
        facilityEnrichmentTask?.cancel()
        isEnrichingForFacility = false
        filter = StationFilter()
        applyFilters()
    }

    func setFacilityFilter(_ type: StationFacilityType?) {
        filter.facilityType = type
        applyFilters()
        enrichForActiveFacilityFiltersIfNeeded()
        if !activeFiltersNeedOfficialData {
            facilityEnrichmentTask?.cancel()
            isEnrichingForFacility = false
            if unfilteredResults.isEmpty == false {
                errorMessage = nil
            }
        }
    }

    func distanceText(for station: Station) -> String? {
        // Station coordinates are GCJ-02; a raw Core Location fix is not, and the gap is ~540 m —
        // larger than most of the distances this line prints. See LocationService.mapSpaceLocation.
        guard let location = locationService.mapSpaceLocation else { return nil }
        let meters = station.coordinate.distance(to: location.coordinate)
        return AppLocalization.text(
            english: "\(AppLocalization.distance(meters)) from here",
            simplified: "距当前位置 \(AppLocalization.distance(meters))",
            traditional: "距目前位置 \(AppLocalization.distance(meters))"
        )
    }

    /// The exact stored station for a recent-search row — replay must not re-resolve by
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

    private func applyFilters() {
        let filtered = stationSearchService.filterStations(unfilteredResults, by: filter)
        if let location = locationService.mapSpaceLocation {
            // Compute each distance once (Haversine is trig-heavy) rather than recomputing it
            // inside every comparator call.
            let origin = location.coordinate
            searchResults = filtered
                .map { (station: $0, distance: $0.coordinate.distance(to: origin)) }
                .sorted { $0.distance < $1.distance }
                .map(\.station)
        } else {
            // Transform the localized name (a Hans→Hant StringTransform in zh-Hant) once per
            // element instead of on every comparison.
            searchResults = filtered
                .map { (station: $0, key: $0.localizedName) }
                .sorted { $0.key < $1.key }
                .map(\.station)
        }
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
            // Identity check (Station is a class): publish only while the list this task
            // enriched is still the one displayed — the load token alone can't see a
            // keyword search that replaced the results within the same city epoch.
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
