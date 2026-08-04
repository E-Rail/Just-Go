#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}

if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "Xcode developer directory not found: $DEVELOPER_DIR" >&2
    exit 1
fi

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/justgo-personal-media-tests.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$REPO_ROOT/JustGo/Models/Transit/MetroStationIdentifier.swift" \
    "$REPO_ROOT/JustGo/Models/User/PersonalStationMedia.swift" \
    "$REPO_ROOT/JustGo/Services/Data/PersonalStationMediaService.swift" \
    "$SCRIPT_DIR/test_personal_station_media.swift" \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -o "$BUILD_DIR/test_personal_station_media"

"$BUILD_DIR/test_personal_station_media"
