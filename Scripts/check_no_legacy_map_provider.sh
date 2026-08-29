#!/bin/sh
set -eu

# The app used to link Amap's native SDK and ship an AMAP_API_KEY. That is what this guard is for,
# and the reason is the one BaiduMapsClient gives for choosing an HTTP web service over Baidu's own
# SDK: a closed-source binary that collects device identifiers has no place in an app whose whole
# promise is that it does not do that. `SubwayData` was that integration's bundled dataset.
#
# Opening a URL is categorically different and is deliberately allowed. No key, no linked binary,
# nothing collected by us — the rider taps a button and their own installed app takes the leg over.
# It is narrowly scoped to bike and car legs by ExternalRouteHandoff, for the reasons written there.
#
# So this bans the integration, not the word. Widening it back to a bare "amap" match would forbid
# the handoff; narrowing it further would let the SDK back in.
if rg -n "AMAP_API_KEY|SubwayData|AMapFoundationKit|AMapSearchKit|MAMapKit|import AMap" \
  Just-Go README.md Just-Go.xcodeproj Scripts \
  --glob '!check_no_legacy_map_provider.sh'; then
  echo "Legacy map-provider integration found." >&2
  exit 1
fi

# The handoff may only ever be an outbound URL. If an Amap symbol shows up in Swift that is not a
# string literal, the SDK is coming back.
if rg -n --type swift "AMap[A-Za-z]*\s*\(" Just-Go; then
  echo "Amap SDK call found; only URL handoff is permitted." >&2
  exit 1
fi

echo "No legacy map-provider integration found."
