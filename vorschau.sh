#!/bin/sh
# Live-Vorschau vom ezcap 116 in ffplay.
#
#   ./vorschau.sh            50 Bilder/s, Halbbilder einzeln (fluessig wie am Roehren-TV)
#   ./vorschau.sh roh        25 Vollbilder, Halbbilder verzahnt (Kammeffekt bei Bewegung)
#   ./vorschau.sh -s         S-Video statt Composite (weitere Optionen gehen an ./ezcap)
#
# Regler: Tasten hier im Terminal (h = Hilfe). Im Videofenster: f = Vollbild, q = Ende.

cd "$(dirname "$0")" || exit 1

MODE=fluessig
if [ "$1" = roh ]; then MODE=roh; shift; fi

# PAL nach BT.601: begrenzter Wertebereich (16-235), PAL-Farbmatrix, oberes Halbbild zuerst.
# PAL-Pixel sind etwas breiter als hoch (59:54), sonst wirkt alles gestaucht.
VF="setparams=field_mode=tff:range=tv:colorspace=bt470bg:color_primaries=bt470bg:color_trc=smpte170m"
if [ "$MODE" = fluessig ]; then
    VF="$VF,bwdif=mode=send_field:parity=tff"
fi
VF="$VF,setsar=59/54"

./ezcap "$@" | ffplay -hide_banner -loglevel error -nostats \
    -fflags nobuffer -flags low_delay -framedrop \
    -f rawvideo -pixel_format yuyv422 -video_size 720x576 -framerate 25 -i - \
    -vf "$VF" -window_title "ezcap VHS"
