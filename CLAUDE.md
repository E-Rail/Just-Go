# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

Just-Go is a universal iPhone/iPadOS transit companion (SwiftUI, iOS 18+, Swift 5 mode,
`TARGETED_DEVICE_FAMILY = "1,2"`, bundle id `com.e-rail.just-go`). It plans metro routes from a
bundled network graph, uses Apple Maps for place search and walking legs, and layers on narrowly
scoped official city data.

Its defining rule is **honesty over completeness**: missing schedules, layouts, transfer paths and
door positions are shown as unavailable rather than inferred. Most of the validator suite exists to
enforce that. When you cannot verify something, say so — do not fill the gap with a plausible guess.

## Build and verify

There are **no Xcode test targets**. The gate is Ruby suites, shell suites, validators, and two
builds. `.github/workflows/ci.yml` is the source of truth; keep them in sync.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

# Builds — Debug and Release both, warnings-as-errors is stricter than CI and worth keeping
xcodebuild build -project Just-Go.xcodeproj -scheme Just-Go \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES

for s in Scripts/validate_*.rb; do ruby "$s"; done
ruby Scripts/validate_data_rights.rb --history
ruby Scripts/import_osm_metro_geometry.rb --self-test
for t in Scripts/test_*.rb;  do ruby "$t"; done
for t in Scripts/test_*.sh;  do bash "$t"; done   # easy to forget; CI runs them
bash Scripts/check_no_legacy_map_provider.sh
git diff --check
```

**`xcodebuild` rewrites `Just-Go.xcodeproj/project.pbxproj`.** Snapshot it before any build and
restore it after, or unrelated churn lands in your commit:

```bash
cp Just-Go.xcodeproj/project.pbxproj /tmp/pbxproj.bak
# ... build ...
cp /tmp/pbxproj.bak Just-Go.xcodeproj/project.pbxproj
```

### Regenerating data

Generators are byte-for-byte deterministic and CI runs each twice and diffs. After touching
anything under `Scripts/lib/`:

```bash
ruby Scripts/generate_city_pack_manifest.rb      # packs + manifest + rights inventory
ruby Scripts/generate_universal_city_data.rb
ruby Scripts/generate_official_transit_resources.rb
ruby Scripts/generate_station_info_api.rb
```

## Traps that have actually cost time

- **Ruby is 2.6.10.** No `filter_map` (2.7+), no `Hash#except`. Use `map {}.compact` and
  `each_with_object`.
- **Coordinates are GCJ-02 everywhere the app draws.** OpenStreetMap and most open data publish
  WGS-84. Convert with `GCJ02.from_wgs84(lat, lon)` from `Scripts/lib/gcj02.rb` *before* measuring
  or matching. Unconverted coordinates land ~600 m away and produce an **empty-but-valid** import —
  a silent failure. `oss_data_validators.rb` pins this with a nearest-distance check; keep it.
- **Rights are declared three times on purpose**, and all three must agree:
  `oss_city_pack_pipeline.rb` (rights entry + per-file `rightsIDs`), `oss_data_validators.rb`
  (`expected_rights_for`), and `validate_station_info_api.rb` (`STABLE_CATALOGS`). Plus the host in
  the `oss_data_validators.rb` allowlist and the URL in `validate_runtime_data_policy.rb`
  (`expected_web_literals`). The duplication is deliberate — do not "DRY" it.
- **`BundledCityPacks`, `MetroNetworks` and `StationInfo` are folder references** in the pbxproj
  (`lastKnownFileType = folder`), so new files inside them need no project change. Adding a new
  *source* file does need four pbxproj edits.
- **One malformed station rejects an entire city pack.** `OfficialCityPackService.validatesStation`
  is all-or-nothing; a present-but-empty `stationNameEn` silently discarded Beijing's whole pack for
  months. Pack-shape bugs look like "the feature does nothing", not like an error.
- **`AppLocalization` is mandatory for user-visible text.** `validate_localizations.rb` rejects
  direct English literals in `Text(...)`, Chinese values equal to their key, and unused keys. Prefer
  `AppLocalization.text(english:simplified:traditional:)` — it needs no `.strings` edit. Literals
  containing `\(interpolation)` are skipped by the checker, as is `Text(verbatim:)`.

## Verifying UI without tap injection

This environment has **no tap or scroll injection**. Two workable approaches:

1. `ImageRenderer` for a view that needs no async loading.
2. A temporary DEBUG probe: gate `JustGoApp.body` on a `JUST_GO_DEBUG_PROBE` env var, render or query
   the real view/service, **write results to `Documents/probe.txt`** (`simctl launch --console` is
   unreliable), then read them back:

```bash
xcrun simctl install <UDID> path/to/Just-Go.app
SIMCTL_CHILD_JUST_GO_DEBUG_PROBE=1 xcrun simctl launch <UDID> com.e-rail.just-go
cat "$(xcrun simctl get_app_container <UDID> com.e-rail.just-go data)/Documents/probe.txt"
```

To see a section below the fold, temporarily reorder it to the top of the `VStack` and screenshot
with `xcrun simctl io <UDID> screenshot`. Scaling the page down renders blank — don't bother.
**Revert every probe edit before committing.**

Never diagnose a performance problem by reasoning about it. Three consecutive rounds of confident
reasoning-only perf fixes were all wrong. Use the DEBUG `MainThreadHangMonitor` and measure.

## Layout

```
Just-Go/
  App/          JustGoApp (staged launch), ContentView (tab root)
  Core/         DI container, localization, extensions
  Models/       Transit, City, Station, User domain types
  Services/     Data (city packs, catalogs), Transit (routing, providers), Map, Notifications
  ViewModels/   Map, Route
  Views/        Map, Route, Station, Profile, Onboarding, Components
  Resources/    BundledCityPacks/, MetroNetworks/, StationInfo/ — all folder references
Scripts/        importers, generators, validators, tests (plain Ruby + minitest)
Scripts/lib/    oss_city_pack_pipeline.rb, oss_data_validators.rb, gcj02.rb
DataPacks/      generated manifest, rights inventory, per-source vendored data
StationInfoAPI/ station-information directory + source rules
```

Routing lives in `BundledMetroRouteProvider` (graph search) with `RoutePlanningService` doing
enrichment on top — exits, service hours, coverage, warnings. Enrichment is where rider-facing
judgement belongs; the graph stays mechanical.

## Data licensing — read before adding any source

Every bundled byte must be redistributable, and the validators will stop you if it is not.

- **OpenStreetMap (`ODbL-1.0`)** — the only source that may be **bundled inside the app**.
  Redistribution is fine with attribution and share-alike.
- **Hong Kong (`LicenseRef-DATA-GOV-HK-1.2`)** and **Taipei (`LicenseRef-OGDL-TW-1.0`)** — bundled
  under their own terms. Taipei's attribution is **mandatory**; omitting it voids the grant
  retroactively.
- **Beijing / Shanghai / Guangzhou / Hangzhou operator content
  (`LicenseRef-External-Link-Only`)** — first/last-train and similar operator content **must not be
  committed**. Only station IDs, operator identifiers, aliases and verification dates may live in
  the repo. The content is fetched on the rider's device, cached device-only, and redistributed to
  nobody. `validate_runtime_data_policy.rb` enforces this.

Adding a live-fetch city touches ~10 places; see `memory/adding-live-fetch-city.md`.

## Conventions

- Comments explain **why**, especially where the obvious approach is wrong. Match the surrounding
  density — this codebase comments decisions, not mechanics.
- Prefer one shared rule over per-screen copies. The station sheet and transfer sheet render the
  same rows via `StationAccessPointRow`; they drifted once and shipped blank rows.
- Coverage numbers, station counts and exit counts are **pinned** in `oss_data_validators.rb`. When
  data legitimately changes, update the pins in the same commit and say why in the message.
- Report what you actually verified. If a step was skipped or a check was not run, state it.
