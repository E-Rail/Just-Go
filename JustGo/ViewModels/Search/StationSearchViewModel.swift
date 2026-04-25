import Foundation
import CoreLocation

@Observable
final class StationSearchViewModel {
    var searchText: String = ""
    var searchResults: [Station] = []
    var recentSearches: [SearchHistory] = []
    var isSearching = false
    var errorMessage: String?

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
        defer { isSearching = false }

        do {
            let results = try await stationSearchService.search(keyword: searchText, city: city)
            searchResults = stationSearchService.filterStations(results, by: filter)
            searchResults = stationSearchService.sortStations(searchResults, by: sortStrategy, userLocation: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
        errorMessage = nil
    }

    func toggleAccessibleFilter() {
        filter.accessibleOnly.toggle()
    }

    func toggleElevatorFilter() {
        filter.elevatorOnly.toggle()
    }

    func toggleTransferFilter() {
        filter.transferOnly.toggle()
    }

    func accessibilityLabel(for station: Station) -> String {
        accessibilityService.stationAccessibilityLabel(station)
    }
}
