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

    // Filters
    var filter = StationFilter()
    var sortStrategy: StationSortStrategy = .name

    private let stationSearchService: StationSearchService
    private let accessibilityService: AccessibilityService

    init(
        stationSearchService: StationSearchService,
        accessibilityService: AccessibilityService
    ) {
        self.stationSearchService = stationSearchService
        self.accessibilityService = accessibilityService
    }

    func search(city: String) async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
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

    private func applyFilters() {
        searchResults = stationSearchService.filterStations(unfilteredResults, by: filter)
        searchResults = stationSearchService.sortStations(searchResults, by: sortStrategy, userLocation: nil)
    }
}
