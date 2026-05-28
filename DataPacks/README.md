# JustGo City Data Packs

This folder is the cloud-upload root for official city data. It is a source artifact for hosting and must not be added to the iOS app bundle.

The current beta setup serves this folder from GitHub/jsDelivr. If you later choose a different static host, upload the contents of this folder so these URLs work:

- `{CITY_PACK_BASE_URL}/manifest.json`
- `{CITY_PACK_BASE_URL}/packs/1100/beijing-official-20260519/city_pack.json`

Use the public folder URL in your local `JustGo/Config/Secrets.xcconfig`:

```xcconfig
CITY_PACK_SECRET_BASE_URL = https:/$()/your-static-host.example/justgo-city-data
```

The tracked app config falls back to jsDelivr's GitHub CDN for development and beta testing:

```xcconfig
CITY_PACK_FALLBACK_BASE_URL = https:/$()/cdn.jsdelivr.net/gh/E-Rail/JustGo@main/DataPacks
```

The app also accepts a full manifest URL through `CITY_PACK_SECRET_MANIFEST_URL` for backward compatibility, but the preferred setup is the base folder URL.
