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

    private let stationSearchService: StationSearchService
    private let accessibilityService: AccessibilityService
    private let recentSearchesKey = "recentStationSearches"

    init(
        stationSearchService: StationSearchService,
        accessibilityService: AccessibilityService
    ) {
        self.stationSearchService = stationSearchService
        self.accessibilityService = accessibilityService
        recentSearches = UserDefaults.standard.codableValue(forKey: recentSearchesKey, as: [SearchHistory].self, default: [])
    }

    func loadInitialStations(city: String) async {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !city.isEmpty else { return }

        do {
            unfilteredResults = try await stationSearchService.search(keyword: "", city: city)
            applyFilters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func search(city: String) async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            await loadInitialStations(city: city)
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            let results = try await stationSearchService.search(keyword: searchText, city: city)
            unfilteredResults = results
            applyFilters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSearch() {
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

    func accessibilityLabel(for station: Station) -> String {
        accessibilityService.stationAccessibilityLabel(station)
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
        searchResults.sort { $0.localizedName < $1.localizedName }
    }
}
