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
    private let locationService: LocationService
    private let recentSearchesKey = "recentStationSearches"
    private var hasRequestedSearchLocation = false

    init(
        stationSearchService: StationSearchService,
        locationService: LocationService
    ) {
        self.stationSearchService = stationSearchService
        self.locationService = locationService
        recentSearches = UserDefaults.standard.codableValue(forKey: recentSearchesKey, as: [SearchHistory].self, default: [])
    }

    func loadInitialStations(city: String) async {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !city.isEmpty else { return }
        await refreshLocationIfAlreadyAllowed()

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
        await refreshLocationIfAlreadyAllowed()

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
