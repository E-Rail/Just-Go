import Foundation

/// The app consumes its own published Station Information API rather than reaching into DataPacks:
/// a bundled mirror of `directory.json` (which source covers each station, with which key) and
/// `sources.json` (which cities are served, and how). Adding a city is a data change. See
/// `StationInfoAPI/API.md`; the copies are written by `Scripts/generate_station_info_api.rb` and
/// diff-checked in CI.
struct StationDirectoryEntry: Sendable, Equatable {
    let stationID: String
    let name: String
    let nameEn: String?
    let aliases: [String]
    /// A source identifier from the registry, e.g. `beijingSubwayOnline`, `shanghaiMetroOnline`.
    let source: String
    /// The source's primary station key. For sources keyed per line this is the first line key.
    let externalStationID: String
    /// Every key the source uses for this station. One per line it serves. `[externalStationID]`
    /// for sources without per-line keys.
    let lineStationIDs: [String]
    let sourcePageURL: String?
}

final class StationInformationDirectory: Sendable {
    private struct Contents: Sendable {
        /// Sources whose data is fetched live on the rider's device. `bundledDataset` sources (Hong
        /// Kong) are served from the city pack and are intentionally excluded from the online path.
        let onDeviceFetchSources: Set<String>
        /// City IDs a `stable` source covers. Used to answer "does this city have station info"
        /// the same way the API's `sources.json` declares it, rather than hard-coding city IDs.
        let servedCityIDs: Set<String>
        let entriesByStationID: [String: StationDirectoryEntry]
    }

    /// Parsed on first use, not on construction: `directory.json` is 455 KB and 1,603 entries, and
    /// this type is built at launch on the main thread. The first caller is a route plan or a
    /// station sheet, both off the main actor. The lock makes the type honestly `Sendable`.
    private let bundle: Bundle
    private let lock = NSLock()
    nonisolated(unsafe) private var loaded: Contents?

    private var contents: Contents {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let parsed = Self.parse(bundle: bundle)
        loaded = parsed
        return parsed
    }

    private var onDeviceFetchSources: Set<String> { contents.onDeviceFetchSources }
    private var servedCityIDs: Set<String> { contents.servedCityIDs }
    private var entriesByStationID: [String: StationDirectoryEntry] { contents.entriesByStationID }

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    private static func parse(bundle: Bundle) -> Contents {
        let directory = Self.loadJSONObject(named: "directory", bundle: bundle)
        let sources = Self.loadJSONObject(named: "sources", bundle: bundle)

        var onDeviceFetch: Set<String> = []
        var servedCities: Set<String> = []
        if let registry = sources?["sources"] as? [String: Any] {
            for (sourceID, value) in registry {
                guard let source = value as? [String: Any] else { continue }
                let stable = (source["status"] as? String) == "stable"
                if (source["access"] as? [String: Any])?["kind"] as? String == "onDeviceFetch" {
                    onDeviceFetch.insert(sourceID)
                }
                if stable, let cityID = source["cityID"] as? String {
                    servedCities.insert(cityID)
                }
            }
        }

        var entries: [String: StationDirectoryEntry] = [:]
        if let stations = directory?["stations"] as? [String: Any] {
            entries.reserveCapacity(stations.count)
            for (stationID, value) in stations {
                guard let entry = value as? [String: Any],
                      let name = entry["name"] as? String,
                      let sourceMap = entry["sources"] as? [String: Any],
                      let (source, reference) = sourceMap.first,
                      let reference = reference as? [String: Any] else { continue }

                let lineStationIDs = (reference["lineStationIDs"] as? [String]) ?? []
                let externalStationID = (reference["externalStationID"] as? String)
                    ?? lineStationIDs.first
                    ?? ""
                entries[stationID] = StationDirectoryEntry(
                    stationID: stationID,
                    name: name,
                    nameEn: entry["nameEn"] as? String,
                    aliases: (entry["aliases"] as? [String]) ?? [],
                    source: source,
                    externalStationID: externalStationID,
                    lineStationIDs: lineStationIDs.isEmpty ? [externalStationID] : lineStationIDs,
                    sourcePageURL: reference["sourcePageURL"] as? String
                )
            }
        }
        return Contents(
            onDeviceFetchSources: onDeviceFetch,
            servedCityIDs: servedCities,
            entriesByStationID: entries
        )
    }

    /// The routing entry for a canonical station, if any source covers it live.
    func onlineEntry(forStationID stationID: String) -> StationDirectoryEntry? {
        guard let entry = entriesByStationID[Self.canonicalStationID(stationID)],
              onDeviceFetchSources.contains(entry.source),
              !entry.externalStationID.isEmpty else { return nil }
        return entry
    }

    /// Stations from the bundled metro network carry `network-<cityID>-<canonicalID>`, while the
    /// directory is keyed by the bare canonical ID, as the packs are. Anything else is already
    /// canonical.
    private static func canonicalStationID(_ value: String) -> String {
        MetroStationIdentifier.canonical(value)
    }

    /// Whether a city has any station-information source, matching how `sources.json` declares it.
    func servesStationInformation(cityID: String) -> Bool {
        servedCityIDs.contains(cityID)
    }

    /// How to ask the operator about this station, or nil when none covers it. One mapping for the
    /// route and the station page, so a station cannot resolve differently on the two.
    func officialReference(
        forStationID stationID: String,
        name: String,
        nameEn: String?
    ) -> OfficialStationInformationReference? {
        guard let entry = onlineEntry(forStationID: stationID) else { return nil }
        let expectedNames = ([name, nameEn, entry.name, entry.nameEn].compactMap { $0 }) + entry.aliases
        switch entry.source {
        case "beijingSubwayOnline":
            return .beijing(externalStationID: entry.externalStationID, expectedNames: expectedNames)
        case "shanghaiMetroOnline":
            return .shanghai(lineStationIDs: entry.lineStationIDs, expectedNames: expectedNames)
        case "guangzhouMetroOnline":
            return .guangzhou(stationShowCode: entry.externalStationID, expectedNames: expectedNames)
        case "hangzhouMetroOnline":
            // Hangzhou keys service times per operator station record, and 火车东站 is published
            // as two, so the reference carries every code rather than the representative alone.
            return .hangzhou(
                stationCodes: entry.lineStationIDs.isEmpty
                    ? [entry.externalStationID]
                    : entry.lineStationIDs,
                expectedNames: expectedNames
            )
        default:
            return nil
        }
    }

    private static func loadJSONObject(named name: String, bundle: Bundle) -> [String: Any]? {
        guard let url = bundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "StationInfo"
        ), let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
