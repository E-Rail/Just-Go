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

    var filter = StationFilter()

    var isEnrichingForFacility = false
    private var facilityEnrichmentTask: Task<Void, Never>?

    private let stationSearchService: StationSearchService
    private let locationService: LocationService
    private let recentSearchesKey = "recentStationSearches"
    private var hasRequestedSearchLocation = false
    private var stationLoadID = UUID()
    private var searchTask: Task<Void, Never>?

    init(
        stationSearchService: StationSearchService,
        locationService: LocationService
    ) {
        self.stationSearchService = stationSearchService
        self.locationService = locationService
        recentSearches = UserDefaults.standard.codableValue(forKey: recentSearchesKey, as: [SearchHistory].self, default: [])
    }

    func loadInitialStations(city: String) async {
        let loadID = UUID()
        stationLoadID = loadID
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !city.isEmpty else {
            unfilteredResults = []
            searchResults = []
            errorMessage = AppLocalization.localized("Choose a city to browse stations")
            return
        }
        await refreshLocationIfAlreadyAllowed()
        errorMessage = nil
        unfilteredResults = await stationSearchService.stations(in: city)
        guard stationLoadID == loadID else { return }
        applyFilters()
        unfilteredResults = await stationSearchService.enrichStations(unfilteredResults)
        guard stationLoadID == loadID else { return }
        applyFilters()
    }

    func search(city: String) async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            await loadInitialStations(city: city)
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        await refreshLocationIfAlreadyAllowed()

        do {
            let results = try await stationSearchService.search(keyword: searchText, city: city)
            unfilteredResults = results
            applyFilters()
        } catch {
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
        searchText = ""
        unfilteredResults = []
        searchResults = []
        errorMessage = nil
    }

    func toggleAccessibleFilter() {
        filter.accessibleOnly.toggle()
        applyFilters()
    }

    func toggleElevatorFilter() {
        filter.elevatorOnly.toggle()
        applyFilters()
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
        if type != nil && unfilteredResults.allSatisfy({ $0.facilities.isEmpty }) {
            facilityEnrichmentTask?.cancel()
            isEnrichingForFacility = true
            facilityEnrichmentTask = Task { [weak self] in
                guard let self else { return }
                let enriched = await stationSearchService.enrichStations(unfilteredResults)
                guard !Task.isCancelled else { return }
                unfilteredResults = enriched
                applyFilters()
                isEnrichingForFacility = false
            }
        } else {
            facilityEnrichmentTask?.cancel()
            isEnrichingForFacility = false
            applyFilters()
            if type == nil && unfilteredResults.isEmpty == false {
                errorMessage = nil
            }
        }
    }

    func distanceText(for station: Station) -> String? {
        guard let location = locationService.currentLocation else { return nil }
        let meters = station.coordinate.distance(to: location.coordinate)
        return AppLocalization.text(
            english: "\(AppLocalization.distance(meters)) from here",
            simplified: "距当前位置 \(AppLocalization.distance(meters))",
            traditional: "距目前位置 \(AppLocalization.distance(meters))"
        )
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
        searchResults = stationSearchService.filterStations(unfilteredResults, by: filter)
        if let location = locationService.currentLocation {
            searchResults.sort {
                $0.coordinate.distance(to: location.coordinate) < $1.coordinate.distance(to: location.coordinate)
            }
        } else {
            searchResults.sort { $0.localizedName < $1.localizedName }
        }
    }

    private func refreshLocationIfAlreadyAllowed() async {
        guard locationService.isAuthorized else { return }
        guard !hasRequestedSearchLocation || locationService.currentLocation == nil else { return }
        hasRequestedSearchLocation = true
        _ = try? await locationService.requestCurrentLocation()
    }
}
