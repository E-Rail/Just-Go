import Foundation
import CoreLocation
import SwiftUI

struct MapVisibleRegion {
    let center: CLLocationCoordinate2D
    let latitudeDelta: CLLocationDegrees
    let longitudeDelta: CLLocationDegrees

    var maxDelta: CLLocationDegrees {
        max(latitudeDelta, longitudeDelta)
    }

    func contains(_ coordinate: CLLocationCoordinate2D, paddingFactor: Double = 0.35) -> Bool {
        let latitudePadding = latitudeDelta * paddingFactor
        let longitudePadding = longitudeDelta * paddingFactor
        let latitudeRange = (center.latitude - latitudeDelta / 2 - latitudePadding)...(center.latitude + latitudeDelta / 2 + latitudePadding)
        let longitudeRange = (center.longitude - longitudeDelta / 2 - longitudePadding)...(center.longitude + longitudeDelta / 2 + longitudePadding)
        return latitudeRange.contains(coordinate.latitude) && longitudeRange.contains(coordinate.longitude)
    }
}

@Observable
final class MapViewModel {
    var stations: [Station] = []
    var subwayLines: [SubwayLineMapOverlay] = []
    var nearbyStations: [Station] = []
    var isShowingAllNearbyStations = false
    var searchText = ""
    var searchResults: [Station] = []
    var isLoading = false
    var errorMessage: String?
    var visibleRegion: MapVisibleRegion?
    var isLocationAuthorized: Bool {
        locationService.isAuthorized
    }

    private let locationService: LocationService
    private let stationSearchService: StationSearchService
    private let aMapService: AMapService
    private let cityService: CityService
    private var loadedCityID: String?
    private var loadingCityID: String?
    private var mapContentByCityID: [String: MetroMapContent] = [:]
    private var viewportLoadTask: Task<Void, Never>?
    private let metroDetailThreshold: CLLocationDegrees = 2.4

    init(
        locationService: LocationService,
        stationSearchService: StationSearchService,
        aMapService: AMapService,
        cityService: CityService
    ) {
        self.locationService = locationService
        self.stationSearchService = stationSearchService
        self.aMapService = aMapService
        self.cityService = cityService
    }

    var userLocation: CLLocationCoordinate2D? {
        locationService.currentLocation?.coordinate
    }

    func loadStations(for city: City) async {
        guard loadedCityID != city.id, loadingCityID != city.id else {
            updateCamera(to: city.coordinate, spanDelta: 0.22)
            return
        }

        let cityID = city.id
        loadingCityID = cityID
        isLoading = true
        updateCamera(to: city.coordinate, spanDelta: 0.22)
        defer {
            if loadingCityID == cityID {
                loadingCityID = nil
                isLoading = false
            }
        }

        let content = await mapContent(for: city)
        guard loadingCityID == cityID else { return }
        if !content.isEmpty {
            stations = content.stations
            subwayLines = content.subwayLines
            loadedCityID = cityID
        }
    }

    func loadNearbyStations() async {
        guard let location = userLocation else { return }

        do {
            nearbyStations = try await stationSearchService.searchNearby(location: location)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestLocationAccess() async {
        do {
            _ = try await locationService.requestCurrentLocation()
            await loadNearbyStations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleNearbyList() {
        isShowingAllNearbyStations.toggle()
    }

    func searchStations(in city: City?) async {
        guard let city else { return }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }

        do {
            searchResults = try await stationSearchService.suggestions(keyword: searchText, city: city.id, limit: 8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
    }

    func viewportChanged(to region: MapVisibleRegion) {
        visibleRegion = region
        viewportLoadTask?.cancel()
        viewportLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await self?.loadVisibleMapContent(for: region)
        }
    }

    @discardableResult
    func selectStation(_ station: Station) async -> Station {
        withAnimation {
            visibleRegion = MapVisibleRegion(
                center: station.coordinate,
                latitudeDelta: 0.01,
                longitudeDelta: 0.01
            )
        }

        do {
            let detailedStation = try await stationSearchService.stationDetails(
                stationID: station.stationID,
                city: station.cityID
            )
            return detailedStation
        } catch {
            errorMessage = error.localizedDescription
            return station
        }
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D) {
        updateCamera(to: coordinate, spanDelta: 0.1)
    }

    func updateCamera(to coordinate: CLLocationCoordinate2D, spanDelta: CLLocationDegrees) {
        withAnimation {
            visibleRegion = MapVisibleRegion(
                center: coordinate,
                latitudeDelta: spanDelta,
                longitudeDelta: spanDelta
            )
        }
    }

    func centerOnUser() {
        guard let location = userLocation else { return }
        updateCamera(to: location)
    }

    private func loadVisibleMapContent(for region: MapVisibleRegion) async {
        guard region.maxDelta <= metroDetailThreshold else { return }

        let visibleCities = cityService.getAllCities()
            .filter { region.contains($0.coordinate) }

        if visibleCities.count == 1, visibleCities.first?.id == loadingCityID {
            return
        }

        guard !visibleCities.isEmpty else { return }

        let contents = await visibleCities.asyncMap { city in
            await self.mapContent(for: city)
        }
        if contents.contains(where: { !$0.isEmpty }) {
            stations = contents.flatMap(\.stations)
            subwayLines = contents.flatMap(\.subwayLines)
        }
    }

    private func mapContent(for city: City) async -> MetroMapContent {
        if let cached = mapContentByCityID[city.id] {
            return cached
        }

        async let nextStations = try? stationSearchService.search(keyword: "", city: city.id)
        async let nextSubwayLines = try? aMapService.getSubwayLines(city: city.id)
        let content = MetroMapContent(
            stations: await nextStations ?? [],
            subwayLines: await nextSubwayLines ?? []
        )
        if !content.isEmpty {
            mapContentByCityID[city.id] = content
        }
        return content
    }
}

private struct MetroMapContent {
    let stations: [Station]
    let subwayLines: [SubwayLineMapOverlay]

    var isEmpty: Bool {
        stations.isEmpty && subwayLines.isEmpty
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}
