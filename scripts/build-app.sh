#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/frogmouth.app"
CONTENTS="$APP/Contents"
ICON="$ROOT/Assets/AppIcon.icns"

cd "$ROOT"
swift build -c release --disable-sandbox

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/frogmouth" "$CONTENTS/MacOS/frogmouth"

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
plutil -insert CFBundleShortVersionString -string 0.1.0 "$PLIST"
plutil -insert CFBundleVersion -string 1 "$PLIST"
plutil -insert LSMinimumSystemVersion -string 15.0 "$PLIST"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"

echo "Built $APP"
