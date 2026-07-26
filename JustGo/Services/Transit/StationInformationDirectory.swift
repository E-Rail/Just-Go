import Foundation

/// The app consumes its own published Station Information API instead of reaching into DataPacks:
/// it bundles a mirror of `directory.json` (which source covers each station, and with which key)
/// and `sources.json` (which cities are served, and how), and routes from those. Adding a city is
/// then a data change — regenerate the directory — with no routing code to touch.
///
/// See `StationInfoAPI/API.md`. The bundled copies are written by
/// `Scripts/generate_station_info_api.rb` and CI diff-checks them against the published contract.
struct StationDirectoryEntry: Sendable, Equatable {
    let stationID: String
    let name: String
    let nameEn: String?
    let aliases: [String]
    /// A source identifier from the registry, e.g. `beijingSubwayOnline`, `shanghaiMetroOnline`.
    let source: String
    /// The source's primary station key. For sources keyed per line this is the first line key.
    let externalStationID: String
    /// Every key the source uses for this station — one per line it serves. `[externalStationID]`
    /// for sources without per-line keys.
    let lineStationIDs: [String]
    let sourcePageURL: String?
}

final class StationInformationDirectory: Sendable {
    /// Sources whose data is fetched live on the rider's device. `bundledDataset` sources (Hong
    /// Kong) are served from the city pack and are intentionally excluded from the online path.
    private let onDeviceFetchSources: Set<String>
    /// City IDs a `stable` source covers — used to answer "does this city have station info" the
    /// same way the API's `sources.json` declares it, rather than hard-coding city IDs.
    private let servedCityIDs: Set<String>
    private let entriesByStationID: [String: StationDirectoryEntry]

    init(bundle: Bundle = .main) {
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
        onDeviceFetchSources = onDeviceFetch
        servedCityIDs = servedCities

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
        entriesByStationID = entries
    }

    /// The routing entry for a canonical station, if any source covers it live.
    func onlineEntry(forStationID stationID: String) -> StationDirectoryEntry? {
        guard let entry = entriesByStationID[Self.canonicalStationID(stationID)],
              onDeviceFetchSources.contains(entry.source),
              !entry.externalStationID.isEmpty else { return nil }
        return entry
    }

    /// Stations resolved from the bundled metro network carry a synthesised
    /// `network-<cityID>-<canonicalID>` identifier, while the directory — like the city packs — is
    /// keyed by the bare canonical ID. Every station opened from the map arrives in that
    /// synthesised form, so without this the lookup missed for all of them and the live
    /// first/last surface silently fell back to the "official page available" placeholder.
    /// Anything else is already canonical.
    private static func canonicalStationID(_ value: String) -> String {
        let prefix = "network-"
        guard value.hasPrefix(prefix),
              let citySeparator = value.dropFirst(prefix.count).firstIndex(of: "-") else {
            return value
        }
        return String(value[value.index(after: citySeparator)...])
    }

    /// Whether a city has any station-information source, matching how `sources.json` declares it.
    func servesStationInformation(cityID: String) -> Bool {
        servedCityIDs.contains(cityID)
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
