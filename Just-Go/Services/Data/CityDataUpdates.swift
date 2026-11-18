import CryptoKit
import Foundation

// MARK: - What the manifest says about a network

/// One bundled metro network as `DataPacks/manifest.json` lists it: what a data update compares
/// against the network in use and downloads. The bytes are checked against `sizeBytes` and
/// `sha256` before anything decodes them.
struct CityNetworkManifestEntry: Codable, Equatable, Sendable {
    let cityID: String
    /// `osm-YYYYMMDD`, the OpenStreetMap snapshot the network was built from. Compared numerically.
    let version: String
    let sizeBytes: Int
    let sha256: String
    let bundledResource: String
    /// Relative to the manifest, so one manifest serves every mirror.
    let downloadURL: String

    /// The largest bundled network is under 1 MB; anything near this is not a network.
    static let maximumBytes = 20_000_000

    var hasValidContract: Bool {
        !cityID.isEmpty &&
            cityID.unicodeScalars.allSatisfy { (48...57).contains($0.value) } &&
            !version.isEmpty && version.utf8.count <= 64 &&
            sizeBytes > 0 && sizeBytes <= Self.maximumBytes &&
            sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
    }

    func validates(_ data: Data) -> Bool {
        hasValidContract &&
            data.count == sizeBytes &&
            data.cityDataSHA256 == sha256.lowercased()
    }

    /// Whether this is not older than `other`, by snapshot.
    func isNotOlder(than other: CityNetworkManifestEntry) -> Bool {
        version.compare(other.version, options: [.numeric, .caseInsensitive]) != .orderedAscending
    }
}

extension Data {
    var cityDataSHA256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

extension MetroNetwork {
    /// The checks a downloaded network passes before it replaces a bundled one, beyond the hash
    /// that ties it to the repository: everything the routing graph and the map index by ID has to
    /// resolve, so a file that decodes but does not hang together is refused rather than drawn.
    /// An interchange needs one end here only: Shenzhen's and Hong Kong's border crossings name a
    /// station in the other city's network.
    func validatesAsUpdate(for entry: CityNetworkManifestEntry) -> Bool {
        guard cityID == entry.cityID,
              version == entry.version,
              geometryKind == "physicalTrack",
              !stations.isEmpty,
              !lines.isEmpty else { return false }
        let stationIDs = Set(stations.map(\.id))
        let lineIDs = Set(lines.map(\.id))
        guard stationIDs.count == stations.count, lineIDs.count == lines.count else { return false }
        let stationsHold = stations.allSatisfy { station in
            station.latitude.isFinite && abs(station.latitude) <= 90 &&
                station.longitude.isFinite && abs(station.longitude) <= 180 &&
                Set(station.lineIDs).isSubset(of: lineIDs)
        }
        let linesHold = lines.allSatisfy { line in
            Set(line.stationIDs).isSubset(of: stationIDs) &&
                line.servicePatterns.allSatisfy { Set($0).isSubset(of: stationIDs) } &&
                (line.serviceVariants ?? []).allSatisfy { Set($0.stationIDs).isSubset(of: stationIDs) }
        }
        let interchangesHold = interchanges.allSatisfy { interchange in
            (stationIDs.contains(interchange.fromStationID) || stationIDs.contains(interchange.toStationID)) &&
                interchange.walkingDistanceMeters.isFinite && interchange.walkingDistanceMeters >= 0
        }
        return stationsHold && linesHold && interchangesHold
    }
}

// MARK: - Networks on disk

/// Metro networks a data update installed, which `BundledMetroNetworkService` reads in place of the
/// bundled ones. Under the city packs' root, so Clear Cache, a data-rights epoch and a new build
/// sweep both together, and a downloaded pack is never left beside a network it was not checked
/// against.
///
/// A city's record names the file in use. Superseded files stay until `prune`, so an install can be
/// taken back if the pack that goes with it does not store.
enum InstalledCityNetworks {
    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let entry: CityNetworkManifestEntry
        let installedAt: Date
    }

    private static let schemaVersion = 1
    private static let recordName = "installed.json"

    static func rootURL(fileManager: FileManager = .default) -> URL {
        CityPackStorageLocation.rootURL(fileManager: fileManager)
            .appendingPathComponent("networks", isDirectory: true)
    }

    /// Nil for anything that is not a plain numeric city ID, so no path can be built from one.
    private static func directory(for cityID: String) -> URL? {
        guard !cityID.isEmpty,
              cityID.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else { return nil }
        return rootURL().appendingPathComponent(cityID, isDirectory: true)
    }

    private static func dataURL(for entry: CityNetworkManifestEntry, in directory: URL) -> URL {
        directory.appendingPathComponent("\(entry.sha256.lowercased()).json")
    }

    static func record(for cityID: String) -> Record? {
        guard let directory = directory(for: cityID),
              let data = try? Data(contentsOf: directory.appendingPathComponent(recordName)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schemaVersion == schemaVersion,
              record.entry.cityID == cityID,
              record.entry.hasValidContract else { return nil }
        return record
    }

    /// The installed network's file, while it is the size it was when it was hashed. Not hashed
    /// again on every read: it was checked when it was installed, and one that will not decode is
    /// passed over for the bundled network.
    static func fileURL(for cityID: String) -> URL? {
        guard let record = record(for: cityID), let directory = directory(for: cityID) else { return nil }
        let url = dataURL(for: record.entry, in: directory)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == record.entry.sizeBytes else { return nil }
        return url
    }

    static func installedCityIDs() -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: rootURL().path)) ?? []
        return children.filter { record(for: $0) != nil }.sorted()
    }

    /// Writes the file and points the city's record at it. Returns the record it replaced, for
    /// `restore`.
    @discardableResult
    static func install(_ data: Data, for entry: CityNetworkManifestEntry) throws -> Record? {
        guard entry.validates(data), let directory = directory(for: entry.cityID) else {
            throw InstalledCityNetworkError.invalid
        }
        let previous = record(for: entry.cityID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: dataURL(for: entry, in: directory), options: .atomic)
        try write(Record(schemaVersion: schemaVersion, entry: entry, installedAt: Date()), in: directory)
        return previous
    }

    /// Drops the city's record, so the bundled network is used. Returns the record it removed, for
    /// `restore`.
    @discardableResult
    static func uninstall(_ cityID: String) throws -> Record? {
        guard let directory = directory(for: cityID) else { return nil }
        let previous = record(for: cityID)
        let url = directory.appendingPathComponent(recordName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return previous
    }

    /// Puts back what `install` or `uninstall` replaced.
    static func restore(_ previous: Record?, for cityID: String) {
        guard let directory = directory(for: cityID) else { return }
        if let previous {
            try? write(previous, in: directory)
        } else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(recordName))
        }
    }

    /// Removes every file the city's record does not name, and the directory with no record.
    static func prune(_ cityID: String) {
        guard let directory = directory(for: cityID) else { return }
        guard let current = record(for: cityID) else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        let kept: Set<String> = [recordName, dataURL(for: current.entry, in: directory).lastPathComponent]
        let children = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for child in children where !kept.contains(child) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(child))
        }
    }

    private static func write(_ record: Record, in directory: URL) throws {
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(recordName), options: .atomic)
    }
}

enum InstalledCityNetworkError: Error {
    case invalid
}

/// Downloaded city data belongs to the build that fetched it. A new build bundles data at least as
/// new as the repository was when the build was cut, while a download made under an older build
/// can be older still and pass every check, so it would quietly win over the newer bundled copy.
/// The first launch of each build therefore sweeps the downloads; the next update fetches whatever
/// the repository has that this build's bundle lacks.
enum CityDataBuildEpoch {
    private static let key = "cityDataBuild"

    static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static func applyIfNeeded(defaults: UserDefaults = .standard) {
        let current = currentBuild
        guard defaults.string(forKey: key) != current else { return }
        let root = CityPackStorageLocation.rootURL()
        if FileManager.default.fileExists(atPath: root.path) {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                AppLog.data.error("Downloaded city data could not be swept for a new build: \(error)")
                return
            }
        }
        // What the last update did no longer describes what is installed, and the new build should
        // check soon for what the repository has beyond its own bundle.
        CityDataUpdater.forgetLastCheck(in: defaults)
        defaults.set(current, forKey: key)
    }
}

// MARK: - What an update did

/// One city an update changed, with enough of the before and after to say what changed.
struct CityDataCityUpdate: Codable, Equatable, Sendable, Identifiable {
    let cityID: String
    /// The OpenStreetMap snapshot of the network now in use, `YYYY-MM-DD`.
    let snapshot: String?
    let stationsBefore: Int?
    let stationsAfter: Int
    let linesBefore: Int?
    let linesAfter: Int
    /// Lines whose name the city did not have before the update: new lines, and lines OpenStreetMap
    /// renamed. Empty when nothing was loaded to compare with.
    let addedLines: [CityDataLineName]
    /// The city went back to the data this build bundles, because the repository has it again.
    let returnedToIncluded: Bool

    var id: String { cityID }
}

/// A line's name as published, in both languages the network carries. Never converted between
/// scripts.
struct CityDataLineName: Codable, Equatable, Sendable {
    let name: String
    let nameEn: String?

    var localized: String {
        AppLocalization.isChinese ? name : nameEn ?? name
    }
}

struct CityDataSyncOutcome: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// The repository answered and nothing differed.
        case upToDate
        /// The repository answered; `updates` lists what changed and `failedCityIDs` what could
        /// not be checked or installed.
        case checked
        /// No configured origin answered.
        case unreachable
        /// This build names no origin.
        case notConfigured
    }

    let status: Status
    let checkedAt: Date
    let updates: [CityDataCityUpdate]
    let failedCityIDs: [String]
}

// MARK: - The rider's side

/// A city whose data came from an update rather than with the app.
struct DownloadedCityData: Identifiable, Equatable {
    let cityID: String
    let snapshot: String?
    let stationCount: Int
    let lineCount: Int

    var id: String { cityID }
}

/// Keeps the bundled city data in step with the repository's default branch: metro networks and
/// station packs, one set per city, from the mirrors in `Config/*.xcconfig`.
///
/// Automatic checks are the rider's to switch off, and run at most every `automaticInterval`, never
/// on a Low Data Mode network and never while a trip is being guided (a change under a moving
/// rider would redraw their map mid-ride). "Check Now" runs whenever asked.
@MainActor
@Observable
final class CityDataUpdater {
    enum Activity: Equatable {
        case idle
        case checking
    }

    static let automaticInterval: TimeInterval = 6 * 60 * 60

    private(set) var activity: Activity = .idle
    private(set) var lastOutcome: CityDataSyncOutcome?
    /// Bumped whenever the data in use changes, so whatever holds loaded networks reloads them.
    private(set) var revision = 0
    private(set) var downloaded: [DownloadedCityData] = []
    var updatesAutomatically: Bool {
        didSet { defaults.set(updatesAutomatically, forKey: Keys.automatic) }
    }

    private enum Keys {
        static let automatic = "cityDataUpdatesAutomatically"
        static let lastOutcome = "cityDataLastOutcome"
        static let lastAttempt = "cityDataLastAttempt"
    }

    @ObservationIgnored private let stationData: OfficialStationDataProviding
    @ObservationIgnored private let networks: MetroNetworkProviding
    @ObservationIgnored private let releaseRoutingGraphs: @Sendable () async -> Void
    @ObservationIgnored private let isTripUnderWay: @MainActor () -> Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(
        stationData: OfficialStationDataProviding,
        networks: MetroNetworkProviding,
        releaseRoutingGraphs: @escaping @Sendable () async -> Void,
        isTripUnderWay: @escaping @MainActor () -> Bool,
        defaults: UserDefaults = .standard
    ) {
        self.stationData = stationData
        self.networks = networks
        self.releaseRoutingGraphs = releaseRoutingGraphs
        self.isTripUnderWay = isTripUnderWay
        self.defaults = defaults
        // `bool(forKey:)`, not `as? Bool`: a value from a launch argument arrives as a string.
        updatesAutomatically = defaults.object(forKey: Keys.automatic) == nil || defaults.bool(forKey: Keys.automatic)
        lastOutcome = defaults.data(forKey: Keys.lastOutcome)
            .flatMap { try? JSONDecoder().decode(CityDataSyncOutcome.self, from: $0) }
    }

    /// An automatic check, if one is due: on launch and whenever the app comes to the front.
    func checkIfDue() {
        guard updatesAutomatically, activity == .idle, !isTripUnderWay() else { return }
        if let lastAttempt = defaults.object(forKey: Keys.lastAttempt) as? Date,
           Date().timeIntervalSince(lastAttempt) < Self.automaticInterval {
            return
        }
        Task { await run(automatic: true) }
    }

    /// The rider asked.
    func checkNow() async {
        guard activity == .idle else { return }
        await run(automatic: false)
    }

    /// Puts a city back on the data that came with the app, until the next update.
    func restoreIncluded(_ cityID: String) async {
        // Never under a check in flight, which could install the city again behind the rider.
        guard activity == .idle else { return }
        await stationData.restoreIncludedCityData(for: cityID)
        await dataChanged()
    }

    /// After something outside this updater swept the downloads (Clear Cache). The last outcome
    /// goes with them: it describes data no longer installed.
    func downloadsCleared() async {
        lastOutcome = nil
        defaults.removeObject(forKey: Keys.lastOutcome)
        await networks.invalidate(cityIDs: nil)
        await dataChanged()
    }

    nonisolated static func forgetLastCheck(in defaults: UserDefaults) {
        defaults.removeObject(forKey: Keys.lastOutcome)
        defaults.removeObject(forKey: Keys.lastAttempt)
    }

    func refreshDownloaded() async {
        var cities: [DownloadedCityData] = []
        for cityID in await stationData.downloadedCityDataIDs().sorted() {
            guard let network = await networks.network(for: cityID) else { continue }
            cities.append(DownloadedCityData(
                cityID: cityID,
                snapshot: network.sourceSnapshot,
                stationCount: network.stations.count,
                lineCount: network.lines.count
            ))
        }
        downloaded = cities
    }

    private func run(automatic: Bool) async {
        activity = .checking
        defaults.set(Date(), forKey: Keys.lastAttempt)
        let outcome = await stationData.syncCityData(automatic: automatic)
        lastOutcome = outcome
        if let data = try? JSONEncoder().encode(outcome) {
            defaults.set(data, forKey: Keys.lastOutcome)
        }
        if !outcome.updates.isEmpty {
            await dataChanged()
        }
        activity = .idle
    }

    private func dataChanged() async {
        // Graphs are memoised on city and version, and an update can change a network without
        // changing its snapshot.
        await releaseRoutingGraphs()
        revision += 1
        await refreshDownloaded()
    }
}
