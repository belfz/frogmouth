#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.build/test-media-fixtures}"
PROBE="$ROOT/scripts/probe-media-fixture.sh"

"$ROOT/scripts/generate-media-fixtures.sh" "$OUTPUT_DIR"

assert_video() {
    local filename="$1"
    local width="$2"
    local height="$3"
    local frame_rate="$4"
    local frames="$5"
    local audio_count="$6"
    local primaries="$7"
    local transfer="$8"
    local matrix="$9"
    local range="${10}"
    local facts

    facts="$($PROBE "$OUTPUT_DIR/$filename")"
    jq -e \
        --argjson width "$width" \
        --argjson height "$height" \
        --arg frameRate "$frame_rate" \
        --arg frames "$frames" \
        --argjson audioCount "$audio_count" \
        --arg primaries "$primaries" \
        --arg transfer "$transfer" \
        --arg matrix "$matrix" \
        --arg range "$range" '
        ([.streams[] | select(.codec_type == "video")][0]) as $video
        | ([.streams[] | select(.codec_type == "audio")] | length) as $audios
        | $video.width == $width
        and $video.height == $height
        and $video.avg_frame_rate == $frameRate
        and $video.nb_read_frames == $frames
        and $audios == $audioCount
        and $video.color_primaries == $primaries
        and $video.color_transfer == $transfer
        and $video.color_space == $matrix
        and $video.color_range == $range
    ' <<< "$facts" >/dev/null
}

assert_video "base-24fps-320x180.mp4" 320 180 "24/1" "48" 1 "bt709" "bt709" "bt709" "pc"
assert_video "wide-30000-1001-426x180.mp4" 426 180 "30000/1001" "60" 1 "bt709" "bt709" "bt709" "pc"
assert_video "portrait-25fps-180x320.mp4" 180 320 "25/1" "50" 1 "bt709" "bt709" "bt709" "pc"
assert_video "high-rate-60000-1001-320x180.mp4" 320 180 "60000/1001" "60" 1 "bt709" "bt709" "bt709" "pc"
assert_video "silent-24fps-320x180.mp4" 320 180 "24/1" "48" 0 "bt709" "bt709" "bt709" "pc"
assert_video "incompatible-bt2020-pq.mp4" 320 180 "24/1" "48" 1 "bt2020" "smpte2084" "bt2020nc" "tv"

echo "Verified fixture dimensions, rational frame rates, frame counts, audio presence, and colour signaling."
