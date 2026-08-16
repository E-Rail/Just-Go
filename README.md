# Just-Go

[![Website](https://img.shields.io/badge/website-e--rail.github.io%2Fjust--go-2ea44f?logo=githubpages&logoColor=white)](https://e-rail.github.io/just-go)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-lightgrey?logo=apple)](https://e-rail.github.io/just-go)
[![iOS](https://img.shields.io/badge/iOS-18.0%2B-black?logo=apple&logoColor=white)](https://www.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/software-MIT-green.svg)](LICENSE)

English | [中文](README-zh.md)

Just-Go is an iPhone and iPad transit companion for route planning, station context, and honest
data confidence. Rail routing runs on a bundled network graph, so it works underground and with no
signal. Apple Maps supplies place search and walking legs, and narrowly scoped official city data
is layered on top. Missing schedules, layouts, transfer paths and door positions are shown as
unavailable rather than inferred.

## What Ships

- Offline rail routing across a 58-city catalog. 53 of those cities carry a canonical
  metro-network baseline, separately attributed to OpenStreetMap under ODbL 1.0, covering 6,718
  stations. The remaining 5 are catalog-only.
- Apple Maps place search, walking directions, and map rendering.
- Station accessibility data for 582 stations across 14 cities, from each city's own open data.
- Hong Kong MTR and Light Rail station, route, accessibility, and live-reference data from
  DATA.GOV.HK under its custom reuse terms.
- Official Hong Kong live arrivals from the government transport API, with timeout, cache,
  request-coalescing, and rate-limit handling.
- Native three-category station information for 416 reviewed Beijing Subway stations
  (First / Last, Exits, Facilities) and all 162 Hong Kong stations
  (Live Trains, Exits, Facilities).
- A bundled official-resource directory for all 58 catalog cities, with 770 reviewed links to
  rider-facing maps, travel information, accessibility resources, and help pages.
- Optional online enrichment where a Baidu Maps key is configured: ticket fare, measured transfer
  corridor lengths, first and last train times, a taxi estimate beside a last-train warning, and
  cycling and e-bike routing for the first and last mile. None of it is bundled, cached to disk or
  committed, and the app plans routes without it.

Bundled station accessibility coverage, by city:

| City | Network stations | With accessibility data |
| --- | ---: | ---: |
| Xi'an | 247 | 164 |
| Taipei | 151 | 118 |
| Hong Kong | 162 | 98 |
| Shanghai | 471 | 56 |
| Beijing | 444 | 43 |
| Guangzhou | 414 | 37 |
| Shenzhen | 372 | 19 |
| Nanjing | 210 | 11 |
| Hangzhou | 270 | 10 |
| Chengdu | 396 | 9 |
| Wuhan | 293 | 7 |
| Tianjin | 239 | 5 |
| Chongqing | 273 | 3 |
| Suzhou | 235 | 2 |

The other 44 catalog cities are source-pending for station data. Bundled metro topology powers
rail routing independently of optional city-pack details. No current city pack is presented as
downloadable.

## Official Resource Directory

The link catalog is independent of city packs: 43 cities have at least one verified official
resource and 15 carry an explicit dated no-resource review. Its 770 links comprise 275 map links,
447 travel links, 6 accessibility links, and 42 help links. Links do not count as bundled maps,
offline content, or verified transfer guidance.

Every one of Beijing's 444 canonical app stations has a reviewed station-information state.
There are 418 exact pages: 416 current Beijing Subway directory bindings, the operator's retained
legacy page for the temporarily closed Bajiao Amusement Park station, and the official 12306
Beijing North station guide. Of the remaining stations, 18 have route- or operator-specific
official context, 3 are not open for passenger service, and 5 are not current passenger stops.
Seven newer stations in the official directory are not silently attached to stale OSM IDs because
they do not yet have canonical entries in the bundled network snapshot.

Hong Kong contributes 1 system map, 98 distinct Location Maps, 98 distinct Station Layouts, and
14 distinct Light Rail Street Maps from the official MTR indexes, plus current rider-service
pages. Macau remains source-pending for structured data but links to its official route, fare,
and customer-service pages.

Station Detail presents exactly three compact information categories. For 416 reviewed Beijing
Subway station IDs, it requests first/last trains, exits, nearby text, and facilities directly from
the operator when the detail page opens, validates the returned station identity, and renders the
text as native rows. The response uses an ephemeral session, a 1 MB cap, a five-minute memory cache,
and is never written to disk or copied into a city pack. The exact official station page remains an
in-app source and fallback. This endpoint is not a published public API and no compatible content
reuse license was found, so production distribution still requires operator or legal review.

Hong Kong uses the same three-category structure for all 162 stations, with Live Trains replacing
Beijing's First / Last label. Live train rows come from the official government transport API;
exits and facilities use the included DATA.GOV.HK barrier-free snapshot where available, including
verified unavailable states. Other reviewed pages, PDFs, and images open inside Just-Go only after a
rider taps them: pages use a non-persistent WebKit session, while documents use memory-only native
viewers with a 50 MB limit. Just-Go does not persist or redistribute operator content. Unsupported
non-station resources retain an explicit browser fallback.

## Indoor Guidance

Just-Go does not do indoor navigation. The indoor graph, step planner, checkpoint scanner and
their Live Go integration were removed rather than kept dormant: no verified source ever
materialised, so every entry point was unreachable and the camera permission promised a scanner
no rider could open. Just-Go claims no 3D maps, indoor routes, boarding cars, door positions, or
transfer corridors. On a transfer, Live Go shows the station, any official operator links, and
tells the rider to follow station signs.

What it does show comes from official open data: exits and entrances where a city publishes them.
Corridor lengths between platforms come from an online routing provider when one is configured,
and are shown as a distance rather than a path.

## Setup

1. Clone the repository.
2. Open `Just-Go.xcodeproj` in Xcode.
3. Build the `Just-Go` scheme.

Release builds use the included baseline unless a first-party city-pack origin is configured
through the build settings. Release does not fall back to GitHub, jsDelivr, or Wikimedia.
Debug builds may use an explicitly configured development origin. A first-party mainland mirror
can be supplied through `CITY_PACK_SECRET_MAINLAND_MIRROR_URL`; no mirror is configured here.

Regenerate and validate data from the vendored, reviewed inputs:

```sh
ruby Scripts/generate_city_pack_manifest.rb
ruby Scripts/import_beijing_station_information.rb --refresh
ruby Scripts/generate_official_transit_resources.rb
ruby Scripts/generate_universal_city_data.rb
ruby Scripts/validate_data_rights.rb
ruby Scripts/validate_city_packs.rb
ruby Scripts/validate_official_transit_resources.rb
ruby Scripts/validate_universal_city_data.rb
```

Developers consuming Just-Go's data can use the Universal City Data Format.
[`DataPacks/universal/`](DataPacks/universal/) publishes all 58 cities in one versioned,
integrity-indexed JSON schema documented in
[DataPacks/UNIVERSAL_FORMAT.md](DataPacks/UNIVERSAL_FORMAT.md).

See [DataPacks/README.md](DataPacks/README.md), [DataPacks/RIGHTS.md](DataPacks/RIGHTS.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for schema, provenance, checksums, and exact
license treatment.

## Privacy And Network Use

- Personal station media stays in Application Support, is excluded from backup, and is never
  used to infer routing, accessibility, indoor paths, or doors.
- External operator resources render inside non-persistent in-app page and document viewers only
  after a user action. Just-Go does not prefetch, persist, redistribute, or count them as offline
  content. The operator receives the request; unsupported downloads remain an explicit browser
  fallback controlled by the rider.
- Opening one of the 416 natively supported Beijing station details sends its reviewed opaque
  station ID to `www.bjsubway.com`. Just-Go displays selected response text, does not send it to a
  Just-Go server, and keeps only a device-local, backup-excluded copy of the last good snapshot for
  offline access, served clearly labeled as cached and deletable via Settings → Clear Cache.
  Opening the exact source page may also contact provider-selected third-party web services.
- Hong Kong live-arrival requests contact `rt.data.gov.hk` with official station and line
  identifiers. They do not include personal media or the rider's location.
- The app links to the published [Privacy Policy](https://e-rail.github.io/just-go/docs/privacy/)
  and [Terms of Service](https://e-rail.github.io/just-go/docs/terms/).

## License

Just-Go's original software source is MIT licensed. Third-party data and media are not granted
under MIT; their terms are recorded in `DataPacks/rights_inventory.json` and
`THIRD_PARTY_NOTICES.md`.
