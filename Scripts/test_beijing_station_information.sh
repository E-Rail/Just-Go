#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDKROOT=$(env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-path)

if [ ! -x "$SWIFTC" ]; then
    echo "Xcode-beta swiftc not found at $SWIFTC" >&2
    exit 1
fi

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/justgo-beijing-station-information.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

"$SWIFTC" \
    -parse-as-library \
    -swift-version 6 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -sdk "$SDKROOT" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -o "$BUILD_DIR/test-beijing-station-information" \
    "$ROOT/JustGo/Services/Transit/OfficialStationInformationProvider.swift" \
    "$ROOT/Scripts/test_beijing_station_information.swift"

"$BUILD_DIR/test-beijing-station-information"
