#!/bin/sh
# Live preview from the grabber in ffplay.
#
#   ./preview.sh             50 frames/s, every field on its own (smooth like a CRT TV)
#   ./preview.sh raw         25 frames, fields interlaced (combing on motion)
#   ./preview.sh -s          S-Video instead of composite (other options go to ./ezcap)
#
# Controls: keys here in the terminal (h = help). In the video window: f = full screen, q = quit.

cd "$(dirname "$0")" || exit 1

MODE=smooth
if [ "$1" = raw ]; then MODE=raw; shift; fi

# PAL per BT.601: limited range (16-235), PAL color matrix, top field first.
# PAL pixels are slightly wider than tall (59:54), otherwise everything looks squashed.
VF="setparams=field_mode=tff:range=tv:colorspace=bt470bg:color_primaries=bt470bg:color_trc=smpte170m"
if [ "$MODE" = smooth ]; then
    VF="$VF,bwdif=mode=send_field:parity=tff"
fi
VF="$VF,setsar=59/54"

./ezcap "$@" | ffplay -hide_banner -loglevel error -nostats \
    -fflags nobuffer -flags low_delay -framedrop \
    -f rawvideo -pixel_format yuyv422 -video_size 720x576 -framerate 25 -i - \
    -vf "$VF" -window_title "easycap"
