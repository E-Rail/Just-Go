<p align="center">
  <img src="http://just-go.com.cn/assets/icon.png" width="128" height="128" alt="Just-Go app icon">
</p>

<h1 align="center">Just-Go</h1>

<p align="center">
  <strong>Metro trips planned on your phone, underground, with no guesswork.</strong><br>
  A transit companion for iPhone and iPad, covering the rail networks of 53 cities.
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/jYbwrfAa"><img src="https://img.shields.io/badge/TestFlight-join%20the%20beta-0D96F6?logo=apple&logoColor=white" alt="Join the TestFlight beta"></a>
  <a href="http://just-go.com.cn"><img src="https://img.shields.io/badge/website-just--go.com.cn-2ea44f" alt="Website: just-go.com.cn"></a>
  <img src="https://img.shields.io/badge/iOS-18.0%2B-black?logo=apple&logoColor=white" alt="iOS 18.0 or later">
  <img src="https://img.shields.io/badge/iPhone%20%C2%B7%20iPad-supported-lightgrey?logo=apple" alt="iPhone and iPad">
  <a href="LICENSE"><img src="https://img.shields.io/badge/software-GPL--3.0-green" alt="Software licence: GPL-3.0"></a>
</p>

<p align="center">English | <a href="README-zh.md">中文</a></p>

| Map | Routes | Route details | Guidance | Station |
| :-: | :-: | :-: | :-: | :-: |
| <img src="http://just-go.com.cn/assets/screenshots/map.png" width="160" alt="The metro map"> | <img src="http://just-go.com.cn/assets/screenshots/results.png" width="160" alt="Route results"> | <img src="http://just-go.com.cn/assets/screenshots/detail.png" width="160" alt="A route's details"> | <img src="http://just-go.com.cn/assets/screenshots/guiding.png" width="160" alt="Step-by-step guidance"> | <img src="http://just-go.com.cn/assets/screenshots/station.png" width="160" alt="A station's page"> |

## Why Just-Go

| | |
| --- | --- |
| 🚇 **Works with no signal**<br>Rail routes are planned on the phone, from a metro network that ships inside the app. | 🧭 **Guidance that follows you**<br>Steps move on by location and by time, and each says whether it was located or estimated. The step under way stays on the Lock Screen and in the Dynamic Island. |
| 🚉 **Know the station before you arrive**<br>First and last trains straight from the operator in Beijing, Shanghai, Guangzhou and Hangzhou, with exits and facilities in Beijing and Shanghai. In Hong Kong: live trains, exits and facilities. 1,686 stations in all. | ♿ **Step-free when you need it**<br>Ask for wheelchair access, an elevator, or no stairs, and every plan follows it. Accessibility data covers 603 stations in 14 cities. |
| 🌙 **Never miss the last train**<br>The latest moment a trip can start and still make every train, with a reminder. Shown only where the operator publishes first and last trains for every ride. | 🔍 **Honest about what it knows**<br>A missing timetable, station layout, transfer path or door position is shown as unavailable, never guessed. |
| 📱 **Made for every screen**<br>iPhone, iPad and iPhone Duo, in English, 简体中文 and 繁體中文. | 🔄 **Always current**<br>Metro networks update from this repository's `main` branch, through mirrors that work in mainland China. |

<p align="center">
  <img src="http://just-go.com.cn/assets/screenshots/ipad.png" height="360" alt="Just-Go on iPad">
  &nbsp;
  <img src="http://just-go.com.cn/assets/screenshots/duo.png" height="360" alt="Just-Go on the iPhone Duo cover display">
</p>

## Cities

**53 cities with an offline metro network, more than 7,500 stations:** Shanghai, Beijing,
Guangzhou, Chengdu, Shenzhen, Wuhan, Chongqing, Nanjing, Hangzhou, Xi'an, Hong Kong, Tianjin,
Suzhou, Zhengzhou, Hefei, Qingdao, Ningbo, Shenyang, Foshan, Changsha, Taipei, Changchun, Jinan,
Dongguan, Nanchang, Fuzhou, Kunming, Dalian, Nanning, Xiamen, Guiyang, Wuxi, Kaohsiung, Harbin,
Xuzhou, Shijiazhuang, Taiyuan, Hohhot, Nantong, Changzhou, Shaoxing, Wenzhou, Wuhu, Luoyang,
Jinhua, Lanzhou, Xuchang, Urumqi, Taoyuan, Taichung, Macau, Taizhou and Chuzhou.

Ziyang, Xiangtan, Xiangxi, Ezhou and Qingyuan are in the catalog with official links only. All 58
cities share a directory of 776 reviewed official links to maps, travel information, accessibility
resources and help pages.

## What Just-Go won't pretend to know

Just-Go does not do indoor navigation. It claims no 3D station maps, indoor routes, boarding cars,
door positions or transfer corridors. On a transfer it shows the station and any official operator
links, and tells you to follow the station signs. Exits and entrances appear where a city publishes
them. Where an online routing provider measures the walk between platforms, it is shown as a
distance, not as a path.

## Privacy

- **Your trips and saved places stay on your device.** There is no Just-Go account and no Just-Go
  server.
- **Location** is asked for only while the app is in use. A trip being guided keeps reading it in
  the background, so the trip can correct itself and update the Lock Screen. The system shows its
  location indicator while that lasts, and it stops when the trip ends.
- **Place search** goes to Apple Maps.
- **Planning a trip** sends its start and end points to Apple Maps for walking directions. In
  builds with a Baidu Maps key, including TestFlight, they also go to Baidu Maps for the fare,
  transfer distances, first and last trains and cycling routes, and place searches can go there
  too. When you plan from where you are, the start point is your location.
- **Station details** in Beijing, Shanghai, Guangzhou and Hangzhou are requested directly from the
  operator (`www.bjsubway.com`, `m.shmetro.com`, `apis.gzmtr.com`, `www.hzmetro.com`) with the
  station's ID, when you open them. The last good answer is kept on the device only, excluded from
  backup, labelled as cached, and removed by Settings → Clear Cache.
- **Hong Kong live trains** are requested from `rt.data.gov.hk` with station and line codes only.
- **Data updates** check this repository through `cdn.jsdmirror.com`, `cdn.jsdelivr.net` and
  `raw.githubusercontent.com`, at most every six hours. They never run on Low Data Mode or during a
  trip, and can be turned off in Settings → Transit Data.
- **Operator pages and documents** open only when you tap them, in viewers that keep nothing.
- The app links to the [Privacy Policy](http://just-go.com.cn/privacy/) and
  [Terms of Service](http://just-go.com.cn/terms/) on the Just-Go website.

## For developers

<details>
<summary><strong>Build from source</strong></summary>

1. Clone the repository.
2. Open `Just-Go.xcodeproj` in Xcode 26 or newer. The app calls the iOS 26 SDK's glass effect
   behind a runtime check, so it still runs on iOS 18 but needs that SDK to compile.
3. Build the `Just-Go` scheme.

Baidu Maps enrichment is optional. Put `BAIDU_MAPS_SECRET_AK` and `BAIDU_MAPS_SECRET_SK` in the
git-ignored `Just-Go/Config/Secrets.xcconfig`; without them the app plans every route offline and
shows no fare.

There are no Xcode test targets. The gate is the Ruby and shell suites under `Scripts/`, the
validators, and Debug and Release builds; `.github/workflows/ci.yml` runs all of them.

</details>

<details>
<summary><strong>Data updates</strong></summary>

The app keeps its metro networks and city packs in step with this repository's `main` branch
(Settings → Transit Data → Updates): on request, or automatically at most every six hours, never on
a Low Data Mode network and never during a trip. `DataPacks/manifest.json` lists each network and
pack with its size and SHA-256. A city's two files are downloaded only when their hash differs from
what is in use, checked against each other, and installed together or not at all. Downloads are
dropped when the app itself updates.

They come from the three origins in `Just-Go/Config/*.xcconfig`, tried in order: the mainland
jsDelivr mirror, jsDelivr, and `raw.githubusercontent.com`, each serving `main`.
`Scripts/validate_runtime_data_policy.rb` pins them by value. Wikimedia is never an origin.

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

</details>

<details>
<summary><strong>Accessibility coverage by city</strong></summary>

From each city's own open data. The counts are pinned in `Scripts/lib/oss_data_validators.rb`.

| City | Network stations | With accessibility data |
| --- | ---: | ---: |
| Xi'an | 263 | 167 |
| Taipei | 152 | 119 |
| Hong Kong | 243 | 98 |
| Shanghai | 471 | 57 |
| Beijing | 452 | 43 |
| Guangzhou | 434 | 41 |
| Shenzhen | 380 | 29 |
| Nanjing | 281 | 11 |
| Hangzhou | 270 | 11 |
| Chengdu | 403 | 10 |
| Wuhan | 359 | 7 |
| Tianjin | 240 | 5 |
| Chongqing | 300 | 3 |
| Suzhou | 235 | 2 |

The other cities are source-pending for station data. The bundled metro network powers rail
routing on its own, without any city pack.

</details>

<details>
<summary><strong>Station information and official resources</strong></summary>

Station Detail presents three compact categories. When the page opens, it requests them from the
operator: first and last trains, exits and facilities in Beijing (422 stations) and Shanghai (415),
and first and last trains in Guangzhou (428) and Hangzhou (259). It validates the returned station
identity and renders the text as native rows, using an ephemeral session, a 1 MB cap and a
five-minute memory cache. None of these endpoints is a published public
API, and no compatible content-reuse licence was found, so their content is fetched on the rider's
device, never redistributed, and production distribution still requires operator or legal review.
The exact official station page remains an in-app source and fallback. The contract the app
follows is published in [StationInfoAPI/](StationInfoAPI/README.md).

Hong Kong uses the same three categories for all 162 stations, with live trains from the official
government transport API in place of first and last trains. Exits and facilities come from the
bundled DATA.GOV.HK barrier-free snapshot, including verified unavailable states. Hong Kong also
contributes 1 system map, 98 location maps, 98 station layouts and 14 Light Rail street maps from
the official MTR indexes.

All 450 of Beijing's canonical stations have a reviewed station-information state: 424 exact
pages, 18 with route- or operator-specific official context, 3 not open for passenger service and
5 not current passenger stops.

The official resource directory is independent of the city packs. 43 cities have at least one
verified official resource, and 15 carry an explicit dated no-resource review. Links do not count
as bundled maps, offline content or verified transfer guidance. Reviewed pages, PDFs and images
open inside Just-Go only after a tap: pages in a non-persistent WebKit session, documents in
memory-only viewers with a 50 MB limit.

</details>

<details>
<summary><strong>Data formats, sources and licences</strong></summary>

- The [Universal City Data Format](DataPacks/UNIVERSAL_FORMAT.md):
  [`DataPacks/universal/`](DataPacks/universal/) publishes all 58 cities in one versioned,
  integrity-indexed JSON schema.
- Metro networks come from OpenStreetMap under ODbL 1.0, separately attributed. Hong Kong data is
  from DATA.GOV.HK under its reuse terms, and Taipei's from data.taipei under the OGDL-TW.
  Beijing, Shanghai, Guangzhou and Hangzhou operator content is link-only and never committed.
- [DataPacks/README.md](DataPacks/README.md), [DataPacks/RIGHTS.md](DataPacks/RIGHTS.md) and
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) record schema, provenance, checksums and the
  exact licence treatment.

</details>

## License

Just-Go's original software source is licensed under GPL-3.0. Third-party data and media are not
granted under the GPL-3.0 licence; their terms are recorded in `DataPacks/rights_inventory.json`
and `THIRD_PARTY_NOTICES.md`.
