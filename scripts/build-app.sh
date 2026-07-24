#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/frogmouth.app"
CONTENTS="$APP/Contents"
ICON="$ROOT/Assets/AppIcon.icns"
RESOURCE_BUNDLE="$ROOT/.build/release/frogmouth_FrogmouthApp.bundle"
VERSION_FILE="$ROOT/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "Missing application version file: $VERSION_FILE" >&2
    exit 1
fi

VERSION="${FROGMOUTH_VERSION:-$(tr -d '[:space:]' < "$VERSION_FILE")}"
if [[ -n "${FROGMOUTH_BUILD_NUMBER:-}" ]]; then
    BUILD_NUMBER="$FROGMOUTH_BUILD_NUMBER"
else
    BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

"$ROOT/scripts/validate-version.sh" "v$VERSION"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid bundle build number: $BUILD_NUMBER" >&2
    exit 1
fi

cd "$ROOT"
swift build -c release --disable-sandbox

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/frogmouth" "$CONTENTS/MacOS/frogmouth"

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Missing app resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/"

if [[ ! -f "$ICON" ]]; then
    echo "Missing app icon: $ICON" >&2
    exit 1
fi
cp "$ICON" "$CONTENTS/Resources/AppIcon.icns"

PLIST="$CONTENTS/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleDevelopmentRegion -string en "$PLIST"
plutil -insert CFBundleExecutable -string frogmouth "$PLIST"
plutil -insert CFBundleIdentifier -string dev.frogmouth.app "$PLIST"
plutil -insert CFBundleIconFile -string AppIcon "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$PLIST"
plutil -insert CFBundleName -string frogmouth "$PLIST"
plutil -insert CFBundlePackageType -string APPL "$PLIST"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -insert LSMinimumSystemVersion -string 15.0 "$PLIST"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"

echo "Built $APP version $VERSION ($BUILD_NUMBER)"
