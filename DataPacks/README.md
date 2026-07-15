# OSS-Safe City Data Packs

`DataPacks/manifest.json` is the schema-v2 catalog for app-bundled city packs. It is not a
download catalog: every `downloadURL` is `null`, and the only available packs point to
`JustGo/Resources/BundledCityPacks/1100.json` and `8100.json` through `bundledResource`.
The other 56 catalog cities are intentionally `source_pending`.
Macau (`8200`) additionally exposes the official Macao Light Rapid Transit homepage as a
catalog-level, tap-only link; it remains non-downloadable and has no copied operator dataset.

## Build

Run the standard-library Ruby pipeline from the repository root:

```sh
ruby Scripts/generate_city_pack_manifest.rb
ruby Scripts/validate_data_rights.rb
ruby Scripts/validate_runtime_data_policy.rb
ruby Scripts/validate_city_packs.rb
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

## Schema V2

Each bundled pack contains `schemaVersion`, `cityID`, `version`, `generatedAt`, `rightsIDs`,
`capabilities`, `coverage`, and `stations`. Hong Kong also includes `destinationNames` for
official heavy-rail destination codes.

Station IDs are the raw IDs from the corresponding canonical `MetroNetworks` resource.
Every station record includes names, aliases, accessibility, an empty `schedules` array,
facilities, external landing resources, licensed media, and live-arrival references.

Coverage metrics always use the canonical network station count as `total`:

- `matchedStations`: canonical stations represented by a pack record.
- `accessibility`: represented stations with official accessibility data.
- `staticSchedules`: represented stations with static schedule rows; always zero here.
- `liveArrivals`: represented stations with an official API lookup reference.
- `externalLayouts`: represented stations with an allowlisted official layout landing page.
- `licensedMedia`: represented stations with a validated, locally bundled licensed image.
- `verifiedTransferContexts`: on-site verified transfer contexts; always zero here.

Current exact coverage is:

| City | Network | Matched | Accessibility | Static schedules | Live arrivals | External layouts | Licensed media | Verified transfers |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Beijing | 444 | 444 | 0 | 0 | 0 | 0 | 1 | 0 |
| Hong Kong | 162 | 162 | 98 | 0 | 162 | 98 | 1 | 0 |

Racecourse is bound explicitly to canonical station `5100239bb9315f24`, accessibility group
`70`, and realtime code `EAL/RAC` using the reviewed MTR realtime dictionary. The compatibility
mapping for `Hoi Wong Road / 海皇路` keeps the canonical `Tuen Mun Swimming Pool` ID and geometry
and retains the former bilingual names as aliases. The barrier-free snapshot contains 99 source
station groups; 98 resolve to canonical heavy-rail stations.

See `RIGHTS.md`, `rights_inventory.json`, and `sources/8100/metadata.json` for provenance,
terms, checksums, and attribution.
The generated `DataLicenseMetadata` record also pins the snapshot date, exact attribution,
terms URL, and reviewed redistribution-evidence URL for the custom DATA.GOV.HK license.
