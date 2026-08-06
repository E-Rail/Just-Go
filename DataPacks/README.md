# OSS-Safe City Data Packs

`DataPacks/manifest.json` is the schema-v2 catalog for app-bundled city packs. It is not a
download catalog: every `downloadURL` is `null`, and the only available packs point to
`Just-Go/Resources/BundledCityPacks/1100.json` and `8100.json` through `bundledResource`.
The other 56 catalog cities are intentionally `source_pending`.
The separate official-resource catalog exposes reviewed user-initiated resources without changing
a city's pack status or copying an operator dataset.

## Build

Run the standard-library Ruby pipeline from the repository root:

```sh
ruby Scripts/generate_city_pack_manifest.rb
ruby Scripts/import_beijing_station_information.rb --refresh
ruby Scripts/generate_official_transit_resources.rb
ruby Scripts/validate_data_rights.rb
ruby Scripts/validate_runtime_data_policy.rb
ruby Scripts/validate_city_packs.rb
ruby Scripts/validate_official_transit_resources.rb
ruby Scripts/import_licensed_station_media.rb
```

The first command uses the already-vendored files in `sources/8100`. Pass
`--refresh-sources --snapshot-dir /private/tmp` only when intentionally replacing all four
snapshots from the reviewed local inputs. The build timestamp and version are constants, JSON
objects and arrays have stable ordering, and repeated builds from identical inputs are
byte-for-byte identical. The same pipeline generates the bundled `THIRD_PARTY_NOTICES.md`
from the reviewed rights and media records so human-readable attribution cannot drift.

`Scripts/import_licensed_station_media.rb` verifies the bundled pilot checksums, dimensions, and
absence of EXIF/XMP/IPTC metadata without networking. Its explicit `--refresh` mode is a
developer-only Commons importer; it verifies source-page metadata and original SHA-1 before
re-encoding, and refuses any output that differs from the reviewed checksum.

`DataPacks/packs` is retired and must not contain tracked files. Binary station maps,
operator timetable images, scraped schedules, and operator-derived Beijing station facts are
not part of this baseline.

## Official Resource Catalog

`official_transit_resources.json` is a deterministic bundled catalog of factual link metadata,
independent of city packs. It contains one dated review record for every one of the 58 catalog
cities. The current output has 770 links: 275 maps, 447 travel resources, 6 accessibility
resources, and 42 help resources. Forty-three cities have verified links; 15 have an explicit
`noVerifiedOfficialResource` result.

Beijing's refresh-only importer maps the official directory to canonical OSM station IDs with
exact names and four reviewed aliases. It emits 416 current station bindings, one reviewed legacy
station page, one reviewed 12306 station guide, 28 canonical source gaps, 27 Beijing Subway
direct-page gaps, and only a count for seven source-only stations. All 444 canonical app stations
receive an explicit state: 418 exact pages, 18 official-context-only records, 3 stations not open
for passenger service, and 5 points without current passenger service. No source-only station is
attached to an invented canonical ID. The committed output is factual URL/ID metadata only; it
contains no operator schedules, facilities, exits, coordinates, images, timetable data, or page
text. The 416 reviewed opaque operator IDs are also the allowlist for transient native
station-information requests.

Hong Kong URL metadata is refreshed only by an intentional developer command:

```sh
ruby Scripts/import_hong_kong_official_resources.rb --refresh
```

The importer parses the official MTR System Map and Light Rail Street Map indexes, maps their
links to 162 canonical station records through explicit bindings, and stores no PDF content. The
generated catalog exposes 197 distinct heavy-rail PDFs and 14 distinct Light Rail PDFs. Normal
generation and CI are offline and read the reviewed snapshot.

Runtime code trusts links and Beijing provider references only from this bundled catalog.
City-pack `externalResources` fields remain decodable for schema-v2 compatibility but are ignored,
and downloaded packs cannot inject URLs or online station IDs. Opening one of the 416 supported
Beijing Station Detail records performs a fixed-host, fixed-path request and displays selected
first/last, exit, and facility text in native rows. Responses are identity-checked, capped at
1 MB, cached in memory for 30 minutes, and kept as a device-local, backup-excluded last-good
snapshot for offline access — served labeled as cached only when the service is unreachable,
and deleted by Settings → Clear Cache and the data-rights epoch cleanup (see RIGHTS.md). All
other reviewed pages use a
non-persistent WebKit session after a user tap; reviewed PDFs and images use memory-only native
viewers with a 50 MB limit. An unsupported resource can leave the app only through an explicit
rider-selected browser fallback.

## Universal Format

`universal/` republishes every city as one self-contained JSON document in a single
versioned schema for external developers — network graph, reviewed station details,
official resources, coverage, and rights, with an integrity index. Generated by
`Scripts/generate_universal_city_data.rb`, validated by
`Scripts/validate_universal_city_data.rb`, documented in
[UNIVERSAL_FORMAT.md](UNIVERSAL_FORMAT.md). These files are repository artifacts; the app
does not bundle them.

## Schema V2

Each bundled pack contains `schemaVersion`, `cityID`, `version`, `generatedAt`, `rightsIDs`,
`capabilities`, `coverage`, and `stations`. Hong Kong also includes `destinationNames` for
official heavy-rail destination codes.

Station IDs are the raw IDs from the corresponding canonical `MetroNetworks` resource.
Every station record includes names, aliases, accessibility, an empty `schedules` array,
facilities, compatibility-only external resource fields, licensed media, and live-arrival
references.

Coverage metrics always use the canonical network station count as `total`:

- `matchedStations`: canonical stations represented by a pack record.
- `accessibility`: represented stations with official accessibility data.
- `staticSchedules`: represented stations with static schedule rows; always zero here.
- `liveArrivals`: represented stations with an official API lookup reference.
- `externalLayouts`: always zero. Operator hyperlinks are counted only in the separate official
  resource catalog and never as included pack coverage.
- `licensedMedia`: represented stations with a validated, locally bundled licensed image.
- `verifiedTransferContexts`: on-site verified transfer contexts; always zero here.

Current exact coverage is:

| City | Network | Matched | Accessibility | Static schedules | Live arrivals | External layouts | Licensed media | Verified transfers |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Beijing | 444 | 444 | 0 | 0 | 0 | 0 | 1 | 0 |
| Hong Kong | 162 | 162 | 98 | 0 | 162 | 0 | 1 | 0 |

Racecourse is bound explicitly to canonical station `5100239bb9315f24`, accessibility group
`70`, and realtime code `EAL/RAC` using the reviewed MTR realtime dictionary. The compatibility
mapping for `Hoi Wong Road / 海皇路` keeps the canonical `Tuen Mun Swimming Pool` ID and geometry
and retains the former bilingual names as aliases. The barrier-free snapshot contains 99 source
station groups; 98 resolve to canonical heavy-rail stations.

See `RIGHTS.md`, `rights_inventory.json`, and `sources/8100/metadata.json` for provenance,
terms, checksums, and attribution.
The generated `DataLicenseMetadata` record also pins the snapshot date, exact attribution,
terms URL, and reviewed redistribution-evidence URL for the custom DATA.GOV.HK license.
