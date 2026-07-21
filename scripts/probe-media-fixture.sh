#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <media-file>" >&2
    exit 2
fi

FFPROBE="${FFPROBE:-$(command -v ffprobe)}"
if [[ -z "$FFPROBE" || ! -x "$FFPROBE" ]]; then
    echo "A runnable ffprobe executable is required." >&2
    exit 1
fi

"$FFPROBE" -v error -count_frames \
    -show_entries \
stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,nb_read_frames,sample_rate,channels,color_range,color_space,color_transfer,color_primaries:format=duration \
    -of json "$1"
