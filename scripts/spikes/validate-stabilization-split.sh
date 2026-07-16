#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"
AWK_SCRIPT="$ROOT/scripts/spikes/slice-vidstab-local-motions.awk"
BASE="$ROOT/.build/timeline-spikes"
FONT="/System/Library/Fonts/Monaco.ttf"

mkdir -p "$BASE"
WORK="$(mktemp -d "$BASE/t01.XXXXXX")"

if [[ -z "$FFMPEG" || ! -x "$FFMPEG" ]]; then
    echo "A runnable ffmpeg executable is required." >&2
    exit 1
fi

if [[ ! -f "$FONT" ]]; then
    echo "Missing fixture font: $FONT" >&2
    exit 1
fi

make_shaky_source() {
    local output="$1"
    local rate="$2"
    local duration="$3"

    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=360x220:rate=${rate}:duration=${duration}" \
        -vf "crop=320:180:x='20+8*sin(n*1.7)':y='20+6*cos(n*1.3)',drawtext=fontfile=${FONT}:text='FRAME %{n}':fontcolor=white:fontsize=24:box=1:boxcolor=black@0.7:x=(w-text_w)/2:y=(h-text_h)/2,setparams=range=full:color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$output"
}

analyze() {
    local input="$1"
    local transforms="$2"

    "$FFMPEG" -hide_banner -loglevel error -y -i "$input" \
        -vf "vidstabdetect=result=${transforms}:shakiness=5:accuracy=9:stepsize=12:fileformat=ascii" \
        -an -f null -
}

transform_filter() {
    local transforms="$1"
    echo "vidstabtransform=input=${transforms}:smoothing=8:optzoom=2:interpol=bicubic"
}

render() {
    local metric="$1"
    shift
    /usr/bin/time -p -o "$metric" "$FFMPEG" -hide_banner -loglevel error -y "$@"
}

frame_hashes() {
    local input="$1"
    local output="$2"
    "$FFMPEG" -hide_banner -loglevel error -i "$input" -map 0:v:0 -f framemd5 "$output"
}

assert_same_frames() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if ! cmp -s "$expected" "$actual"; then
        echo "Frame mismatch: $message" >&2
        exit 1
    fi
}

assert_different_frames() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if cmp -s "$expected" "$actual"; then
        echo "Unexpected frame equality: $message" >&2
        exit 1
    fi
}

validate_rate() {
    local label="$1"
    local rate="$2"
    local duration="$3"
    local start="$4"
    local midpoint="$5"
    local end="$6"
    local directory="$WORK/$label"
    local source="$directory/source.mkv"
    local transforms="$directory/full.trf"
    local sliced="$directory/sliced.trf"
    local full="$directory/full-stabilized.mkv"
    local reference="$directory/reference-child.mkv"
    local inline="$directory/full-domain-inline-child.mkv"
    local naive="$directory/naive-sliced-child.mkv"
    local shared_a="$directory/shared-a.mkv"
    local shared_b="$directory/shared-b.mkv"

    mkdir -p "$directory"
    make_shaky_source "$source" "$rate" "$duration"
    analyze "$source" "$transforms"
    awk -v start="$start" -v end="$end" -f "$AWK_SCRIPT" "$transforms" > "$sliced"

    render "$directory/full.time" -i "$source" \
        -vf "$(transform_filter "$transforms")" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$full"

    render "$directory/reference.time" -i "$full" \
        -vf "trim=start_frame=${start}:end_frame=${end},setpts=PTS-STARTPTS" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$reference"

    render "$directory/inline.time" -i "$source" \
        -vf "$(transform_filter "$transforms"),trim=start_frame=${start}:end_frame=${end},setpts=PTS-STARTPTS" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$inline"

    render "$directory/naive.time" -i "$source" \
        -vf "trim=start_frame=${start}:end_frame=${end},setpts=PTS-STARTPTS,$(transform_filter "$sliced")" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$naive"

    render "$directory/shared.time" -i "$source" \
        -filter_complex "[0:v]$(transform_filter "$transforms"),split=2[parentA][parentB];[parentA]trim=start_frame=${start}:end_frame=${midpoint},setpts=PTS-STARTPTS[childA];[parentB]trim=start_frame=${midpoint}:end_frame=${end},setpts=PTS-STARTPTS[childB]" \
        -map "[childA]" -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$shared_a" \
        -map "[childB]" -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$shared_b"

    render "$directory/repeated-a.time" -i "$source" \
        -vf "$(transform_filter "$transforms"),trim=start_frame=${start}:end_frame=${midpoint},setpts=PTS-STARTPTS" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$directory/repeated-a.mkv"
    render "$directory/repeated-b.time" -i "$source" \
        -vf "$(transform_filter "$transforms"),trim=start_frame=${midpoint}:end_frame=${end},setpts=PTS-STARTPTS" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$directory/repeated-b.mkv"

    frame_hashes "$reference" "$directory/reference.md5"
    frame_hashes "$inline" "$directory/inline.md5"
    frame_hashes "$naive" "$directory/naive.md5"
    frame_hashes "$shared_a" "$directory/shared-a.md5"
    frame_hashes "$shared_b" "$directory/shared-b.md5"
    frame_hashes "$directory/repeated-a.mkv" "$directory/repeated-a.md5"
    frame_hashes "$directory/repeated-b.mkv" "$directory/repeated-b.md5"

    "$FFMPEG" -hide_banner -loglevel error -i "$full" \
        -vf "trim=start_frame=${start}:end_frame=${midpoint},setpts=PTS-STARTPTS" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$directory/reference-a.mkv"
    "$FFMPEG" -hide_banner -loglevel error -i "$full" \
        -vf "trim=start_frame=${midpoint}:end_frame=${end},setpts=PTS-STARTPTS" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$directory/reference-b.mkv"
    frame_hashes "$directory/reference-a.mkv" "$directory/reference-a.md5"
    frame_hashes "$directory/reference-b.mkv" "$directory/reference-b.md5"

    assert_same_frames "$directory/reference.md5" "$directory/inline.md5" "$label full-domain trim"
    assert_different_frames "$directory/reference.md5" "$directory/naive.md5" "$label naively sliced local motions"
    assert_same_frames "$directory/reference-a.md5" "$directory/shared-a.md5" "$label shared branch A"
    assert_same_frames "$directory/reference-b.md5" "$directory/shared-b.md5" "$label shared branch B"
    assert_same_frames "$directory/reference-a.md5" "$directory/repeated-a.md5" "$label repeated branch A"
    assert_same_frames "$directory/reference-b.md5" "$directory/repeated-b.md5" "$label repeated branch B"

    echo "$label: full-domain and shared-prefix children match; naively sliced local motions differ."
}

validate_stacked_passes() {
    local directory="$WORK/stacked-24"
    local source="$WORK/24fps/source.mkv"
    local first="$WORK/24fps/full.trf"
    local first_render="$WORK/24fps/full-stabilized.mkv"
    local second="$directory/second.trf"
    local stacked="$directory/full-stacked.mkv"
    local child="$directory/stacked-child.mkv"
    local reference="$directory/reference-child.mkv"
    local first_filter="$(transform_filter "$first")"
    local second_filter

    mkdir -p "$directory"
    analyze "$first_render" "$second"
    second_filter="$(transform_filter "$second")"

    render "$directory/full.time" -i "$source" \
        -vf "${first_filter},${second_filter}" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$stacked"
    render "$directory/child.time" -i "$source" \
        -vf "${first_filter},${second_filter},trim=start_frame=24:end_frame=72,setpts=PTS-STARTPTS" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$child"
    "$FFMPEG" -hide_banner -loglevel error -y -i "$stacked" \
        -vf "trim=start_frame=24:end_frame=72,setpts=PTS-STARTPTS" \
        -c:v ffv1 -level 3 -pix_fmt yuv420p -an "$reference"

    frame_hashes "$child" "$directory/child.md5"
    frame_hashes "$reference" "$directory/reference.md5"
    assert_same_frames "$directory/reference.md5" "$directory/child.md5" "stacked full-domain trim"
    echo "stacked-24: two-pass full-domain child matches the stacked reference."
}

validate_rate "24fps" "24" "4" 24 48 72
validate_rate "60000-1001" "60000/1001" "2.002" 30 60 90
validate_stacked_passes

echo
echo "Timing and disk metrics:"
for directory in "$WORK/24fps" "$WORK/60000-1001" "$WORK/stacked-24"; do
    echo "$(basename "$directory")"
    for metric in "$directory"/*.time; do
        echo "  $(basename "$metric" .time): $(tr '\n' ' ' < "$metric")"
    done
    du -kh "$directory" | tail -n 1
done

echo
echo "T01 spike artifacts: $WORK"
