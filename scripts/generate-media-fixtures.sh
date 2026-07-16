#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.build/test-media-fixtures}"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"
FONT="/System/Library/Fonts/Monaco.ttf"

if [[ -z "$FFMPEG" || ! -x "$FFMPEG" ]]; then
    echo "A runnable ffmpeg executable is required." >&2
    exit 1
fi

if [[ ! -f "$FONT" ]]; then
    echo "Missing fixture font: $FONT" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

video_filter() {
    local colour="$1"
    local filter="drawtext=fontfile=${FONT}:text='FRAME %{n}':fontcolor=white:fontsize=24:box=1:boxcolor=black@0.7:x=(w-text_w)/2:y=(h-text_h)/2"
    if [[ "$colour" == "bt2020-pq" ]]; then
        filter+=",setparams=range=limited:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc"
    else
        filter+=",setparams=range=full:color_primaries=bt709:color_trc=bt709:colorspace=bt709"
    fi
    echo "$filter"
}

make_av_fixture() {
    local filename="$1"
    local size="$2"
    local rate="$3"
    local duration="$4"
    local frequency="$5"
    local colour="$6"

    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=${size}:rate=${rate}:duration=${duration}" \
        -f lavfi -i "sine=frequency=${frequency}:sample_rate=48000:duration=${duration}" \
        -vf "$(video_filter "$colour")" \
        -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p \
        -c:a aac -b:a 128k -ar 48000 -ac 2 \
        -movflags +faststart -shortest \
        "$OUTPUT_DIR/$filename"
}

make_silent_fixture() {
    local filename="$1"
    local size="$2"
    local rate="$3"
    local duration="$4"

    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=${size}:rate=${rate}:duration=${duration}" \
        -vf "$(video_filter bt709)" \
        -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p \
        -an -movflags +faststart \
        "$OUTPUT_DIR/$filename"
}

make_av_fixture "base-24fps-320x180.mp4" "320x180" "24" "2" "440" "bt709"
make_av_fixture "wide-30000-1001-426x180.mp4" "426x180" "30000/1001" "2.002" "550" "bt709"
make_av_fixture "portrait-25fps-180x320.mp4" "180x320" "25" "2" "660" "bt709"
make_av_fixture "high-rate-60000-1001-320x180.mp4" "320x180" "60000/1001" "1.001" "770" "bt709"
make_silent_fixture "silent-24fps-320x180.mp4" "320x180" "24" "2"
make_av_fixture "incompatible-bt2020-pq.mp4" "320x180" "24" "2" "880" "bt2020-pq"

echo "Generated deterministic media fixtures in $OUTPUT_DIR"
