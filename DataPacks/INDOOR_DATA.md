# Indoor Transfer Data

Beijing indoor-navigation metadata is generated from the per-station fragments under
`packs/1100/beijing-official-20260527/indoor/` by `Scripts/build_indoor_maps.rb`.

- Every served line at the 41 diagram-backed interchanges has either a canonical,
  direction-aware platform checkpoint or an explicit `lineCoverageGaps` entry.
- The bundled Muxidi diagram does not depict Line 16, so that platform remains an explicit
  source gap instead of receiving fabricated geometry.
- Only Haidian Huangzhuang and Xizhimen currently have connected, diagram-traced paths.
- The other 39 stations intentionally use `platformCheckpoints`; no corridor, distance,
  turn, boarding zone, car, or door is inferred when the source diagram does not prove it.
- A `diagramReviewed` graph is not an official navigation feed or continuous indoor position.
  Only `onSiteVerified` data may make an on-site verification claim.
- Camera sign recognition is an optional on-device checkpoint confirmation mechanism. It
  does not make an unverified path accurate and never creates new map data.
- Diagram assets retain their source URL and content digest. `assetUsageStatus` remains
  `reviewRequired` until redistribution and product-display permission is documented.

Run `ruby Scripts/build_indoor_maps.rb` after fragment edits, then
`ruby Scripts/validate_indoor_maps.rb`. The validator enforces manifest digests, provenance,
canonical line/station IDs, direction adjacency, graph connectivity, confidence claims, and
complete platform-or-explicit-gap coverage for every served line.
