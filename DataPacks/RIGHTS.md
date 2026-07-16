# Data And Media Rights

The machine-readable inventory is `rights_inventory.json`. Its IDs are referenced directly by
each bundled pack through `rightsIDs`; undeclared licenses and binaries fail validation.

## Canonical Networks

Canonical station IDs and names are read from the app's `MetroNetworks` resources, whose
geometry source is OpenStreetMap. OpenStreetMap data is licensed under the Open Data Commons
Open Database License 1.0 (ODbL-1.0). Attribution must remain visible, and adapted databases
remain subject to the ODbL share-alike terms.

## Hong Kong CSV Snapshots

The four files in `sources/8100` are official MTR Corporation Limited resources distributed
through DATA.GOV.HK. They are not assigned a standard open-source SPDX license. This repository
uses `LicenseRef-DATA-GOV-HK-1.2` to identify the custom DATA.GOV.HK Terms of Use, version 1.2.
Those terms permit commercial and non-commercial reuse subject to their conditions, including
clear source identification and attribution to MTR Corporation Limited and DATA.GOV.HK.

The exact source URLs, byte counts, CSV record counts, and SHA-256 checksums are recorded in
`sources/8100/metadata.json`. That metadata also inventories the two runtime arrival APIs,
their DATA.GOV.HK landing pages and MTR data dictionaries, plus the explicit `EAL/RAC`
Racecourse binding. The generated `DataLicenseMetadata` contract records the terms
URL, attribution, snapshot date, and official terms page used as redistribution evidence.
Generated Hong Kong JSON contains only the fields needed for canonical matching,
accessibility, official live lookup identifiers, and schema-compatibility link fields. Runtime
code ignores city-pack links and trusts only the separately reviewed bundled resource catalog.
It contains no static schedules.

This inventory is a conservative engineering control, not a legal guarantee. Custom or
ambiguous terms require legal review before new data is bundled.

## Official External Resource Links

`official_transit_resources.json` contains factual URL metadata only: exact target and source-page
URLs, provider, city or station scope, format, and review date. Its 58 dated city reviews currently
contain 330 links across 43 cities and explicit no-resource results for the other 15. No linked
page, PDF, or image is copied into the repository or app bundle.

Hong Kong's refresh-only developer importer reads the official MTR System Map and Light Rail
Street Map indexes and stores URL metadata, not document contents. The catalog exposes 1 system
map, 98 Location Maps, 98 Station Layouts, and 14 Light Rail Street Maps, all hosted by MTR. Macau
remains source-pending for structured data and exposes official route, fare, and customer-service
links.

Resources open only after a user taps an ordinary system-browser link. JustGo does not fetch,
preview, cache, prefetch, or store operator content, and external maps do not count as offline
coverage or evidence of an indoor path or door position. Browser downloads remain the user's
choice. Hyperlinking is a conservative engineering policy, not a legal guarantee.

## Pilot Media

- `LicensedMedia/beijing-jianguomen.jpg`: "Beijing Subway Jianguomen Station 01.jpg" by Ian
  Holton, licensed CC BY 2.0. The app-normalized file is 470435 bytes with SHA-256
  `54f8ab6ecab018924e43fb244b5d2d940a100a4680caa799e8e807a721adf750`.
- `LicensedMedia/hong-kong-central.jpg`: "Central station in Hong Kong.jpg" by Qqhhss,
  dedicated under CC0 1.0. The app-normalized file is 955201 bytes with SHA-256
  `7ef38511d29cee0872787d5ab154bafce6a0089af3bc48508999244ff0840370`.

The normalized files are local bundle resources. Runtime packs may retain Commons description
page URLs for attribution, but must never use Commons or Wikimedia upload URLs as runtime image
sources.
