# JustGo

[![Website](https://img.shields.io/badge/website-e--rail.github.io%2Fjustgo-2ea44f?logo=githubpages&logoColor=white)](https://e-rail.github.io/justgo)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-lightgrey?logo=apple)](https://e-rail.github.io/justgo)
[![iOS](https://img.shields.io/badge/iOS-18.0%2B-black?logo=apple&logoColor=white)](https://www.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/software-MIT-green.svg)](LICENSE)

English | [中文](README-zh.md)

JustGo is an iPhone and iPad transit companion for route planning, station context, and honest
data confidence. It combines bundled metro routing, Apple Maps place search and walking legs,
attributed metro geometry, and narrowly
scoped official city data. Missing schedules, layouts, transfer paths, and door positions are
shown as unavailable rather than inferred.

## What Ships

- Apple Maps place search, walking directions, and map rendering.
- A 58-city catalog with 46 canonical metro-network baselines, separately attributed to
  OpenStreetMap under ODbL 1.0; 12 entries are catalog-only.
- Two included offline city-data baselines: Beijing and Hong Kong.
- Hong Kong MTR and Light Rail station, route, accessibility, and live-reference data from
  DATA.GOV.HK under its custom reuse terms.
- Official Hong Kong live arrivals from the government transport API, with timeout, cache,
  request-coalescing, and rate-limit handling.
- A bundled official-resource directory for all 58 catalog cities, with 770 reviewed links to
  rider-facing maps, travel information, accessibility resources, and help pages.
- Two bundled pilot photos: Jianguomen by Ian Holton under CC BY 2.0, and Hong Kong Central by
  Qqhhss under CC0 1.0.
- Private station images imported from Photos or Files, normalized and stored only on-device.

The current bundled coverage is:

| City | Network | Matched | Accessibility | Live arrivals | External maps | Media | Verified transfers |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Beijing | 444 | 444 | 0 | 0 | 0 | 1 | 0 |
| Hong Kong | 162 | 162 | 98 | 162 | 0 | 1 | 0 |

The other 56 city packs are source-pending. Of those cities, 44 retain an attributed network
baseline and 12 are catalog-only. Included metro topology powers rail routing independently of
optional city-pack details; Apple Maps supplies place search and walking legs. No current city
pack is presented as downloadable.

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

Every resource opens inside JustGo after a rider taps it. The app stores factual URL metadata only:
pages use an ephemeral WebKit session, while PDFs and images use memory-only native viewers with a
50 MB limit. Beijing's exact station pages receive a phone reader stylesheet so train times, exits,
nearby places, and facilities fit the Station Detail flow without opening Safari. JustGo does not
prefetch, persist, or redistribute operator content. The operator receives the user-initiated
request and may process network information under its own policy. Non-station resources retain an
explicit browser fallback when they cannot render in the app; exact Beijing station information
remains in JustGo and offers an in-app retry instead.

Beijing station pages follow the same boundary. JustGo does not call the undocumented station
detail API, prefetch pages when Station Detail opens, or extract operator schedules, exits,
facilities, coordinates, images, or text into native/offline models.

## Indoor Guidance

The indoor graph, checkpoint scanner, persistence, and Live Go integration remain in the app
for future verified data. This release contains zero verified transfer contexts. It does not
claim universal 3D maps, indoor routes, boarding cars, door positions, or transfer corridors.
When verified guidance is unavailable, Live Go keeps the normal transfer step and says so.

## Setup

1. Clone the repository.
2. Open `JustGo.xcodeproj` in Xcode.
3. Build the `JustGo` scheme.

Release builds use the included baseline unless a first-party city-pack origin is configured
through the build settings. Release does not fall back to GitHub, jsDelivr, or Wikimedia.
Debug builds may use an explicitly configured development origin. A first-party mainland mirror
can be supplied through `CITY_PACK_SECRET_MAINLAND_MIRROR_URL`; no mirror is configured here.

Regenerate and validate data from the vendored, reviewed inputs:

```sh
ruby Scripts/generate_city_pack_manifest.rb
ruby Scripts/import_beijing_station_information.rb --refresh
ruby Scripts/generate_official_transit_resources.rb
ruby Scripts/validate_data_rights.rb
ruby Scripts/validate_city_packs.rb
ruby Scripts/validate_official_transit_resources.rb
```

See [DataPacks/README.md](DataPacks/README.md), [DataPacks/RIGHTS.md](DataPacks/RIGHTS.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for schema, provenance, checksums, and exact
license treatment.

## Privacy And Network Use

- Personal station media stays in Application Support, is excluded from backup, and is never
  used to infer routing, accessibility, indoor paths, or doors.
- External operator resources render inside non-persistent in-app page and document viewers only
  after a user action. JustGo does not prefetch, persist, redistribute, or count them as offline
  content. The operator receives the request; unsupported downloads remain an explicit browser
  fallback controlled by the rider. Beijing station-information pages do not offer that fallback.
- Beijing station and reviewed context pages are requested from their recorded official provider
  only after the rider taps. Page-controlled third-party services may receive ordinary web-request
  metadata. JustGo does not parse or persist the page content.
- Hong Kong live-arrival requests contact `rt.data.gov.hk` with official station and line
  identifiers. They do not include personal media or the rider's location.
- The app links to the published [Privacy Policy](https://e-rail.github.io/justgo/docs/privacy/)
  and [Terms of Service](https://e-rail.github.io/justgo/docs/terms/).

## License

JustGo's original software source is MIT licensed. Third-party data and media are not granted
under MIT; their terms are recorded in `DataPacks/rights_inventory.json` and
`THIRD_PARTY_NOTICES.md`.
