import Foundation

enum StationInformationCacheLocation {
    static func rootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Just-Go", isDirectory: true)
            .appendingPathComponent("StationInformationCache", isDirectory: true)
    }
}

/// Device-only persistence for the last good official station-information snapshot per station, so
/// exits, facilities and first/last trains stay available offline.
///
/// Policy, enforced by validate_runtime_data_policy.rb: storage only, no network code; under
/// Application Support, excluded from backup; never bundled or exported; wiped by Settings → Clear
/// Cache and by the data-rights epoch cleanup at launch.
actor OfficialStationInformationDiskCache: OfficialStationInformationCaching {
    /// v2 nests services under their line with stable string wire values; v3 adds `destination`,
    /// separating a short-turn from the full run under one direction marker. See
    /// `DataPacks/STATION_INFORMATION_SCHEMA.md`. An older entry fails the version check and is
    /// refetched, which for v3 is the point: it would keep serving the merged last train offline.
    static let schemaVersion = 3
    // The provider's own response cap: anything larger has no business being read back either.
    private static let maximumEntryBytes = 1_048_576

    private struct StoredEnvelope: Codable {
        let schemaVersion: Int
        let externalStationID: String
        let fetchedAt: Date
        let snapshot: OfficialStationInformationSnapshot
    }

    private let fileManager: FileManager
    private let rootURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        rootURL = StationInformationCacheLocation.rootURL(fileManager: fileManager)
    }

    func storedSnapshot(
        cityID: String,
        stationID: String,
        externalStationID: String
    ) -> (snapshot: OfficialStationInformationSnapshot, fetchedAt: Date)? {
        let url = entryURL(cityID: cityID, externalStationID: externalStationID)
        guard let data = try? Data(contentsOf: url),
              data.count <= Self.maximumEntryBytes,
              let envelope = try? JSONDecoder().decode(StoredEnvelope.self, from: data),
              envelope.schemaVersion == Self.schemaVersion,
              envelope.externalStationID == externalStationID,
              envelope.snapshot.stationID == stationID else {
            return nil
        }
        return (envelope.snapshot, envelope.fetchedAt)
    }

    func store(
        _ snapshot: OfficialStationInformationSnapshot,
        cityID: String,
        externalStationID: String
    ) {
        let envelope = StoredEnvelope(
            schemaVersion: Self.schemaVersion,
            externalStationID: externalStationID,
            fetchedAt: .now,
            snapshot: snapshot
        )
        guard let data = try? JSONEncoder().encode(envelope),
              data.count <= Self.maximumEntryBytes else { return }
        do {
            let directory = directoryURL(cityID: cityID)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var backupExclusion = URLResourceValues()
            backupExclusion.isExcludedFromBackup = true
            var root = rootURL
            try? root.setResourceValues(backupExclusion)
            try data.write(to: entryURL(cityID: cityID, externalStationID: externalStationID), options: .atomic)
        } catch {
            AppLog.data.error("Station information cache write failed: \(error)")
        }
    }

    func clearAll() {
        try? fileManager.removeItem(at: rootURL)
    }

    /// One subdirectory per city, so a station key repeated across operators cannot collide.
    /// Beijing keeps its `1100` path.
    private func directoryURL(cityID: String) -> URL {
        let safeCity = cityID.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
        return rootURL.appendingPathComponent(safeCity.isEmpty ? "unknown" : safeCity, isDirectory: true)
    }

    private func entryURL(cityID: String, externalStationID: String) -> URL {
        let safeName = externalStationID.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
        return directoryURL(cityID: cityID).appendingPathComponent("\(safeName).json", isDirectory: false)
    }
}
