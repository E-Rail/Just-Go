# Indoor And Transfer Data

JustGo ships no indoor diagrams, transfer paths, or station map files, and **has no runtime that
could consume them**. `verifiedTransferContexts.covered` is zero for every catalog city and the
metric is retained only so a pack that claimed otherwise would fail validation.

The Swift indoor-navigation interfaces were removed in full: the `StationIndoorMap` graph and its
step planner, the schematic walkthrough, the camera-based checkpoint scanner, and the
`indoorMap` / `transferPath` / `boardingZoneGuidance` / `doorGuidance` provider methods. They had
been kept dormant for a future on-site-verified pilot, but no data source ever materialised, so
every entry point was unreachable — the app carried roughly 3,600 lines that no user could run,
plus an `NSCameraUsageDescription` promising App Review a scanner nobody could open.

What remains, and is honest:

- **Exits and entrances** — `stationAccessPoints`, from official open data (Taipei today).
- **Corridor and platform hints** — free text from official accessibility data (Hong Kong today).
- **Official layout references** — HTTPS landing pages only. A link does not imply that a diagram
  was copied, redistributed, verified on site, or converted into navigable geometry.

Re-introducing indoor navigation is a new feature, not a revival: it needs a reviewed source with
redistribution rights, a checksum, a verification status, and a runtime built alongside the data
rather than ahead of it. `Scripts/validate_indoor_maps.rb` enforces the current state — no indoor
data files, no indoor fields on pack stations, and no coverage claimed.
