#!/bin/sh
set -eu

if rg -n "AMap|amap|AMAP_API_KEY|SubwayData" JustGo README.md JustGo.xcodeproj Scripts \
  --glob '!check_no_legacy_map_provider.sh'; then
  echo "Legacy map-provider reference found." >&2
  exit 1
fi

echo "No legacy map-provider references found."
