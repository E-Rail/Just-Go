# Station Information Schema (v3)

The interchange format Just-Go uses for live, operator-published station information: first/last
trains, exits, and facilities. It is the shape of every entry in the device-only station
information cache, and it is documented here so other applications can implement against the same
contract.

## What this document is, and is not

**This is a schema, not a dataset.** Just-Go bundles no operator station content and this repository
ships none. Beijing's first/last trains, exits, and facilities are covered by
`beijing-official-landing-links` in `rights_inventory.json`, whose grant is
`LicenseRef-External-Link-Only`:

> no operator page text, schedules, facilities, exits, coordinates, images, or media are copied

so Just-Go requests them from `www.bjsubway.com` on the rider's own device, keeps a last-good copy
under Application Support (backup-excluded, wiped by Settings → Clear Cache), and redistributes
nothing. What *is* bundled is `sources/official-resources/beijing_station_information.json`, which
holds only station IDs, names, aliases, and page URLs — the permitted scope.

A schema is not the operator's content. Implementing it is free; populating it is between you and
whichever source you use, under whatever licence that source grants you.

## Envelope

One JSON object per station, as stored on disk.

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | integer | `3`. A reader must reject any version it does not know. |
| `externalStationID` | string | The upstream provider's own station identifier. |
| `fetchedAt` | string | ISO-8601, UTC. When this copy was retrieved. |
| `snapshot` | object | The station information itself. |

## `snapshot`

| Field | Type | Notes |
|---|---|---|
| `stationID` | string | Canonical station ID, stable across releases. |
| `stationName` | string | Station name as the provider states it. |
| `source` | string | `beijingSubwayOnline` \| `hongKongGovernment`. |
| `freshness` | object | `{"state": "live"}` or `{"state": "cached", "fetchedAt": "…"}`. |
| `serviceDayNote` | string \| null | Which service day the times describe, in the source's own words. Hangzhou publishes `工作日时刻表`, the weekday timetable; a consumer showing it on a Saturday must say so. Null when unstated. |
| `lines` | array | Service information, grouped by line. |
| `exits` | array | Exits and entrances. |
| `facilityGroups` | array | Facilities, grouped as the provider groups them. |

### `lines[]`

Services nest under the line that runs them: one block per line, holding every direction it
serves. The line's name and colour are stated once rather than repeated on each direction.

| Field | Type | Notes |
|---|---|---|
| `lineName` | string | Unique within a station; usable as the block's identity. |
| `lineColorHex` | string \| null | `#RRGGBB`. Null when the provider states no colour. |
| `services` | array | One entry per direction of travel. |

### `lines[].services[]`

| Field | Type | Notes |
|---|---|---|
| `direction` | string | The direction of travel, as a rider reads it on the platform sign. Names a way, not necessarily where this train ends. |
| `destination` | string \| null | Where this individual service terminates, when the source distinguishes it from `direction`. Null when it publishes one name for both. |
| `firstTrain` | string \| null | `H:MM` or `HH:MM`, provider-local time. |
| `lastTrain` | string \| null | Same format. May be past midnight — see below. |
| `liveTime` | string \| null | A live countdown, where the operator publishes one. |

Two rules a correct implementation needs:

**Times are on the service day, not the clock day.** A last train at `00:21` is *later* than one at
`23:39`. Comparing the strings, or parsing them as plain clock times, ranks the real last train as
the earliest of the day and discards it.

**Keep services apart; merge only true duplicates.** Providers commonly return one record per
*service* rather than per direction, so a direction served by several short-turn runs yields several
records sharing a line, a direction marker, and a first-train time, differing in the last-train
digits. It is tempting to fold those into one window spanning earliest-first to latest-last. **Do
not.** That last train belongs to whichever run goes furthest, and a rider getting off beyond where
the others turn back cannot catch it.

Live at 国贸, every northbound 10号线 record carries `direction` = 双井 and they separate only by
`destination`:

    → 车道沟   5:18 – 21:28        → 成寿寺   5:18 – 23:36        → 巴沟   5:18 – 23:12

Folded, that publishes 23:36. The 23:36 train turns back at 成寿寺, seventeen stops before 车道沟, so
a rider heading round the ring is handed a last train that was never going to carry them; theirs is
the 23:12. Key on (`direction`, `destination`) and emit one entry per service. Merge two records only
when both names match — a genuine duplicate — and then take earliest first, latest last.

Do **not** merge the two directions of a line either: their first and last trains genuinely differ,
and a rider needs the one they are travelling in.

### `exits[]`

| Field | Type | Notes |
|---|---|---|
| `name` | string | Exit label, e.g. `A`, `B2`. |
| `details` | array of string | Landmarks the provider associates with the exit. |
| `isAccessible` | boolean \| null | Null means *not stated*, which is not the same as `false`. |

### `facilityGroups[]`

| Field | Type | Notes |
|---|---|---|
| `name` | string | The provider's own group heading. |
| `items` | array | Facilities in that group. |

### `facilityGroups[].items[]`

| Field | Type | Notes |
|---|---|---|
| `name` | string | Facility name. |
| `location` | string \| null | Where in the station, when stated. |
| `availability` | string \| null | `available` \| `unavailable`. Null means *not stated*. |

Providers write "no data" in many ways — `无`, `暂无`, `沒有`, `/`, `-`, `n/a`, `none`. Treat those
as `unavailable` with a null `location` rather than copying the placeholder through as if it were
a location.

## Example

```json
{
  "schemaVersion": 3,
  "externalStationID": "150996249",
  "fetchedAt": "2026-07-14T03:33:20Z",
  "snapshot": {
    "stationID": "00170074e2fd8df1",
    "stationName": "天通苑南",
    "source": "beijingSubwayOnline",
    "freshness": { "state": "live" },
    "lines": [
      {
        "lineName": "5号线",
        "lineColorHex": "#A6217F",
        "services": [
          { "direction": "宋家庄",   "destination": "宋家庄",   "firstTrain": "05:19", "lastTrain": "22:53", "liveTime": null },
          { "direction": "天通苑北", "destination": "天通苑北", "firstTrain": "05:53", "lastTrain": "00:21", "liveTime": null }
        ]
      }
    ],
    "exits": [
      { "name": "A", "details": ["天通苑东一区"], "isAccessible": true }
    ],
    "facilityGroups": [
      {
        "name": "无障碍设施",
        "items": [
          { "name": "无障碍电梯", "location": "A口", "availability": "available" }
        ]
      }
    ]
  }
}
```

## Version history

- **v3** — `services[]` gained `destination`, and `snapshot` gained `serviceDayNote`. Both are facts
  the sources were already publishing and this schema was throwing away. Without `destination` a
  direction's short-turns can only be folded into one window whose last train belongs to whichever
  run goes furthest, which is a train a rider getting off earlier cannot catch; without
  `serviceDayNote` a weekday-only timetable (Hangzhou's) reads as today's on a Saturday. A stored v2
  entry fails the version check and is refetched — which is the point, since serving one would keep
  answering with the merged window offline.
- **v2** — services nested under `lines[]` instead of a flat `trains[]` that repeated the line name
  on every row; `source` and `availability` became plain strings and `freshness` gained an explicit
  `state`, replacing Swift's synthesised `{"caseName": {}}` encoding, which no other implementation
  could reasonably produce. A stored v1 entry fails the version check and is refetched.
- **v1** — internal only, never published.
