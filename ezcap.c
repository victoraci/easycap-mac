// ezcap.c – Live-Video vom ezcap 116 als Rohdaten auf stdout, mit Glitch-Reglern.
//
// Ausgabe: 720x576, YUYV (ffmpeg: yuyv422), 25 Vollbilder/s,
//          Halbbilder zeilenweise verzahnt, oberes Halbbild zuerst.
// Statuszeile jede Sekunde auf stderr. Tasten im Terminal verstellen den Decoder live
// (Liste mit "h"). Alles ist fluechtig: Stick ab- und anstecken = Werkszustand.
//
// Beispiel: ./ezcap | ffplay -f rawvideo -pixel_format yuyv422 -video_size 720x576 -framerate 25 -i -
// (fertig verpackt in vorschau.sh)
//
// Bauen: make ezcap
// Start: ./ezcap [-a alt] [-t sekunden] [-s] [-q] [-r reg=wert ...] [-R datei]
//   -s  S-Video statt Composite     -q  keine Statuszeile
//   -r  Decoder-Register direkt setzen (hex), z. B. -r 08=2c
//   -R  REC-Anzeige mit Laufzeit und Groesse dieser Datei (fuer aufnahme.sh)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <termios.h>
#include <sys/stat.h>
#include "hw.h"

#define FRAME_BYTES (EZ_LINE_BYTES * EZ_HEIGHT)
#define SLOTS 4                     // Puffer zwischen USB und Ausgabe (= 160 ms)

static volatile int running = 1;

// ------------------------------------------------------------ Bild bauen --

// Halbbilder werden direkt in dieses Bild geschrieben. Fehlt mal eines, bleiben
// einfach die alten Zeilen stehen – wie Nachleuchten auf der Roehre.
static uint8_t work[FRAME_BYTES];
static long pos;                    // Bytes im aktuellen Halbbild
static int in_field, cur_top, field_closed, swap_fields;

// Ringpuffer USB -> Schreib-Thread
static uint8_t slot[SLOTS][FRAME_BYTES];
static int head, tail, count;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake = PTHREAD_COND_INITIALIZER;

static long frames_out, frames_dropped, frames_capped, frames_passed;
static double t_start;
static const char *rec_path;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void field_end(void)
{
    if (!in_field || field_closed) return;
    field_closed = 1;
    if (cur_top) return;            // Vollbild ist erst nach dem unteren Halbbild fertig

    // Drossel: nie mehr als 25 Bilder/s raus. Im erzwungenen 60-Hz-Modus kommen ~30,
    // die wuerden sich sonst in ffplay stauen und die Vorschau immer spaeter machen.
    if (frames_passed >= (now() - t_start) * 25 + 2) {
        frames_capped++;
        return;
    }
    frames_passed++;

    pthread_mutex_lock(&lock);
    if (count < SLOTS) {
        memcpy(slot[head], work, FRAME_BYTES);
        head = (head + 1) % SLOTS;
        count++;
        pthread_cond_signal(&wake);
    } else {
        frames_dropped++;           // Abnehmer (ffplay/ffmpeg) kommt nicht hinterher
    }
    pthread_mutex_unlock(&lock);
}

static void put_video(const uint8_t *p, int len)
{
    int row_offset = (cur_top != swap_fields) ? 0 : 1;
    long at = pos;
    while (len > 0 && at < EZ_FIELD_BYTES) {
        long line = at / EZ_LINE_BYTES, col = at % EZ_LINE_BYTES;
        int n = EZ_LINE_BYTES - col < len ? EZ_LINE_BYTES - col : len;
        memcpy(work + (line * 2 + row_offset) * EZ_LINE_BYTES + col, p, n);
        p += n; len -= n; at += n;
    }
}

// Kopf: 22 5a xx 88 = neues Halbbild (Bit 0 von xx: 0 = oben), 88 88 88 88 = weiter,
// Ende-Marker c6 93 93 93. Siehe streamtest.c.
static void on_packet(const uint8_t *p, int len)
{
    if (len >= 4 && p[0] == 0x22 && p[1] == 0x5a) {
        field_end();
        in_field = 1;
        field_closed = 0;
        pos = 0;
        cur_top = !(p[2] & 1);
        p += 4; len -= 4;
    } else if (len >= 4 && !memcmp(p, "\x88\x88\x88\x88", 4)) {
        p += 4; len -= 4;
    }
    if (!in_field || field_closed) return;
    if (pos + len == EZ_FIELD_BYTES + 4 && !memcmp(p + len - 4, "\xc6\x93\x93\x93", 4))
        len -= 4;
    put_video(p, len);
    pos += len;
    if (pos >= EZ_FIELD_BYTES) field_end();
}

// ------------------------------------------------------------- Ausgabe --

static int write_all(const uint8_t *p, size_t n)
{
    while (n > 0) {
        ssize_t w = write(1, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return 0;               // z. B. ffplay-Fenster geschlossen (EPIPE)
        }
        p += w; n -= w;
    }
    return 1;
}

// Eigener Thread, damit ein langsamer Abnehmer nie den USB-Empfang blockiert.
static void *writer(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&lock);
    while (running) {
        if (count == 0) {
            pthread_cond_wait(&wake, &lock);
            continue;
        }
        uint8_t *f = slot[tail];
        pthread_mutex_unlock(&lock);
        int ok = write_all(f, FRAME_BYTES);
        pthread_mutex_lock(&lock);
        tail = (tail + 1) % SLOTS;
        count--;
        if (ok) frames_out++;
        else running = 0;
    }
    pthread_mutex_unlock(&lock);
    return NULL;
}

// --------------------------------------------------------- Glitch-Regler --
//
// Alle Bits aus dem SAA7113H-Datenblatt (Rev. 02, 2005), Abschnitt 9.2:
//   0x08 Sync (Tab. 36): D7 AUFD 50/60-Auto, D6 FSEL 0=50/1=60 Hz,
//        D4-D3 HTC Zeilen-PLL 00 TV / 01 VTR / 11 schnell, D2 HPLL 1 = PLL offen,
//        D1-D0 VNOI vertikal 00 normal / 01 schnell / 10 freilaufend / 11 aus
//   0x03 (Tab. 31) D3 HOLDG: Helligkeits-AGC einfrieren
//   0x09 (Tab. 37) D7 BYPS:  Farbtraeger-Falle aus
//   0x0B (Tab. 39) Kontrast, vorzeichenbehaftet: negativ = invertierte Helligkeit
//   0x0C (Tab. 40) Saettigung, vorzeichenbehaftet: negativ = invertierte Farben
//   0x0D (Tab. 41) Farbton, -180 bis +178.6 Grad (1.4 Grad pro Schritt)
//   0x0E (Tab. 42) D1-D0 CHBW: Farb-Bandbreite 620 / 800 / 920 / 1000 kHz
//   0x0F (Tab. 44) D7 ACGC:  1 = Farb-AGC aus, feste Verstaerkung
//   0x11 (Tab. 49) D0 COLO:  Farbe erzwingen (kein Farb-Killer)

enum { R03, R08, R09, R0B, R0C, R0D, R0E, R0F, R11, NREG };
static const uint8_t reg_addr[NREG] = { 0x03, 0x08, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x11 };
static uint8_t reg[NREG], reg0[NREG];  // aktuell / Startwert fuer "0"

static const char *htc_name[] = { "TV", "VTR", "?", "schnell" };
static const char *vnoi_name[] = { "normal", "schnell", "frei", "aus" };
static const char *chbw_name[] = { "schmal", "normal", "mittel", "breit" };

static void regs_load(void)
{
    for (int i = 0; i < NREG; i++)
        reg[i] = reg0[i] = ez_saa_read(reg_addr[i]);
}

static void set(int i, uint8_t v)
{
    reg[i] = v;
    ez_saa_write(reg_addr[i], v);
}

static uint8_t negate(uint8_t v) { return (uint8_t)-(int8_t)v; }

static void handle_key(char c)
{
    switch (c) {
    case 's': {                                         // TV -> VTR -> schnell -> TV
        int htc = (reg[R08] >> 3) & 3;
        htc = htc == 0 ? 1 : htc == 1 ? 3 : 0;
        set(R08, (reg[R08] & ~0x18) | (htc << 3));
        break;
    }
    case 'p': set(R08, reg[R08] ^ 0x04); break;
    case 'v': set(R08, (reg[R08] & ~0x03) | ((reg[R08] + 1) & 0x03)); break;
    case 'n': set(R08, (reg[R08] & ~0x80) ^ 0x40); break;   // Auto aus, 50/60 umschalten
    case 'a': set(R03, reg[R03] ^ 0x08); break;
    case 'g': set(R0F, reg[R0F] ^ 0x80); break;
    case 'c': set(R11, reg[R11] ^ 0x01); break;
    case 't': set(R09, reg[R09] ^ 0x80); break;
    case 'b': set(R0E, (reg[R0E] & ~0x03) | ((reg[R0E] + 1) & 0x03)); break;
    case 'u': set(R0D, reg[R0D] + 32); break;              // +45 Grad
    case 'i': set(R0B, negate(reg[R0B])); break;
    case 'k': set(R0C, negate(reg[R0C])); break;
    case 'f': swap_fields ^= 1; break;
    case '0':
        for (int i = 0; i < NREG; i++)
            if (reg[i] != reg0[i]) set(i, reg0[i]);
        swap_fields = 0;
        break;
    }
}

static void print_help(void)
{
    fprintf(stderr,
        "\nTasten (hier im Terminal):\n"
        "  Sync   s Zeilen-PLL TV/VTR/schnell   p PLL offen (Bild reisst)\n"
        "         v vertikal normal/schnell/frei/aus   n 50/60 Hz erzwingen (rollt)\n"
        "  Pegel  a Helligkeits-Automatik fest   g Farb-Automatik fest\n"
        "  Farbe  c Farbe erzwingen   t Farbtraeger-Falle aus   b Farb-Bandbreite\n"
        "         u Farbton +45 Grad   k Farben invertieren\n"
        "  Bild   i Negativ   f Halbbilder tauschen\n"
        "         0 alles zurueck   h Hilfe   Ctrl+C Ende\n\n");
}

// Eine Zeile, nur was von der Grundeinstellung abweicht. Kuerzel = Tasten.
static void print_status(long fps, int locked)
{
    char s[256];
    int n = 0;
#define ADD(...) n += snprintf(s + n, sizeof s - n, __VA_ARGS__)
    uint8_t d08 = reg[R08] ^ reg0[R08];
    if (d08 & 0x18) ADD(" s:%s", htc_name[(reg[R08] >> 3) & 3]);
    if (d08 & 0x04) ADD(" p:%s", (reg[R08] & 0x04) ? "offen" : "zu");
    if (d08 & 0x03) ADD(" v:%s", vnoi_name[reg[R08] & 3]);
    if (d08 & 0xc0) ADD(" n:%s", (reg[R08] & 0x80) ? "auto" : (reg[R08] & 0x40) ? "60" : "50");
    if ((reg[R03] ^ reg0[R03]) & 0x08) ADD(" a:%s", (reg[R03] & 0x08) ? "fest" : "an");
    if ((reg[R0F] ^ reg0[R0F]) & 0x80) ADD(" g:%s", (reg[R0F] & 0x80) ? "fest" : "an");
    if ((reg[R11] ^ reg0[R11]) & 0x01) ADD(" c:%s", (reg[R11] & 0x01) ? "immer" : "auto");
    if ((reg[R09] ^ reg0[R09]) & 0x80) ADD(" t:%s", (reg[R09] & 0x80) ? "aus" : "an");
    if ((reg[R0E] ^ reg0[R0E]) & 0x03) ADD(" b:%s", chbw_name[reg[R0E] & 3]);
    if (reg[R0D] != reg0[R0D]) ADD(" u:%+.0f Grad", (int8_t)reg[R0D] * 180.0 / 128);
    if (reg[R0C] != reg0[R0C]) ADD(" k:invertiert");
    if (reg[R0B] != reg0[R0B]) ADD(" i:negativ");
    if (swap_fields) ADD(" f:getauscht");
    if (frames_dropped) ADD(" | verworfen %ld", frames_dropped);
#undef ADD
    fprintf(stderr, "\r\033[K");
    if (rec_path) {
        struct stat sb;
        long t = (long)(now() - t_start);
        double gb = stat(rec_path, &sb) == 0 ? sb.st_size / 1e9 : 0;
        fprintf(stderr, "REC %ld:%02ld:%02ld %.2f GB | ", t / 3600, t / 60 % 60, t % 60, gb);
    }
    fprintf(stderr, "%2ld fps %-11s |%s", fps, locked ? "Signal" : "kein Signal",
            n ? s : " Grundeinstellung");
}

// ------------------------------------------------------------- Terminal --

static struct termios tio_orig;
static int tio_set;

static void term_restore(void)
{
    if (tio_set) tcsetattr(0, TCSANOW, &tio_orig);
}

// Tasten sofort lesen (ohne Enter), ohne Echo. Ctrl+C funktioniert weiter.
static void term_raw(void)
{
    if (!isatty(0)) return;
    tcgetattr(0, &tio_orig);
    struct termios t = tio_orig;
    t.c_lflag &= ~(ICANON | ECHO);
    t.c_cc[VMIN] = 0;
    t.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &t);
    tio_set = 1;
    atexit(term_restore);
}

static void on_signal(int s) { (void)s; running = 0; }

// ----------------------------------------------------------------- main --

int main(int argc, char **argv)
{
    int alt = 7, seconds = 0, svideo = 0, quiet = 0, opt, npoke = 0;
    unsigned poke_reg[32], poke_val[32];
    while ((opt = getopt(argc, argv, "a:t:sqr:R:")) != -1) {
        if (opt == 'a') alt = atoi(optarg);
        else if (opt == 't') seconds = atoi(optarg);
        else if (opt == 's') svideo = 1;
        else if (opt == 'q') quiet = 1;
        else if (opt == 'R') rec_path = optarg;
        else if (opt == 'r' && npoke < 32 &&
                 sscanf(optarg, "%x=%x", &poke_reg[npoke], &poke_val[npoke]) == 2) npoke++;
        else {
            fprintf(stderr, "Aufruf: %s [-a alt] [-t sekunden] [-s] [-q] [-r reg=wert] [-R datei]\n", argv[0]);
            return 1;
        }
    }
    if (isatty(1)) {
        fprintf(stderr, "stdout ist ein Terminal. Bitte an ffplay/ffmpeg weiterleiten, z. B. ./vorschau.sh\n");
        return 1;
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (ez_open(svideo) < 0) return 1;
    for (int i = 0; i < npoke; i++) {
        ez_saa_write(poke_reg[i], poke_val[i]);
        fprintf(stderr, "Decoder-Register 0x%02x = 0x%02x\n", poke_reg[i], poke_val[i]);
    }
    regs_load();

    t_start = now();
    if (ez_stream_start(alt, on_packet) < 0) { ez_close(); return 1; }
    pthread_t wt;
    pthread_create(&wt, NULL, writer, NULL);

    term_raw();
    if (tio_set && !quiet) print_help();

    time_t start = time(NULL), last = start;
    long last_out = 0, fps = 0;
    while (running && (!seconds || time(NULL) - start < seconds)) {
        ez_stream_poll(50);

        char c;
        int changed = 0;
        while (tio_set && read(0, &c, 1) == 1) {
            if (c == 'h') print_help();
            else handle_key(c);
            changed = 1;
        }
        if (time(NULL) != last) {
            fps = frames_out - last_out;
            last_out = frames_out;
            last = time(NULL);
            changed = 1;
        }
        if (changed && !quiet) print_status(fps, ez_signal_locked());
    }

    running = 0;
    ez_stream_stop();
    pthread_mutex_lock(&lock);
    pthread_cond_broadcast(&wake);
    pthread_mutex_unlock(&lock);
    pthread_join(wt, NULL);
    ez_close();
    term_restore();

    fprintf(stderr, "\nEnde: %ld Bilder ausgegeben, %ld verworfen, %ld gedrosselt, %ld USB-Fehler\n",
            frames_out, frames_dropped, frames_capped, ez_stats.errors);
    return 0;
}
