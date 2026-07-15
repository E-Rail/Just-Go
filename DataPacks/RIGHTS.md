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
Generated Hong Kong JSON contains only the fields needed for
canonical matching, accessibility, official live lookup identifiers, and official layout
landing links. It contains no static schedules.

This inventory is a conservative engineering control, not a legal guarantee. Custom or
ambiguous terms require legal review before new data is bundled.

## Official Landing Links

Beijing content is limited to canonical OpenStreetMap station identity plus HTTPS links to
official Beijing Subway and Beijing MTR landing pages. No page text, station facts, maps,
PDFs, images, or schedules are copied. Hong Kong layout resources likewise point to the MTR
system-map landing page rather than directly to layout PDFs.

Macau remains source-pending. Its catalog entry contains only the official Macao Light Rapid
Transit Corporation homepage (`https://www.mlm.com.mo/en/`) as a user-initiated external link.

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
