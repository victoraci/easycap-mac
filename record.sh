#!/bin/sh
# Recording from the grabber: lossless FFV1 in MKV, plus a live preview.
#
#   ./record.sh                         saves to recordings/vhs_DATE_TIME.mkv
#   ./record.sh -s                      other options go to ./ezcap (e.g. -s = S-Video)
#   OUT=/Volumes/Disk ./record.sh       save somewhere else
#
# Stop: Ctrl+C in the terminal. Glitch controls as in preview.sh (h = help).
# Closing the preview window does NOT stop the recording.
#
# What gets saved is exactly what the stick delivers: fields interlaced (top first),
# YUV 4:2:2, PAL color space, aspect ratio 59:54. Nothing smoothed, nothing sharpened.

cd "$(dirname "$0")" || exit 1

OUT=${OUT:-recordings}
mkdir -p "$OUT" || exit 1
FILE="$OUT/vhs_$(date +%Y-%m-%d_%H-%M-%S).mkv"

FREE=$(df -g "$OUT" | awk 'NR == 2 { print $4 }')
echo "Recording to $FILE" >&2
echo "$FREE GB free (roughly 25-40 GB per hour, depending on the noise on the tape)" >&2

# Ctrl+C goes to every program in the chain; the script itself should keep running afterwards
trap ':' INT

# Collect ffmpeg's messages first, so they don't wreck the status line
LOG=$(mktemp -t easycap-ffmpeg) || exit 1

# Recording: attach color space/field info to the frames, then FFV1 (level 3,
# every frame on its own, 16 slices with checksums -> robust against bit errors).
# A tee sends the result to the file and to the preview;
# the preview may fail or hang without disturbing the recording.
VF_REC="setparams=field_mode=tff:range=tv:colorspace=bt470bg:color_primaries=bt470bg:color_trc=smpte170m,setsar=59/54"
VF_PREVIEW="bwdif=mode=send_field:parity=tff,setsar=59/54"

./ezcap -R "$FILE" "$@" \
| ffmpeg -hide_banner -loglevel error -nostats \
    -f rawvideo -pixel_format yuyv422 -video_size 720x576 -framerate 25 -i - \
    -vf "$VF_REC" \
    -c:v ffv1 -level 3 -g 1 -slices 16 -slicecrc 1 -context 1 -pix_fmt yuv422p \
    -color_range tv -colorspace bt470bg -color_primaries bt470bg -color_trc smpte170m \
    -map 0:v -f tee "$FILE|[f=nut:onfail=ignore:use_fifo=1:fifo_options=drop_pkts_on_overflow\=1]pipe:1" \
    2>"$LOG" \
| ffplay -hide_banner -loglevel error -nostats -autoexit \
    -fflags nobuffer -flags low_delay -framedrop \
    -i - -vf "$VF_PREVIEW" -window_title "easycap  REC"

# "Slave muxer failed" only means the preview window is closed. Show everything else.
grep -v "Slave muxer" "$LOG" >&2
rm -f "$LOG"

if [ -s "$FILE" ]; then
    DURATION=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$FILE" 2>/dev/null)
    echo "Saved: $FILE  ($(du -h "$FILE" | cut -f1), ${DURATION%.*} s)" >&2
else
    echo "Nothing saved." >&2
fi
