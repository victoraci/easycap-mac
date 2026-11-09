#!/bin/sh
# Aufnahme vom ezcap 116: verlustfrei als FFV1 in MKV, dazu Live-Vorschau.
#
#   ./aufnahme.sh                       speichert nach aufnahmen/vhs_DATUM_ZEIT.mkv
#   ./aufnahme.sh -s                    weitere Optionen gehen an ./ezcap (z. B. -s = S-Video)
#   ZIEL=/Volumes/Platte ./aufnahme.sh  woanders speichern
#
# Stoppen: Ctrl+C im Terminal. Glitch-Regler wie bei vorschau.sh (h = Hilfe).
# Das Vorschaufenster zu schliessen stoppt die Aufnahme NICHT.
#
# Gespeichert wird genau das, was der Stick liefert: Halbbilder verzahnt (oberes zuerst),
# YUV 4:2:2, PAL-Farbraum, Seitenverhaeltnis 59:54. Nichts geglaettet, nichts geschaerft.

cd "$(dirname "$0")" || exit 1

ZIEL=${ZIEL:-aufnahmen}
mkdir -p "$ZIEL" || exit 1
DATEI="$ZIEL/vhs_$(date +%Y-%m-%d_%H-%M-%S).mkv"

FREI=$(df -g "$ZIEL" | awk 'NR == 2 { print $4 }')
echo "Aufnahme nach $DATEI" >&2
echo "$FREI GB frei (grob 25-40 GB pro Stunde, je nach Rauschen auf dem Band)" >&2

# Ctrl+C geht an alle Programme der Kette; das Skript selbst soll danach weiterlaufen
trap ':' INT

# ffmpeg-Meldungen erst sammeln, damit sie die Statuszeile nicht zerschiessen
LOG=$(mktemp -t ezcap-ffmpeg) || exit 1

# Aufnahme: Farbraum/Halbbild-Infos an die Bilder haengen, dann FFV1 (Level 3,
# jedes Bild einzeln, 16 Slices mit Pruefsumme -> robust gegen Bitfehler).
# Ein T-Stueck (tee) schickt das Ergebnis in die Datei und an die Vorschau;
# die Vorschau darf ausfallen oder haengen, ohne die Aufnahme zu stoeren.
VF_REC="setparams=field_mode=tff:range=tv:colorspace=bt470bg:color_primaries=bt470bg:color_trc=smpte170m,setsar=59/54"
VF_VOR="bwdif=mode=send_field:parity=tff,setsar=59/54"

./ezcap -R "$DATEI" "$@" \
| ffmpeg -hide_banner -loglevel error -nostats \
    -f rawvideo -pixel_format yuyv422 -video_size 720x576 -framerate 25 -i - \
    -vf "$VF_REC" \
    -c:v ffv1 -level 3 -g 1 -slices 16 -slicecrc 1 -context 1 -pix_fmt yuv422p \
    -color_range tv -colorspace bt470bg -color_primaries bt470bg -color_trc smpte170m \
    -map 0:v -f tee "$DATEI|[f=nut:onfail=ignore:use_fifo=1:fifo_options=drop_pkts_on_overflow\=1]pipe:1" \
    2>"$LOG" \
| ffplay -hide_banner -loglevel error -nostats -autoexit \
    -fflags nobuffer -flags low_delay -framedrop \
    -i - -vf "$VF_VOR" -window_title "ezcap VHS  REC"

# "Slave muxer failed" heisst nur: Vorschaufenster ist zu. Alles andere zeigen.
grep -v "Slave muxer" "$LOG" >&2
rm -f "$LOG"

if [ -s "$DATEI" ]; then
    DAUER=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$DATEI" 2>/dev/null)
    echo "Gespeichert: $DATEI  ($(du -h "$DATEI" | cut -f1), ${DAUER%.*} s)" >&2
else
    echo "Keine Aufnahme gespeichert." >&2
fi
