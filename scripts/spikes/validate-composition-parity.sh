#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$ROOT/.build/test-media-fixtures"
BASE="$ROOT/.build/timeline-spikes"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"
FFPROBE="${FFPROBE:-$(command -v ffprobe)}"
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$BASE/swift-module-cache"
BASE_CLIP="$FIXTURES/base-24fps-320x180.mp4"
WIDE_CLIP="$FIXTURES/wide-30000-1001-426x180.mp4"
HIGH_RATE_CLIP="$FIXTURES/high-rate-60000-1001-320x180.mp4"

mkdir -p "$BASE"
WORK="$(mktemp -d "$BASE/t02.XXXXXX")"
AV_OUTPUT="$WORK/avfoundation.mov"
FF_OUTPUT="$WORK/ffmpeg.mov"
MANIFEST="$WORK/avfoundation-manifest.json"
HIGH_AV_OUTPUT="$WORK/high-rate-avfoundation.mov"
HIGH_FF_OUTPUT="$WORK/high-rate-ffmpeg.mov"
HIGH_MANIFEST="$WORK/high-rate-avfoundation-manifest.json"
"$ROOT/scripts/generate-media-fixtures.sh" "$FIXTURES"

"$SWIFTC" -sdk "$SDK" -target arm64-apple-macos15.0 \
    -module-cache-path "$MODULE_CACHE" -parse-as-library -O \
    "$ROOT/scripts/spikes/AVCompositionParity.swift" \
    -o "$WORK/av-composition-parity"
"$WORK/av-composition-parity" standard "$BASE_CLIP" "$WIDE_CLIP" "$HIGH_RATE_CLIP" "$AV_OUTPUT" "$MANIFEST"
"$WORK/av-composition-parity" high-rate "$BASE_CLIP" "$WIDE_CLIP" "$HIGH_RATE_CLIP" "$HIGH_AV_OUTPUT" "$HIGH_MANIFEST"

"$FFMPEG" -hide_banner -loglevel error -y \
    -i "$BASE_CLIP" -i "$WIDE_CLIP" -i "$BASE_CLIP" \
    -filter_complex \
"[0:v]trim=start_frame=12:end_frame=36,setpts=PTS-STARTPTS,fps=24,scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v0];
[1:v]trim=start_frame=15:end_frame=45,setpts=PTS-STARTPTS,fps=24,setpts=N/(24*TB),scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v1];
[2:v]trim=start_frame=36:end_frame=48,setpts=PTS-STARTPTS,fps=24,scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v2];
[0:a]atrim=start=0.5:end=1.5,asetpts=PTS-STARTPTS,aresample=48000[a0];
[1:a]atrim=start=0.5005:end=1.5015,asetpts=PTS-STARTPTS,atempo=1.001,atrim=duration=1,aresample=48000[a1];
[2:a]atrim=start=1.5:end=2,asetpts=PTS-STARTPTS,aresample=48000[a2];
[v0][a0][v1][a1][v2][a2]concat=n=3:v=1:a=1[v][a]" \
    -map "[v]" -map "[a]" \
    -c:v prores_ks -profile:v 2 -pix_fmt yuv422p10le \
    -c:a pcm_s16le "$FF_OUTPUT"

"$FFMPEG" -hide_banner -loglevel error -y \
    -i "$HIGH_RATE_CLIP" -i "$BASE_CLIP" -i "$HIGH_RATE_CLIP" \
    -filter_complex \
"[0:v]trim=start_frame=0:end_frame=40,setpts=PTS-STARTPTS,fps=60000/1001,setpts=N*1001/(60000*TB),scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v0];
[1:v]trim=start_frame=12:end_frame=24,setpts=PTS-STARTPTS,fps=60000/1001,setpts=N*1001/(60000*TB),scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v1];
[2:v]trim=start_frame=40:end_frame=60,setpts=PTS-STARTPTS,fps=60000/1001,setpts=N*1001/(60000*TB),scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v2];
[0:a]atrim=start=0:end=0.667333333333,asetpts=PTS-STARTPTS,aresample=48000[a0];
[1:a]atrim=start=0.5:end=1,asetpts=PTS-STARTPTS,atempo=0.999000999,atrim=duration=0.5005,aresample=48000[a1];
[2:a]atrim=start=0.667333333333:end=1.001,asetpts=PTS-STARTPTS,aresample=48000[a2];
[v0][a0][v1][a1][v2][a2]concat=n=3:v=1:a=1[v][a]" \
    -map "[v]" -map "[a]" \
    -r 60000/1001 -fps_mode cfr \
    -c:v prores_ks -profile:v 2 -pix_fmt yuv422p10le \
    -c:a pcm_s16le "$HIGH_FF_OUTPUT"

probe_output() {
    local input="$1"
    "$FFPROBE" -v error -count_frames \
        -show_entries stream=codec_type,width,height,avg_frame_rate,nb_read_frames,duration,sample_rate,channels:format=duration \
        -of json "$input"
}

AV_FACTS="$(probe_output "$AV_OUTPUT")"
FF_FACTS="$(probe_output "$FF_OUTPUT")"

for facts in "$AV_FACTS" "$FF_FACTS"; do
    jq -e '
        ([.streams[] | select(.codec_type == "video")][0]) as $video
        | ([.streams[] | select(.codec_type == "audio")][0]) as $audio
        | $video.width == 320
        and $video.height == 180
        and $video.avg_frame_rate == "24/1"
        and $video.nb_read_frames == "60"
        and (($video.duration | tonumber) - 2.5 | fabs) < 0.000001
        and $audio.sample_rate == "48000"
        and $audio.channels == 2
    ' <<< "$facts" >/dev/null
done

HIGH_AV_FACTS="$(probe_output "$HIGH_AV_OUTPUT")"
HIGH_FF_FACTS="$(probe_output "$HIGH_FF_OUTPUT")"
for facts in "$HIGH_AV_FACTS" "$HIGH_FF_FACTS"; do
    jq -e '
        ([.streams[] | select(.codec_type == "video")][0]) as $video
        | ([.streams[] | select(.codec_type == "audio")][0]) as $audio
        | $video.width == 320
        and $video.height == 180
        and $video.avg_frame_rate == "60000/1001"
        and $video.nb_read_frames == "90"
        and (($video.duration | tonumber) - 1.5015 | fabs) < 0.000001
        and $audio.sample_rate == "48000"
        and $audio.channels == 2
    ' <<< "$facts" >/dev/null
done

jq -e '
    .duration == "60/24"
    and (.segments | length) == 3
    and .segments[0].timelineStart == "0/1"
    and .segments[0].timelineDuration == "24/24"
    and .segments[1].sourceDuration == "30030/30000"
    and .segments[1].timelineDuration == "24/24"
    and .segments[2].timelineStart == "48/24"
    and .segments[2].timelineDuration == "12/24"
' "$MANIFEST" >/dev/null

jq -e '
    .duration == "90090/60000"
    and .frameRate == "60000/1001"
    and (.segments | length) == 3
    and .segments[0].timelineDuration == "40040/60000"
    and .segments[1].sourceDuration == "12/24"
    and .segments[1].timelineDuration == "30030/60000"
    and .segments[2].timelineStart == "70070/60000"
    and .segments[2].timelineDuration == "20020/60000"
' "$HIGH_MANIFEST" >/dev/null

SSIM_LOG="$WORK/ssim.log"
"$FFMPEG" -hide_banner -i "$AV_OUTPUT" -i "$FF_OUTPUT" \
    -lavfi "[0:v]format=yuv420p[av];[1:v]format=yuv420p[ff];[av][ff]ssim=stats_file=${SSIM_LOG}" \
    -f null - >/dev/null 2>&1
read -r AVERAGE_SSIM MINIMUM_SSIM <<< "$(awk '
    BEGIN { minimum = 1; sum = 0; count = 0 }
    {
        for (i = 1; i <= NF; i++) if ($i ~ /^All:/) {
            split($i, value, ":")
            sum += value[2]
            count++
            if (value[2] < minimum) minimum = value[2]
        }
    }
    END { if (count == 0) exit 1; print sum / count, minimum }
' "$SSIM_LOG")"

awk -v average="$AVERAGE_SSIM" -v minimum="$MINIMUM_SSIM" 'BEGIN { if (average < 0.90 || minimum < 0.75) exit 1 }'

HIGH_SSIM_LOG="$WORK/high-rate-ssim.log"
"$FFMPEG" -hide_banner -i "$HIGH_AV_OUTPUT" -i "$HIGH_FF_OUTPUT" \
    -lavfi "[0:v]format=yuv420p[av];[1:v]format=yuv420p[ff];[av][ff]ssim=stats_file=${HIGH_SSIM_LOG}" \
    -f null - >/dev/null 2>&1
read -r HIGH_AVERAGE_SSIM HIGH_MINIMUM_SSIM <<< "$(awk '
    BEGIN { minimum = 1; sum = 0; count = 0 }
    {
        for (i = 1; i <= NF; i++) if ($i ~ /^All:/) {
            split($i, value, ":")
            sum += value[2]
            count++
            if (value[2] < minimum) minimum = value[2]
        }
    }
    END { if (count == 0) exit 1; print sum / count, minimum }
' "$HIGH_SSIM_LOG")"
awk -v average="$HIGH_AVERAGE_SSIM" -v minimum="$HIGH_MINIMUM_SSIM" 'BEGIN { if (average < 0.90 || minimum < 0.75) exit 1 }'

padding_luma() {
    local input="$1"
    local y="$2"
    "$FFMPEG" -hide_banner -loglevel info -ss 1.25 -i "$input" -frames:v 1 \
        -vf "crop=320:20:0:${y},signalstats,metadata=print" -f null - 2>&1 \
        | awk -F= '/lavfi.signalstats.YAVG/ { value=$2 } END { print value }'
}

for output in "$AV_OUTPUT" "$FF_OUTPUT"; do
    TOP_LUMA="$(padding_luma "$output" 0)"
    BOTTOM_LUMA="$(padding_luma "$output" 160)"
    awk -v top="$TOP_LUMA" -v bottom="$BOTTOM_LUMA" 'BEGIN {
        if (top > 66 || bottom > 66) exit 1
    }'
done

tone_zero_crossing_rate() {
    local input="$1"
    local start="$2"
    "$FFMPEG" -hide_banner -ss "$start" -t 0.2 -i "$input" -vn \
        -af "astats=metadata=0:reset=0" -f null - 2>&1 \
        | awk -F': ' '/Zero crossings rate/ { value=$2 } END { print value }'
}

for output in "$AV_OUTPUT" "$FF_OUTPUT"; do
    RATE_440_A="$(tone_zero_crossing_rate "$output" 0.25)"
    RATE_550="$(tone_zero_crossing_rate "$output" 1.25)"
    RATE_440_B="$(tone_zero_crossing_rate "$output" 2.25)"
    awk -v a="$RATE_440_A" -v b="$RATE_550" -v c="$RATE_440_B" 'BEGIN {
        if (a < 0.017 || a > 0.020) exit 1
        if (b < 0.021 || b > 0.025) exit 1
        if (c < 0.017 || c > 0.020) exit 1
    }'
done

for output in "$HIGH_AV_OUTPUT" "$HIGH_FF_OUTPUT"; do
    RATE_770_A="$(tone_zero_crossing_rate "$output" 0.25)"
    RATE_440="$(tone_zero_crossing_rate "$output" 0.85)"
    RATE_770_B="$(tone_zero_crossing_rate "$output" 1.3)"
    awk -v a="$RATE_770_A" -v b="$RATE_440" -v c="$RATE_770_B" 'BEGIN {
        if (a < 0.030 || a > 0.034) exit 1
        if (b < 0.017 || b > 0.020) exit 1
        if (c < 0.030 || c > 0.034) exit 1
    }'
done

echo "AVFoundation and FFmpeg each produced 60 frames at 320x180, 24 fps, and 2.5 seconds."
echo "Video similarity: average SSIM=$AVERAGE_SSIM, minimum per-frame SSIM=$MINIMUM_SSIM"
echo "The 426x180 clip is aspect-fitted with matching centered black padding."
echo "Audio tone regions follow 440 Hz -> 550 Hz -> 440 Hz in both outputs."
echo "60000/1001 parity: 90 frames over 1.5015 seconds, average SSIM=$HIGH_AVERAGE_SSIM, minimum=$HIGH_MINIMUM_SSIM"
echo "High-rate audio regions follow 770 Hz -> 440 Hz -> 770 Hz in both outputs."
echo "T02 spike artifacts: $WORK"
