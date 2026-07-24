#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/frogmouth.app}"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/frogmouth"
EXPECTED_VERSION="$("$ROOT/scripts/validate-version.sh")"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Missing executable app binary: $EXECUTABLE" >&2
    exit 1
fi
if [[ ! -f "$PLIST" ]]; then
    echo "Missing app Info.plist: $PLIST" >&2
    exit 1
fi

plutil -lint "$PLIST"

ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
MINIMUM_SYSTEM="$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")"
BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"

if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "App version $ACTUAL_VERSION does not match VERSION $EXPECTED_VERSION." >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid app bundle build number: $BUILD_NUMBER" >&2
    exit 1
fi
if [[ "$MINIMUM_SYSTEM" != "15.0" ]]; then
    echo "Unexpected minimum macOS version: $MINIMUM_SYSTEM" >&2
    exit 1
fi
if [[ "$BUNDLE_IDENTIFIER" != "dev.frogmouth.app" ]]; then
    echo "Unexpected bundle identifier: $BUNDLE_IDENTIFIER" >&2
    exit 1
fi
if ! file "$EXECUTABLE" | grep -q "arm64"; then
    echo "The release executable is not an Apple-silicon binary." >&2
    exit 1
fi

echo "Verified $APP version $ACTUAL_VERSION ($BUILD_NUMBER)"
