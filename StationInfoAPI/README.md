# Station Information API

A uniform, developer-facing contract for transit station information — first/last trains, exits and
facilities — normalized across operators that each publish it in a completely different raw form.

**It is a contract, not a hosted service.** There is no endpoint here to call. You read the static
files below, then fetch each operator yourself, on your end-user's device, and reshape the response
into one schema. That indirection is what keeps every consumer inside the source licences: for
mainland operators the grant is `LicenseRef-External-Link-Only` — link and index freely, but do not
copy and re-serve their content. See [`API.md`](API.md) for the reasoning and the boundary.

## Files

| Path | Layer | Licence | Maintained |
|---|---|---|---|
| [`schema/station-information.schema.json`](schema/station-information.schema.json) | ① the shape | MIT (authored) | by hand |
| [`directory/directory.json`](directory/directory.json) | ② the index — station → source + key | link metadata only | **generated** |
| [`sources/sources.json`](sources/sources.json) | ③ the recipe — how to fetch + map each source | MIT (recipe) + link URLs | by hand |
| [`API.md`](API.md) | the call guide | MIT (authored) | by hand |

None of these files carry operator content — only station IDs, names, aliases, page URLs, and
JustGo's own authored schema and mapping recipes. The prose companion to the schema is
[`../DataPacks/STATION_INFORMATION_SCHEMA.md`](../DataPacks/STATION_INFORMATION_SCHEMA.md).

## How the three layers fit together

```
directory.json   →  "for station X, use source S with key K"
      +
sources.json     →  "to read source S: fetch these endpoints, map these fields, obey these rules"
      +
schema.json      →  "the result must look exactly like this"
      =
a generic client that supports every city with no per-city code.
```

Read [`API.md`](API.md) for the four-step call flow and the per-source notes.

## Regenerating the directory

`directory/directory.json` is derived from the reviewed per-city catalogs under
`DataPacks/sources/official-resources/`. It is deterministic — regenerating produces byte-identical
output.

```sh
ruby Scripts/generate_station_info_api.rb          # rewrite the directory
ruby Scripts/generate_station_info_api.rb --check  # fail if the committed file has drifted
ruby Scripts/validate_station_info_api.rb          # validate all three files + their consistency
```

## Coverage

| Source | City | Licence | Fetch model | first/last | exits | facilities | status |
|---|---|---|---|:-:|:-:|:-:|---|
| `beijingSubwayOnline` | Beijing | link-only | on-device | ✅ | ✅ | ✅ | stable |
| `shanghaiMetroOnline` | Shanghai | link-only | on-device | ✅ | ✅ | ✅ | stable |
| `hongKongGovernment` | Hong Kong | DATA.GOV.HK | bundled + live arrivals | — | ✅ | ✅ | stable |
| `guangzhouMetroOnline` | Guangzhou | link-only | on-device | ✅ | — | — | preview |

*Preview* = the fetch/map recipe is verified live but no reviewed catalog ships yet, so the source
has no `directory.json` entries. Adding a stable city is a data change (a new catalog + regenerate),
not new client code.
