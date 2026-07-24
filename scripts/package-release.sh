#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/scripts/validate-version.sh")"
APP="$ROOT/build/frogmouth.app"
OUTPUT_DIR="$ROOT/build/releases"
STAGING_DIR="$ROOT/build/.release-staging"
DMG_NAME="frogmouth-$VERSION-macos-arm64.dmg"
ZIP_NAME="frogmouth-$VERSION-macos-arm64.zip"
CHECKSUM_NAME="SHA256SUMS.txt"

"$ROOT/scripts/verify-app-bundle.sh" "$APP"

rm -rf "$OUTPUT_DIR" "$STAGING_DIR"
mkdir -p "$OUTPUT_DIR" "$STAGING_DIR"
trap 'rm -rf "$STAGING_DIR"' EXIT

ditto "$APP" "$STAGING_DIR/frogmouth.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -quiet \
    -volname "frogmouth $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_DIR/$DMG_NAME"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/$ZIP_NAME"

(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > "$CHECKSUM_NAME"
    shasum -a 256 -c "$CHECKSUM_NAME"
)
hdiutil verify -quiet "$OUTPUT_DIR/$DMG_NAME"
unzip -tqq "$OUTPUT_DIR/$ZIP_NAME"

echo "Packaged unsigned release artifacts in $OUTPUT_DIR"
echo "  $DMG_NAME"
echo "  $ZIP_NAME"
echo "  $CHECKSUM_NAME"
