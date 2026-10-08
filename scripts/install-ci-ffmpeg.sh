#!/bin/zsh
set -euo pipefail

# Keep CI on a tested release instead of Homebrew's rolling ffmpeg-full formula.
VERSION="8.1.2"
# Homebrew/homebrew-core at 00137008b001d776b790d68765cd80c9e9494715.
SOURCE_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
PREFIX="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frogmouth-ffmpeg-$VERSION}"

if [[ "${FROGMOUTH_TEST_FFMPEG_VERSION:-$VERSION}" != "$VERSION" ]]; then
    echo "CI expects FFmpeg $FROGMOUTH_TEST_FFMPEG_VERSION, but the installer pins $VERSION." >&2
    exit 1
fi

# The workflows install these libraries with Homebrew before calling this script.
pkg-config --exists x264 x265 vidstab freetype2 harfbuzz
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"
BUILD_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frogmouth-ffmpeg.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
ARCHIVE="$BUILD_DIR/ffmpeg-$VERSION.tar.xz"

curl --fail --location --retry 3 \
    "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" \
    --output "$ARCHIVE"
echo "$SOURCE_SHA256  $ARCHIVE" | shasum -a 256 -c -
tar -xf "$ARCHIVE" -C "$BUILD_DIR"

cd "$BUILD_DIR/ffmpeg-$VERSION"
./configure \
    --prefix="$PREFIX" \
    --disable-autodetect \
    --disable-shared \
    --enable-static \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --enable-gpl \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libvidstab \
    --enable-libfreetype \
    --enable-libharfbuzz \
    --enable-videotoolbox \
    --enable-audiotoolbox
make -j "${FROGMOUTH_FFMPEG_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}"
make install

if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$PREFIX/bin" >> "$GITHUB_PATH"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "FFMPEG=$PREFIX/bin/ffmpeg" >> "$GITHUB_ENV"
    echo "FFPROBE=$PREFIX/bin/ffprobe" >> "$GITHUB_ENV"
    echo "FROGMOUTH_FFMPEG=$PREFIX/bin/ffmpeg" >> "$GITHUB_ENV"
fi
echo "Installed CI FFmpeg $VERSION at $PREFIX"
