# Station Information API — call guide

This is a **client contract**, not a hosted service. There is no Just-Go server to call. You read
three static files, then fetch each operator **yourself, on your end-user's device**, and reshape
the response into one uniform schema.

That indirection is the whole design. For Beijing, Shanghai and Guangzhou the grant is
`LicenseRef-External-Link-Only`: the operator's page content — first/last trains, exits, facilities
— may be linked and indexed but **not copied and re-served**. So neither Just-Go nor you may stand up
an endpoint that proxies it. Each app fetches it live, on its own users' devices, and redistributes
nothing. Hong Kong is different (`LicenseRef-DATA-GOV-HK-1.2`, redistributable) and its static data
ships in a pack; see [Hong Kong](#hong-kong) below.

## The three files

| File | What it is | You use it to… |
|---|---|---|
| [`schema/station-information.schema.json`](schema/station-information.schema.json) | JSON Schema (draft 2020-12) | validate / codegen the shape you must produce |
| [`directory/directory.json`](directory/directory.json) | station index (generated) | look up a station and learn **which source** covers it and **which identifier** to fetch with |
| [`sources/sources.json`](sources/sources.json) | source registry | learn **how to fetch** each source and **how to map** its raw fields |

A generic client needs no per-city code: the directory says *where*, the registry says *how*, the
schema says *what the result must look like*.

## The four steps

```
① look the station up in directory.json        → which source, which key
② read that source's recipe in sources.json     → endpoints + field map + rules
③ fetch LIVE from the operator, on-device       → raw response
④ reshape into schema.json, applying the rules  → uniform snapshot
```

### ① Look up the station

`directory.json` is keyed by canonical `stationID` (stable across releases):

```jsonc
"026d8ef2c102d891": {
  "name": "陆家嘴",
  "nameEn": "Lujiazui",
  "sources": {
    "shanghaiMetroOnline": {
      "externalStationID": "0247",
      "lineStationIDs": ["0247", "1438"],   // one key per line it serves
      "sourcePageURL": "https://service.shmetro.com/czxx/index.htm?id=0247"
    }
  }
}
```

The key you pass downstream is named by that source's `directoryKey` in the registry
(`lineStationIDs` for Shanghai, `externalStationID` for Beijing, `stationShowCode` for Guangzhou).

### ② Read the recipe

Each source in `sources.json` carries its `license`, a `redistributable` flag, an `access` block
(endpoints), a `map` (raw field → schema field), and `rules` (the things that are wrong if you skip
them). **Check `redistributable` first** — `false` means step ③ must run on the end-user's device.

### ③ Fetch live

Call the endpoints from `access.endpoints`, substituting the directory key into the `{…}`
placeholder. Example (Shanghai first/last for line 2):

```
GET https://m.shmetro.com/interface/metromap/metromap.aspx?func=fltime&line=2
→ [ { "stat_id": "247", "description": "往广兰路", "first_time": "--", "last_time": "23:23" }, … ]
```

### ④ Reshape into the schema

Apply the `map` and `rules`, then validate against `schema/station-information.schema.json`:

```jsonc
{
  "stationID": "026d8ef2c102d891",
  "stationName": "陆家嘴",
  "source": "shanghaiMetroOnline",
  "freshness": { "state": "live" },
  "lines": [
    { "lineName": "2号线", "lineColorHex": "#8CC220", "services": [
        { "direction": "往广兰路", "firstTrain": null, "lastTrain": "23:23", "liveTime": null }
    ] }
  ],
  "exits": [ … ],
  "facilityGroups": [ … ]
}
```

Note `"--"` became `null`, not the string `"--"` — that is rule `placeholders` doing its job.

## The rules everyone gets wrong

These live per-source in `sources.json`, but three are universal:

1. **Service-day ordering.** A last train at `00:21` is *later* than one at `23:39`. Comparing the
   strings, or parsing them as plain clock times, ranks the real last train earliest and drops it.
   Add 24h to any hour `< 4` before comparing.
2. **Collapse services, not directions.** Operators often return one row per short-turn *run*, not
   per direction — several rows sharing a line, a direction and a first-train time, differing only
   in the last-train digits. Merge them (earliest first, latest last). Never merge a line's two
   directions; a rider needs the one they are travelling.
3. **Placeholders are not data.** `无`, `暂无`, `/`, `--`, `n/a` and friends mean *unavailable*.
   Emit `null`; do not copy the token through as if it were a time or a location.

## Per-source notes

### Beijing — `beijingSubwayOnline`
One `GET` returns everything (`…/getStationDetail?accLocation={externalStationID}`): lines, exits,
facilities. Verify `data.station.stationDeviceLocation` equals the ID you requested before trusting
the body. `LicenseRef-External-Link-Only` — fetch on-device.

### Shanghai — `shanghaiMetroOnline`
Three `GET`s: `func=lines` (colours, once for the network), `func=fltime&line={n}` (first/last for a
whole line — filter by `stat_id`), `func=stationInfo&stat_id={lineStationID}` (exits + toilets, as
re-parsed JSON strings). Two quirks: `fltime` `stat_id` drops leading zeros (`"111"` vs the
directory's `"0111"` — left-pad to four); exit `id` may be a JSON number *or* string — coerce.
`LicenseRef-External-Link-Only` — fetch on-device.

### Guangzhou — `guangzhouMetroOnline` *(preview)*
`POST` (body `{}`, `Content-Type: application/json`, no auth). `/metroweb/linestation` yields every
`stationShowCode`; `/serviceTime/list/{stationShowCode}` yields first/last. Lines only — the exit
and facility endpoints return `null`. `lineColor` is 8-digit `RRGGBBAA`; drop the alpha.
Marked **preview**: the recipe is verified but no reviewed catalog ships yet, so Guangzhou has no
directory entries — you supply the `stationShowCode` yourself from `/metroweb/linestation`.
`LicenseRef-External-Link-Only` — fetch on-device.

### Hong Kong
`LicenseRef-DATA-GOV-HK-1.2`, **redistributable** with attribution. Static station information
(barrier-free facilities → exits and facility groups) ships in the app's Hong Kong data pack rather
than being fetched per station. Only live next-train arrivals are fetched, from
`rt.data.gov.hk`, keyed by the directory's `liveArrivalReferences`, and land in `service.liveTime`.
Show the DATA.GOV.HK attribution wherever you display it.

## Versioning

`schema.json` is **version 2** (see `$defs.envelope.schemaVersion`). `source` is deliberately an
open string: adding a city is additive and does **not** bump the schema. The authoritative list of
valid `source` values is the key set of `sources.json`. A reader must reject an envelope whose
`schemaVersion` it does not know.
