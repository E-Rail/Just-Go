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

/// Device-only persistence for the last good official station-information snapshot per
/// station, so riders keep access to exits, facilities, and first/last trains offline.
///
/// Policy (enforced by validate_runtime_data_policy.rb): storage only — no network code in
/// this file; lives under Application Support excluded from iCloud/iTunes backup; never
/// bundled into the app or exported; wiped by both Settings → Clear Cache and the
/// data-rights epoch cleanup at launch.
actor OfficialStationInformationDiskCache: OfficialStationInformationCaching {
    /// v2 nests services under their line and gives every enum a stable string wire value; see
    /// `DataPacks/STATION_INFORMATION_SCHEMA.md`. A stored v1 entry fails the version check in
    /// `storedSnapshot` and is simply refetched, so no migration is needed.
    static let schemaVersion = 2
    // Mirrors the provider's network response cap: anything larger than a legitimate
    // response has no business being read back either.
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

    /// One subdirectory per city, so a station key that repeats across operators cannot collide.
    /// Beijing keeps the historical `1100` path, so entries cached before this change stay valid.
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
