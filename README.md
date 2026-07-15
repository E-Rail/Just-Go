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
- Official operator landing-page links that open only after a rider taps them.
- Two bundled pilot photos: Jianguomen by Ian Holton under CC BY 2.0, and Hong Kong Central by
  Qqhhss under CC0 1.0.
- Private station images imported from Photos or Files, normalized and stored only on-device.

The current bundled coverage is:

| City | Network | Matched | Accessibility | Live arrivals | Layout links | Media | Verified transfers |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Beijing | 444 | 444 | 0 | 0 | 0 | 1 | 0 |
| Hong Kong | 162 | 162 | 98 | 162 | 98 | 1 | 0 |

The other 56 catalog cities are source-pending. Of those, 44 retain an attributed network
baseline and 12 are catalog-only. Included metro topology powers rail routing independently of
optional city-pack details; Apple Maps supplies place search and walking legs.
No current city pack is presented as downloadable. Macau remains source-pending and exposes only
the official Macao Light Rapid Transit homepage as a tap-only operator link.

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
ruby Scripts/validate_data_rights.rb
ruby Scripts/validate_city_packs.rb
```

See [DataPacks/README.md](DataPacks/README.md), [DataPacks/RIGHTS.md](DataPacks/RIGHTS.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for schema, provenance, checksums, and exact
license treatment.

## Privacy And Network Use

- Personal station media stays in Application Support, is excluded from backup, and is never
  used to infer routing, accessibility, indoor paths, or doors.
- External operator resources open only after a user action. JustGo does not render, prefetch,
  cache, or count those pages as offline content.
- Hong Kong live-arrival requests contact `rt.data.gov.hk` with official station and line
  identifiers. They do not include personal media or the rider's location.
- The app links to the published [Privacy Policy](https://e-rail.github.io/justgo/docs/privacy/)
  and [Terms of Service](https://e-rail.github.io/justgo/docs/terms/).

## License

JustGo's original software source is MIT licensed. Third-party data and media are not granted
under MIT; their terms are recorded in `DataPacks/rights_inventory.json` and
`THIRD_PARTY_NOTICES.md`.
