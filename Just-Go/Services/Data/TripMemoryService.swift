import Foundation

@MainActor
@Observable
final class TripMemoryService {
    private let userDefaults: UserDefaults
    private let tripRecordsKey = "tripRecords"
    private let stationQuickTagsKey = "stationQuickTags"
    private let obsoleteFavoriteStationsKey = "favoriteStations"
    private let maxTripRecords = 300

    private(set) var tripRecords: [TripRecord]
    private(set) var stationQuickTags: [StationQuickTag]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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

    func recordPlannedTrip(route: Route, cityID: String) -> TripRecord {
        let record = TripRecord(
            id: UUID().uuidString,
            originName: route.origin,
            destinationName: route.destination,
            cityID: cityID,
            routeSummary: route.formattedDuration,
            plannedDuration: route.totalDuration,
            walkingDistance: route.walkingDistance,
            transferCount: route.transferCount,
            strategy: route.strategy,
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

    func markTripComplete(route: Route, cityID: String, note: String? = nil) {
        let record = TripRecord(
            id: UUID().uuidString,
            originName: route.origin,
            destinationName: route.destination,
            cityID: cityID,
            routeSummary: route.formattedDuration,
            plannedDuration: route.totalDuration,
            walkingDistance: route.walkingDistance,
            transferCount: route.transferCount,
            strategy: route.strategy,
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

    private func persistTripRecords() {
        userDefaults.setCodable(tripRecords, forKey: tripRecordsKey)
    }

    private func persistStationQuickTags() {
        userDefaults.setCodable(stationQuickTags, forKey: stationQuickTagsKey)
    }

    func setQuickTag(
        station: Station,
        cityName: String,
        cityNameEn: String? = nil,
        kind: StationQuickTagKind
    ) {
        var quickTag = StationQuickTag(station: station, cityName: cityName, cityNameEn: cityNameEn, kind: kind)
        if let existing = stationQuickTags.first(where: { $0.id == quickTag.id }) {
            quickTag = existing
                .withCityMetadata(cityName: cityName, cityNameEn: cityNameEn)
                .withKind(kind)
        }
        stationQuickTags = StationQuickTagPolicy.inserting(quickTag, into: stationQuickTags)
        persistStationQuickTags()
    }

    func setQuickTag(
        place: TransitPlace,
        cityID: String,
        cityName: String,
        cityNameEn: String? = nil,
        kind: StationQuickTagKind
    ) {
        var quickTag = StationQuickTag(place: place, cityID: cityID, cityName: cityName, cityNameEn: cityNameEn, kind: kind)
        if let existing = stationQuickTags.first(where: { $0.id == quickTag.id }) {
            quickTag = existing
                .withCityMetadata(cityName: cityName, cityNameEn: cityNameEn)
                .withKind(kind)
        }
        stationQuickTags = StationQuickTagPolicy.inserting(quickTag, into: stationQuickTags)
        persistStationQuickTags()
    }

    /// Matched on the place identity alone (not cityID): the city stamped on a POI tag comes
    /// from a nearest-city guess, so requiring it to match again would hide the tagged state
    /// whenever that guess shifts.
    func quickTag(place: TransitPlace) -> StationQuickTag? {
        let identifier = StationQuickTag.placeIdentifier(for: place)
        return stationQuickTags.first { $0.stationID == identifier }
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

    /// Re-syncs each tag's frozen station snapshot (station ID, coordinates, line
    /// names/colors, English names) against the current bundled network data. Tags capture
    /// this data at save time, and data refreshes regenerate the content-hash station IDs.
    /// Without this pass, tags saved before a refresh drift out of sync with what the rest
    /// of the app shows for the same station.
    func repairQuickTagStationData(stationLookup: @MainActor (StationQuickTag) async -> Station?) async {
        let original = stationQuickTags
        var repaired = original
        var didRepair = false
        for (index, quickTag) in original.enumerated() {
            guard quickTag.resolvedTargetType == .station else { continue }
            guard let station = await stationLookup(quickTag) else { continue }
            let rebuilt = StationQuickTag(
                station: station,
                cityName: quickTag.cityName,
                cityNameEn: quickTag.cityNameEn,
                kind: quickTag.kind
            )
            if rebuilt != quickTag {
                repaired[index] = rebuilt
                didRepair = true
            }
        }
        // A user mutation while a lookup was in flight wins. Drop this pass instead of
        // clobbering it; the next launch repairs whatever is still stale.
        guard didRepair, stationQuickTags == original else { return }
        stationQuickTags = StationQuickTagPolicy.normalized(repaired)
        persistStationQuickTags()
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
