// streamtest.c – Datenfluss-Test fuer den ezcap 116 (EM2860 + SAA7113).
// Initialisiert den Stick (hw.c), empfaengt ein paar Sekunden isochrone Pakete,
// zeigt Statistik und speichert ein Vollbild als frame.yuyv (720x576, YUYV).
//
// Bauen: make streamtest      Start: ./streamtest [-a alt] [-t sekunden] [-s] [-v]

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>
#include "hw.h"

static volatile int running = 1;

static struct {
    long noheader;
    long fields, top, bottom, field_ok, field_short, field_long;
    long field_min, field_max;
    long cur;                   // Bytes im aktuellen Halbbild
    int  cur_top, in_field;
} st;

static uint8_t frame[EZ_LINE_BYTES * EZ_HEIGHT];
static int frame_state;         // 0 = suchen, 1 = oberes Halbbild drin, 2 = fertig
static long fields_to_skip = 25;

static void field_done(void)
{
    st.fields++;
    if (st.fields == 1 || st.cur < st.field_min) st.field_min = st.cur;
    if (st.cur > st.field_max) st.field_max = st.cur;
    if (st.cur == EZ_FIELD_BYTES) st.field_ok++;
    else if (st.cur < EZ_FIELD_BYTES) st.field_short++;
    else st.field_long++;

    if (frame_state < 2 && st.fields > fields_to_skip && st.cur >= EZ_FIELD_BYTES) {
        if (st.cur_top) frame_state = 1;
        else if (frame_state == 1) frame_state = 2;
    }
}

// Halbbild-Daten zeilenweise ins Vollbild "verzahnen" (oben = gerade Zeilen)
static void copy_video(const uint8_t *p, int len)
{
    if (frame_state == 2 || st.fields < fields_to_skip) return;
    if (frame_state == 0 && !st.cur_top) return;
    long pos = st.cur;
    while (len > 0 && pos < EZ_FIELD_BYTES) {
        long line = pos / EZ_LINE_BYTES, col = pos % EZ_LINE_BYTES;
        int n = EZ_LINE_BYTES - col < len ? EZ_LINE_BYTES - col : len;
        long row = line * 2 + (st.cur_top ? 0 : 1);
        memcpy(frame + row * EZ_LINE_BYTES + col, p, n);
        p += n; len -= n; pos += n;
    }
}

static int verbose;

static void dump_head(const char *what, const uint8_t *p, int len)
{
    printf("    %s (%4d B):", what, len);
    for (int i = 0; i < 12 && i < len; i++) printf(" %02x", p[i]);
    printf("  ...");
    for (int i = len > 12 ? len - 12 : 0; i < len; i++) printf(" %02x", p[i]);
    printf("\n");
}

// Jedes isochrone Paket beginnt mit 4 Bytes Kopf:
//   22 5a xx 88  = neues Halbbild, xx = Zaehler, Bit 0: 0 = oberes, 1 = unteres
//   88 88 88 88  = Fortsetzung
// Am Ende jedes Halbbilds haengt noch ein Marker: c6 93 93 93
static void handle_packet(const uint8_t *p, int len)
{
    static const uint8_t *prev; static int prev_len;
    if (verbose && st.fields > 5 && st.fields < 9) {
        if (len >= 4 && p[0] == 0x22 && p[1] == 0x5a) {
            dump_head("letztes Paket", prev, prev_len);
            dump_head("Halbbild-Start", p, len);
        }
    }
    prev = p; prev_len = len;

    if (len >= 4 && p[0] == 0x22 && p[1] == 0x5a) {
        if (st.in_field) field_done();
        st.in_field = 1;
        st.cur = 0;
        st.cur_top = !(p[2] & 1);
        if (st.cur_top) st.top++; else st.bottom++;
        p += 4; len -= 4;
    } else if (len >= 4 && p[0] == 0x88 && p[1] == 0x88 && p[2] == 0x88 && p[3] == 0x88) {
        p += 4; len -= 4;
    } else {
        st.noheader++;
    }
    if (!st.in_field) return;
    if (st.cur + len == EZ_FIELD_BYTES + 4 && !memcmp(p + len - 4, "\xc6\x93\x93\x93", 4))
        len -= 4;
    copy_video(p, len);
    st.cur += len;
}

static void on_sigint(int s) { (void)s; running = 0; }

int main(int argc, char **argv)
{
    int alt = 7, seconds = 5, svideo = 0, opt;
    while ((opt = getopt(argc, argv, "a:t:sv")) != -1) {
        if (opt == 'a') alt = atoi(optarg);
        else if (opt == 't') seconds = atoi(optarg);
        else if (opt == 's') svideo = 1;
        else if (opt == 'v') verbose = 1;
        else { fprintf(stderr, "Aufruf: %s [-a alt] [-t sekunden] [-s] [-v]\n", argv[0]); return 1; }
    }

    if (ez_open(svideo) < 0) return 1;
    printf("Chip-ID: %d (34 = EM2860)\n", ez_reg_read(0x0a));
    printf("Decoder-Status (Reg 0x1f): 0x%02x\n", ez_saa_read(0x1f));

    int pkt = ez_stream_start(alt, handle_packet);
    if (pkt < 0) { ez_close(); return 1; }
    printf("Alt-Setting %d aktiv, %d Bytes pro Microframe (= %.1f MB/s reserviert)\n",
           alt, pkt, pkt * 8000.0 / 1e6);

    signal(SIGINT, on_sigint);
    time_t start = time(NULL), last = start;
    long last_bytes = 0, last_fields = 0;
    while (running && time(NULL) - start < seconds) {
        ez_stream_poll(100);
        if (time(NULL) != last) {
            last = time(NULL);
            printf("  %5.1f MB/s  %3ld Halbbilder/s  Pakete: %ld (leer %ld, Fehler %ld)\n",
                   (ez_stats.bytes - last_bytes) / 1e6, st.fields - last_fields,
                   ez_stats.packets, ez_stats.empty, ez_stats.errors);
            last_bytes = ez_stats.bytes; last_fields = st.fields;
        }
    }
    ez_stream_stop();
    ez_close();

    printf("\nGesamt: %.1f MB, %ld Pakete (leer %ld, Fehler %ld, ohne Kopf %ld)\n",
           ez_stats.bytes / 1e6, ez_stats.packets, ez_stats.empty, ez_stats.errors, st.noheader);
    printf("Halbbilder: %ld (oben %ld, unten %ld) | Groesse: %ld exakt %d B, %ld kuerzer, %ld laenger\n",
           st.fields, st.top, st.bottom, st.field_ok, EZ_FIELD_BYTES, st.field_short, st.field_long);
    printf("Halbbild-Groesse: min %ld, max %ld Bytes (= %.2f bis %.2f Zeilen)\n",
           st.field_min, st.field_max, st.field_min / (double)EZ_LINE_BYTES, st.field_max / (double)EZ_LINE_BYTES);

    if (frame_state == 2) {
        FILE *f = fopen("frame.yuyv", "wb");
        fwrite(frame, 1, sizeof frame, f);
        fclose(f);
        printf("Vollbild gespeichert: frame.yuyv (720x576 YUYV)\n");
    } else {
        printf("Kein vollstaendiges Bild zum Speichern.\n");
    }
    return 0;
}
