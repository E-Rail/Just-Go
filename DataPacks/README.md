# JustGo City Data Packs

This folder is the cloud-upload root for official city data. It is a source artifact for hosting and must not be added to the iOS app bundle.

Upload the contents of this folder to a static host that is reachable from mainland China. The recommended free-ish setup is a public Gitee data repository synced by GitHub Actions. After upload or sync, these URLs must work:

- `{CITY_PACK_BASE_URL}/manifest.json`
- `{CITY_PACK_BASE_URL}/packs/1100/beijing-official-20260519/city_pack.json`

For a Gitee repo, use the raw-file base URL:

```xcconfig
CITY_PACK_SECRET_BASE_URL = https:/$()/gitee.com/E-Rail/just-go/raw/main
```

The tracked app config already uses this Gitee raw base URL by default.

The app also accepts a full manifest URL through `CITY_PACK_SECRET_MANIFEST_URL` for backward compatibility, but the preferred setup is the base folder URL.

## GitHub Actions sync

The workflow at `.github/workflows/sync-city-packs-to-gitee.yml` mirrors only this folder to `https://gitee.com/E-Rail/just-go.git`. Create or keep that repository public, then add this GitHub secret:

- `GITEE_TOKEN`: a Gitee access token that can push to the data repo

Optional:

- `GITEE_REPO`: override the default repo if the data repo changes
- `GITEE_BRANCH`: defaults to `main`

The Gitee repository root becomes the city-pack root. Do not put app source code or secrets in the Gitee data repo.
