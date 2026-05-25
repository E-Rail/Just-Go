# JustGo City Data Packs

This folder is the cloud-upload root for official city data. It is a source artifact for hosting and must not be added to the iOS app bundle.

Upload the contents of this folder to a static host that is reachable from mainland China. After upload or sync, these URLs must work:

- `{CITY_PACK_BASE_URL}/manifest.json`
- `{CITY_PACK_BASE_URL}/packs/1100/beijing-official-20260519/city_pack.json`

Use the public folder URL in your local `JustGo/Config/Secrets.xcconfig`:

```xcconfig
CITY_PACK_SECRET_BASE_URL = https:/$()/your-static-host.example/justgo-city-data
```

Do not use Gitee raw URLs as the production host. Gitee may block repositories that are used for external RAW-file hosting, which makes the app receive HTTP 403 even when the GitHub Action pushes successfully.

The tracked app config falls back to GitHub raw files for development testing only:

```xcconfig
CITY_PACK_FALLBACK_BASE_URL = https:/$()/raw.githubusercontent.com/E-Rail/JustGo/main/DataPacks
```

For China mainland users, set `CITY_PACK_SECRET_BASE_URL` to object storage or another static host that allows public JSON/file downloads.

The app also accepts a full manifest URL through `CITY_PACK_SECRET_MANIFEST_URL` for backward compatibility, but the preferred setup is the base folder URL.

## GitHub Actions sync

The workflow at `.github/workflows/sync-city-packs-to-gitee.yml` mirrors only this folder to `https://gitee.com/E-Rail/just-go.git`. This is useful as a private/public source mirror, but Gitee raw is no longer assumed to be a downloadable app host. Add this GitHub secret only if you still want that mirror:

- `GITEE_TOKEN`: a Gitee access token that can push to the data repo

Optional:

- `GITEE_REPO`: override the default repo if the data repo changes
- `GITEE_BRANCH`: defaults to `main`

The Gitee repository root becomes the city-pack root. Do not put app source code or secrets in the Gitee data repo.
