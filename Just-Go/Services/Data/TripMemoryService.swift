import Foundation

@MainActor
@Observable
final class TripMemoryService {
    private let userDefaults: UserDefaults
    private let tripRecordsKey = "tripRecords"
    private let stationQuickTagsKey = "stationQuickTags"
    /// Stores nothing reads any more, cleared so they do not sit on the device indefinitely.
    private let obsoleteKeys = ["favoriteStations", "riderAnswers.v1", "transferNotes.v1", "recentRoutes"]
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
        obsoleteKeys.forEach { userDefaults.removeObject(forKey: $0) }
        if stationQuickTags != storedQuickTags {
            userDefaults.setCodable(stationQuickTags, forKey: stationQuickTagsKey)
        }
    }

    /// Choosing between alternatives is one trip, not one per tap: the newest still-open record for
    /// the same two ends is replaced rather than added to.
    func recordPlannedTrip(route: Route, cityID: String) {
        if let newest = tripRecords.first, newest.completedAt == nil, isSameTrip(newest, route: route, cityID: cityID) {
            tripRecords[0] = makeRecord(route: route, cityID: cityID, id: newest.id)
            persistTripRecords()
            return
        }
        tripRecords.insert(makeRecord(route: route, cityID: cityID), at: 0)
        tripRecords = Array(tripRecords.prefix(maxTripRecords))
        persistTripRecords()
    }

    /// Completes the record written when the trip was planned, found by its two ends and city among
    /// the still-open records, and inserts one only when there is none. Pass the route as it was
    /// planned: a reroute renames the origin "Current Location", which matches nothing.
    func markTripComplete(route: Route, cityID: String, note: String? = nil) {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let index = tripRecords.firstIndex(where: {
            $0.completedAt == nil && isSameTrip($0, route: route, cityID: cityID)
        }) {
            tripRecords[index].completedAt = .now
            tripRecords[index].note = trimmedNote
            persistTripRecords()
            return
        }
        var record = makeRecord(route: route, cityID: cityID)
        record.completedAt = .now
        record.note = trimmedNote
        tripRecords.insert(record, at: 0)
        tripRecords = Array(tripRecords.prefix(maxTripRecords))
        persistTripRecords()
    }

    private func isSameTrip(_ record: TripRecord, route: Route, cityID: String) -> Bool {
        record.cityID == cityID && record.originName == route.origin && record.destinationName == route.destination
    }

    private func makeRecord(route: Route, cityID: String, id: String = UUID().uuidString) -> TripRecord {
        TripRecord(
            id: id,
            originName: route.origin,
            destinationName: route.destination,
            cityID: cityID,
            plannedDuration: route.totalDuration,
            walkingDistance: route.walkingDistance,
            transferCount: route.transferCount,
            strategy: route.strategy,
            warningMessages: route.warnings.map(\.message),
            createdAt: .now,
            completedAt: nil,
            note: nil,
            originCoordinate: route.groundOrigin,
            destinationCoordinate: route.groundDestination
        )
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
        save(StationQuickTag(station: station, cityName: cityName, cityNameEn: cityNameEn, kind: kind))
    }

    func setQuickTag(
        place: TransitPlace,
        cityID: String,
        cityName: String,
        cityNameEn: String? = nil,
        kind: StationQuickTagKind
    ) {
        save(StationQuickTag(place: place, cityID: cityID, cityName: cityName, cityNameEn: cityNameEn, kind: kind))
    }

    /// A tag already saved for the same target keeps its identity and takes the new kind and city.
    private func save(_ quickTag: StationQuickTag) {
        var quickTag = quickTag
        if let existing = stationQuickTags.first(where: { $0.id == quickTag.id }) {
            quickTag = existing
                .withCityMetadata(cityName: quickTag.cityName, cityNameEn: quickTag.cityNameEn)
                .withKind(quickTag.kind)
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
        stationQuickTags = StationQuickTagPolicy.inserting(existing.withKind(kind), into: stationQuickTags)
        persistStationQuickTags()
    }

    func quickTag(stationID: String, cityID: String) -> StationQuickTag? {
        stationQuickTags.first { $0.stationID == stationID && $0.cityID == cityID }
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
