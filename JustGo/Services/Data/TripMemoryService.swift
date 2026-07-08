import Foundation

@MainActor
@Observable
final class TripMemoryService {
    private let userDefaults: UserDefaults
    private let savedTripsKey = "savedTrips"
    private let tripRecordsKey = "tripRecords"
    private let favoriteStationsKey = "favoriteStations"
    private let maxSavedTrips = 50
    private let maxTripRecords = 300
    private let maxFavoriteStations = 50

    private(set) var savedTrips: [SavedTrip]
    private(set) var tripRecords: [TripRecord]
    private(set) var favoriteStations: [FavoriteStation]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        savedTrips = userDefaults.codableValue(forKey: savedTripsKey, as: [SavedTrip].self, default: [])
        tripRecords = userDefaults.codableValue(forKey: tripRecordsKey, as: [TripRecord].self, default: [])
        favoriteStations = userDefaults.codableValue(forKey: favoriteStationsKey, as: [FavoriteStation].self, default: [])
    }

    func createSavedTrip(
        name: String,
        origin: TransitPlaceSnapshot,
        destination: TransitPlaceSnapshot,
        city: City,
        preferredStrategy: RouteStrategy?,
        preferredRoutePreference: RoutePreference? = nil,
        accessibilityFilter: AccessibilityFilter,
        notes: String? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "\(origin.name) -> \(destination.name)"
        let savedTrip = SavedTrip(
            id: UUID().uuidString,
            name: trimmedName.isEmpty ? fallbackName : trimmedName,
            origin: origin,
            destination: destination,
            cityID: city.id,
            cityName: city.localizedName,
            preferredStrategy: preferredStrategy,
            preferredRoutePreference: preferredRoutePreference,
            accessibilityFilter: SavedTripAccessibilityFilter(filter: accessibilityFilter),
            createdAt: .now,
            lastUsedAt: nil,
            useCount: 0,
            notes: notes
        )

        savedTrips.removeAll { existing in
            existing.origin.name == savedTrip.origin.name &&
                existing.destination.name == savedTrip.destination.name &&
                existing.cityID == savedTrip.cityID
        }
        savedTrips.insert(savedTrip, at: 0)
        savedTrips = Array(savedTrips.prefix(maxSavedTrips))
        persistSavedTrips()
    }

    func deleteSavedTrip(id: String) {
        savedTrips.removeAll { $0.id == id }
        persistSavedTrips()
    }

    func markSavedTripUsed(id: String) -> SavedTrip? {
        guard let index = savedTrips.firstIndex(where: { $0.id == id }) else { return nil }
        savedTrips[index].useCount += 1
        savedTrips[index].lastUsedAt = .now
        let trip = savedTrips.remove(at: index)
        savedTrips.insert(trip, at: 0)
        persistSavedTrips()
        return trip
    }

    func recordPlannedTrip(route: Route, cityID: String, accessibilityFilter: AccessibilityFilter, savedTripID: String? = nil) -> TripRecord {
        let record = TripRecord(
            id: UUID().uuidString,
            savedTripID: savedTripID,
            originName: route.origin,
            destinationName: route.destination,
            cityID: cityID,
            routeSummary: route.formattedDuration,
            plannedDuration: route.totalDuration,
            walkingDistance: route.walkingDistance,
            transferCount: route.transferCount,
            strategy: route.strategy,
            accessibilityFilter: SavedTripAccessibilityFilter(filter: accessibilityFilter),
            warningMessages: route.warnings.map(\.message),
            createdAt: .now,
            completedAt: nil,
            note: nil
        )
        tripRecords.insert(record, at: 0)
        tripRecords = Array(tripRecords.prefix(maxTripRecords))
        persistTripRecords()
        return record
    }

    func markTripComplete(route: Route, cityID: String, accessibilityFilter: AccessibilityFilter = .none, note: String? = nil) {
        let record = TripRecord(
            id: UUID().uuidString,
            savedTripID: nil,
            originName: route.origin,
            destinationName: route.destination,
            cityID: cityID,
            routeSummary: route.formattedDuration,
            plannedDuration: route.totalDuration,
            walkingDistance: route.walkingDistance,
            transferCount: route.transferCount,
            strategy: route.strategy,
            accessibilityFilter: SavedTripAccessibilityFilter(filter: accessibilityFilter),
            warningMessages: route.warnings.map(\.message),
            createdAt: .now,
            completedAt: .now,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        tripRecords.insert(record, at: 0)
        tripRecords = Array(tripRecords.prefix(maxTripRecords))
        persistTripRecords()
    }

    func deleteTripRecord(id: String) {
        tripRecords.removeAll { $0.id == id }
        persistTripRecords()
    }

    private func persistSavedTrips() {
        userDefaults.setCodable(savedTrips, forKey: savedTripsKey)
    }

    private func persistTripRecords() {
        userDefaults.setCodable(tripRecords, forKey: tripRecordsKey)
    }

    private func persistFavoriteStations() {
        userDefaults.setCodable(favoriteStations, forKey: favoriteStationsKey)
    }

    func addFavorite(station: Station, cityName: String, cityNameEn: String? = nil) {
        var favorite = FavoriteStation(station: station, cityName: cityName, cityNameEn: cityNameEn)
        // Re-favoriting rebuilds the row from the station — keep the user's tag with it.
        favorite.tag = favoriteStations.first { $0.id == favorite.id }?.tag
        favoriteStations.removeAll { $0.id == favorite.id }
        favoriteStations.insert(favorite, at: 0)
        favoriteStations = Array(favoriteStations.prefix(maxFavoriteStations))
        persistFavoriteStations()
    }

    func removeFavorite(id: String) {
        favoriteStations.removeAll { $0.id == id }
        persistFavoriteStations()
    }

    func setFavoriteTag(id: String, tag: FavoriteStationTag?) {
        var updated = favoriteStations
        var didChange = false
        for (index, favorite) in updated.enumerated() {
            if favorite.id == id {
                guard favorite.tag != tag else { continue }
                updated[index].tag = tag
                didChange = true
            } else if let tag, favorite.tag == tag {
                // Home and Work are single places; assigning one to another station
                // unassigns the previous holder. Custom tags may repeat.
                switch tag {
                case .home, .work:
                    updated[index].tag = nil
                    didChange = true
                case .custom:
                    break
                }
            }
        }
        guard didChange else { return }
        favoriteStations = updated
        persistFavoriteStations()
    }

    func isFavorite(stationID: String, cityID: String) -> Bool {
        favoriteStations.contains { $0.stationID == stationID && $0.cityID == cityID }
    }

    func repairFavoriteCityMetadata(cityLookup: (String) -> City?) {
        // Assign the observed property only when a repair actually happened — this runs on
        // every favorites-list appearance, and an unconditional reassign would fire
        // observation churn each time.
        var repaired = favoriteStations
        var didRepair = false
        for (index, favorite) in favoriteStations.enumerated() {
            guard let city = cityLookup(favorite.cityID),
                  favorite.cityName != city.name || favorite.cityNameEn != city.nameEn else { continue }
            repaired[index] = favorite.withCityMetadata(cityName: city.name, cityNameEn: city.nameEn)
            didRepair = true
        }
        if didRepair {
            favoriteStations = repaired
            persistFavoriteStations()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
