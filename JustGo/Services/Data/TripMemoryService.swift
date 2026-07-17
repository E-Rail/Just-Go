import Foundation

@MainActor
@Observable
final class TripMemoryService {
    private let userDefaults: UserDefaults
    private let savedTripsKey = "savedTrips"
    private let tripRecordsKey = "tripRecords"
    private let stationQuickTagsKey = "stationQuickTags"
    private let obsoleteFavoriteStationsKey = "favoriteStations"
    private let maxSavedTrips = 50
    private let maxTripRecords = 300

    private(set) var savedTrips: [SavedTrip]
    private(set) var tripRecords: [TripRecord]
    private(set) var stationQuickTags: [StationQuickTag]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        savedTrips = userDefaults.codableValue(forKey: savedTripsKey, as: [SavedTrip].self, default: [])
        tripRecords = userDefaults.codableValue(forKey: tripRecordsKey, as: [TripRecord].self, default: [])
        let storedQuickTags = userDefaults.codableValue(
            forKey: stationQuickTagsKey,
            as: [StationQuickTag].self,
            default: []
        )
        stationQuickTags = StationQuickTagPolicy.normalized(storedQuickTags)
        userDefaults.removeObject(forKey: obsoleteFavoriteStationsKey)
        if stationQuickTags != storedQuickTags {
            userDefaults.setCodable(stationQuickTags, forKey: stationQuickTagsKey)
        }
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

    private func persistStationQuickTags() {
        userDefaults.setCodable(stationQuickTags, forKey: stationQuickTagsKey)
    }

    @discardableResult
    func setQuickTag(
        station: Station,
        cityName: String,
        cityNameEn: String? = nil,
        kind: StationQuickTagKind,
        replacing replacementID: String? = nil
    ) -> StationQuickTagMutationResult {
        var quickTag = StationQuickTag(station: station, cityName: cityName, cityNameEn: cityNameEn, kind: kind)
        if let existing = stationQuickTags.first(where: { $0.id == quickTag.id }) {
            quickTag = existing
                .withCityMetadata(cityName: cityName, cityNameEn: cityNameEn)
                .withKind(kind)
        }
        guard let updated = StationQuickTagPolicy.inserting(
            quickTag,
            into: stationQuickTags,
            replacing: replacementID
        ) else {
            return .replacementRequired(stationQuickTags)
        }
        stationQuickTags = updated
        persistStationQuickTags()
        return .saved
    }

    func deleteQuickTag(id: String) {
        stationQuickTags.removeAll { $0.id == id }
        persistStationQuickTags()
    }

    func updateQuickTag(id: String, kind: StationQuickTagKind) {
        guard let existing = stationQuickTags.first(where: { $0.id == id }) else { return }
        let updatedTag = existing.withKind(kind)
        var updated = stationQuickTags.filter { quickTag in
            quickTag.id != id && !(kind.isExclusive && quickTag.kind == kind)
        }
        updated.insert(updatedTag, at: 0)
        stationQuickTags = StationQuickTagPolicy.normalized(updated)
        persistStationQuickTags()
    }

    func quickTag(stationID: String, cityID: String) -> StationQuickTag? {
        stationQuickTags.first { $0.stationID == stationID && $0.cityID == cityID }
    }

    func isQuickTagged(stationID: String, cityID: String) -> Bool {
        quickTag(stationID: stationID, cityID: cityID) != nil
    }

    func repairQuickTagCityMetadata(cityLookup: (String) -> City?) {
        var repaired = stationQuickTags
        var didRepair = false
        for (index, quickTag) in stationQuickTags.enumerated() {
            guard let city = cityLookup(quickTag.cityID),
                  quickTag.cityName != city.name || quickTag.cityNameEn != city.nameEn else { continue }
            repaired[index] = quickTag.withCityMetadata(cityName: city.name, cityNameEn: city.nameEn)
            didRepair = true
        }
        if didRepair {
            stationQuickTags = StationQuickTagPolicy.normalized(repaired)
            persistStationQuickTags()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
