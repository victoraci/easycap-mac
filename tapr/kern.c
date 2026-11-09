// kern.c – Empfang fuer die TAPR-App: Stick suchen, Halbbilder sammeln, an Swift weiterreichen.
// Paket-Logik wie in ezcap.c, nur geht hier jedes Halbbild einzeln raus (50/s)
// statt fertig verzahnter Vollbilder. ezcap.c selbst bleibt unangetastet.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>
#include "../hw.h"
#include "kern.h"

_Static_assert(TAPR_FIELD_BYTES == EZ_FIELD_BYTES, "Halbbild-Groesse passt nicht zu hw.h");

static volatile int running, state = TAPR_SUCHT;
static pthread_t thread;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// --------------------------------------------------------------- Messwerte --

// Nur der USB-Thread schreibt, die Oberflaeche liest zweimal pro Sekunde.
static volatile int signal_ok, rate;
static long fields_total;                       // fertige Halbbilder seit dem Verbinden
static double field_at;                         // wann das letzte fertig war
static double rate_t, rate_field_at;
static long rate_n;

static void messen_start(void)
{
    memset(&ez_stats, 0, sizeof ez_stats);
    fields_total = 0;
    field_at = 0;
    signal_ok = rate = 0;
    rate_t = now();
    rate_n = 0;
    rate_field_at = 0;
}

// Einmal pro Sekunde Halbbilder/s ausrechnen. Gemessen von Halbbild zu Halbbild statt
// einfach pro Sekunde gezaehlt, sonst springt die Anzeige zwischen 49, 50 und 51.
static void messen(void)
{
    double t = now();
    if (t - rate_t < 1) return;
    long n = fields_total - rate_n;
    if (n <= 0) rate = 0;
    else if (rate_field_at > 0) rate = (int)(n / (field_at - rate_field_at) + 0.5);
    else rate = (int)(n / (t - rate_t) + 0.5);      // erste Messung nach dem Verbinden
    rate_t = t;
    rate_n = fields_total;
    rate_field_at = field_at;
}

int  tapr_signal(void) { return signal_ok; }
int  tapr_rate(void) { return rate; }
long tapr_usb_errors(void) { return ez_stats.errors; }

// ----------------------------------------------------------- Glitch-Regler --

// Dieselben Decoder-Register wie in ezcap.c, Bits siehe dort (gegen Datenblatt geprueft).
// Die Oberflaeche sagt nur, welchen Wert sie will. Geschrieben wird im USB-Thread, und zwar
// immer nur der neueste Wunsch: Beim Ziehen am Schieber fallen Zwischenwerte einfach weg.
static const uint8_t reg_addr[TAPR_NREG] = { 0x03, 0x08, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x11 };
static volatile uint8_t reg_want[TAPR_NREG], reg_hw[TAPR_NREG], reg_start[TAPR_NREG];
static volatile int regs_ok;

// Stand nach der Grundeinstellung in hw.c (SAA7113, PAL, Composite). Fuers Testbild.
static const uint8_t reg_default[TAPR_NREG] = { 0x30, 0x28, 0x01, 0x47, 0x40, 0x00, 0x07, 0x2a, 0x0c };

static void regs_load(int from_chip)
{
    for (int i = 0; i < TAPR_NREG; i++) {
        int v = from_chip ? ez_saa_read(reg_addr[i]) : -1;
        reg_want[i] = reg_hw[i] = reg_start[i] = v < 0 ? reg_default[i] : v;
    }
    regs_ok = 1;
}

static void regs_write(void)
{
    for (int i = 0; i < TAPR_NREG; i++) {
        uint8_t v = reg_want[i];
        if (v == reg_hw[i]) continue;
        ez_saa_write(reg_addr[i], v);
        reg_hw[i] = v;
    }
}

int tapr_reg(int i) { return regs_ok && i >= 0 && i < TAPR_NREG ? reg_want[i] : -1; }
int tapr_reg_start(int i) { return regs_ok && i >= 0 && i < TAPR_NREG ? reg_start[i] : -1; }

void tapr_reg_set(int i, int value)
{
    if (i >= 0 && i < TAPR_NREG) reg_want[i] = (uint8_t)value;
}

// --------------------------------------------------------------- Aufnahme --

// Wie ezcap.c: Beide Halbbilder ergeben ein Vollbild, fertig nach dem unteren. Fehlt mal
// etwas, bleiben die alten Zeilen stehen. Gedrosselt auf 25/s (im 60-Hz-Modus kommen ~30).
#define REC_BYTES (TAPR_LINE_BYTES * TAPR_HEIGHT)
#define REC_SLOTS 50                            // Puffer USB -> Schreib-Thread (= 2 s)

static uint8_t rec_work[REC_BYTES];
static uint8_t rec_ring[REC_SLOTS][REC_BYTES];
static int rec_head, rec_tail, rec_count, rec_fd = -1;
static int rec_started, rec_stopping, rec_begun;
static volatile int rec_on, rec_swap;
static volatile long rec_out, rec_lost;
static long rec_passed;
static double rec_t0;
static pthread_t rec_thread;
static pthread_mutex_t rec_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rec_wake = PTHREAD_COND_INITIALIZER;

// Laeuft im USB-Thread (bzw. Testbild-Thread) und blockiert nie auf ffmpeg.
static void rec_feed(const uint8_t *f, int top)
{
    if (!rec_on) return;
    if (!rec_begun) {                           // mit einem oberen Halbbild anfangen, sonst ist Bild 1 halb leer
        if (!top) return;
        rec_begun = 1;
    }
    int row_offset = (top != rec_swap) ? 0 : 1;
    for (int line = 0; line < TAPR_FIELD_LINES; line++)
        memcpy(rec_work + (line * 2 + row_offset) * TAPR_LINE_BYTES, f + line * TAPR_LINE_BYTES, TAPR_LINE_BYTES);
    if (top) return;

    if (rec_passed >= (now() - rec_t0) * 25 + 2) return;
    rec_passed++;

    pthread_mutex_lock(&rec_lock);
    if (rec_on && rec_count < REC_SLOTS) {
        memcpy(rec_ring[rec_head], rec_work, REC_BYTES);
        rec_head = (rec_head + 1) % REC_SLOTS;
        rec_count++;
        pthread_cond_signal(&rec_wake);
    } else if (rec_on) {
        rec_lost++;
    }
    pthread_mutex_unlock(&rec_lock);
}

static int rec_write_all(const uint8_t *p, size_t n)
{
    while (n > 0) {
        ssize_t w = write(rec_fd, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return 0;                           // ffmpeg ist weg (EPIPE)
        }
        p += w; n -= w;
    }
    return 1;
}

static void *rec_writer(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&rec_lock);
    for (;;) {
        while (rec_count == 0 && !rec_stopping) pthread_cond_wait(&rec_wake, &rec_lock);
        if (rec_count == 0) break;
        uint8_t *f = rec_ring[rec_tail];
        pthread_mutex_unlock(&rec_lock);
        int ok = rec_write_all(f, REC_BYTES);
        pthread_mutex_lock(&rec_lock);
        rec_tail = (rec_tail + 1) % REC_SLOTS;
        rec_count--;
        if (!ok) break;
        rec_out++;
    }
    rec_on = 0;
    pthread_mutex_unlock(&rec_lock);
    close(rec_fd);                              // ffmpeg sieht Dateiende und schliesst die MKV sauber ab
    rec_fd = -1;
    return NULL;
}

int tapr_rec_start(int fd)
{
    signal(SIGPIPE, SIG_IGN);                   // abgestuerztes ffmpeg = Schreibfehler statt App-Ende
    if (rec_started) return -1;
    pthread_mutex_lock(&rec_lock);
    rec_fd = fd;
    rec_head = rec_tail = rec_count = 0;
    rec_stopping = rec_begun = 0;
    rec_out = rec_lost = rec_passed = 0;
    rec_t0 = now();
    if (pthread_create(&rec_thread, NULL, rec_writer, NULL) != 0) {
        pthread_mutex_unlock(&rec_lock);
        return -1;
    }
    rec_started = 1;
    rec_on = 1;
    pthread_mutex_unlock(&rec_lock);
    return 0;
}

void tapr_rec_stop(void)
{
    if (!rec_started) return;
    pthread_mutex_lock(&rec_lock);
    rec_on = 0;                                 // keine neuen Bilder mehr, der Rest im Puffer geht noch raus
    rec_stopping = 1;
    pthread_cond_signal(&rec_wake);
    pthread_mutex_unlock(&rec_lock);
    pthread_join(rec_thread, NULL);
    rec_started = 0;
}

void tapr_rec_swap(int swap) { rec_swap = swap != 0; }
int  tapr_rec_active(void) { return rec_on; }
long tapr_rec_frames(void) { return rec_out; }
long tapr_rec_lost(void) { return rec_lost; }

// ------------------------------------------------------------ Halbbilder --

// Je ein Puffer fuers obere und untere Halbbild. Fehlt mal ein Paket, bleiben die
// alten Zeilen stehen – wie in ezcap.c.
static uint8_t field[2][TAPR_FIELD_BYTES];     // [0] oben, [1] unten
static long pos;
static int in_field, cur_top, field_closed;

// Die letzten fertigen Halbbilder fuer die Anzeige. USB liefert in 8-ms-Happen, da kommen
// zwei Halbbilder manchmal fast gleichzeitig an. Die Anzeige holt sie trotzdem der Reihe
// nach ab, eins pro Bildschirm-Takt, statt das erste zu ueberspringen.
#define RING 4
static uint8_t ring[RING][TAPR_FIELD_BYTES];
static int ring_top[RING];
static long latest_seq;                         // Nummer des neuesten Halbbilds, 0 = noch keins
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static volatile int play_on;                    // Wiedergabe laeuft: Live-Bild nicht anzeigen

static void ring_put(const uint8_t *f, int top)
{
    pthread_mutex_lock(&lock);
    long seq = latest_seq + 1;
    memcpy(ring[seq % RING], f, TAPR_FIELD_BYTES);
    ring_top[seq % RING] = top;
    latest_seq = seq;
    pthread_mutex_unlock(&lock);
}

static void publish(const uint8_t *f, int top)
{
    fields_total++;
    field_at = now();
    if (!play_on) ring_put(f, top);
    rec_feed(f, top);
}

// ------------------------------------------------------------- Wiedergabe --

static pthread_t play_thread;
static int play_fd = -1, play_started;

static int play_read_all(uint8_t *p, size_t n)
{
    while (n > 0) {
        ssize_t r = read(play_fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return 0;
        p += r; n -= r;
    }
    return 1;
}

// Oberes Halbbild zuerst, so wie die Datei gespeichert ist. Feste 20-ms-Schritte wie beim Testbild.
static void *play_reader(void *arg)
{
    (void)arg;
    static uint8_t frame[REC_BYTES], f[2][TAPR_FIELD_BYTES];
    double next = now();
    while (play_on && play_read_all(frame, REC_BYTES)) {
        for (int line = 0; line < TAPR_FIELD_LINES; line++)
            for (int t = 0; t < 2; t++)
                memcpy(f[t] + line * TAPR_LINE_BYTES, frame + (line * 2 + t) * TAPR_LINE_BYTES, TAPR_LINE_BYTES);
        for (int t = 0; t < 2 && play_on; t++) {
            ring_put(f[t], t == 0);
            next += 0.02;
            double wait = next - now();
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
            else if (wait < -0.2) next = now();     // nach einem Haenger nicht hinterherrasen
        }
    }
    play_on = 0;
    close(play_fd);
    play_fd = -1;
    return NULL;
}

int tapr_play_start(int fd)
{
    if (play_started) return -1;
    play_fd = fd;
    play_on = 1;
    if (pthread_create(&play_thread, NULL, play_reader, NULL) != 0) {
        play_on = 0;
        return -1;
    }
    play_started = 1;
    return 0;
}

void tapr_play_stop(void)
{
    if (!play_started) return;
    play_on = 0;
    pthread_join(play_thread, NULL);
    play_started = 0;
}

int tapr_play_active(void) { return play_on; }

long tapr_field(long seen, uint8_t *dst, int *top)
{
    pthread_mutex_lock(&lock);
    long want = seen + 1;
    if (latest_seq - want >= 2) want = latest_seq;  // Anzeige haengt hinterher: aufholen, Verzoegerung klein halten
    if (want > latest_seq) want = seen;             // nichts Neues
    else {
        memcpy(dst, ring[want % RING], TAPR_FIELD_BYTES);
        *top = ring_top[want % RING];
    }
    pthread_mutex_unlock(&lock);
    return want;
}

static void field_end(void)
{
    if (!in_field || field_closed) return;
    field_closed = 1;
    publish(field[!cur_top], cur_top);
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
    int n = EZ_FIELD_BYTES - pos < len ? EZ_FIELD_BYTES - pos : len;
    memcpy(field[!cur_top] + pos, p, n);
    pos += len;
    if (pos >= EZ_FIELD_BYTES) field_end();
}

// ---------------------------------------------------------------- Testbild --

// Entwickeln ohne Rekorder: TAPR_TESTBILD=frame.yuyv spielt ein gespeichertes Vollbild
// (720x576 YUYV, z. B. von streamtest) als Halbbild-Strom mit 50/s ab.
static int testbild(const char *path)
{
    static uint8_t frame[EZ_LINE_BYTES * EZ_HEIGHT];
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    size_t n = fread(frame, 1, sizeof frame, f);
    fclose(f);
    if (n != sizeof frame) return -1;

    for (int line = 0; line < EZ_HEIGHT / 2; line++)
        for (int t = 0; t < 2; t++)
            memcpy(field[t] + line * EZ_LINE_BYTES, frame + (line * 2 + t) * EZ_LINE_BYTES, EZ_LINE_BYTES);
    // Feste 20-ms-Schritte ab Start, sonst summiert sich das Ueberschlafen von usleep
    double next = now();
    messen_start();
    regs_load(0);                                   // Regler sind bedienbar, wirken aber auf nichts
    signal_ok = 1;
    state = TAPR_LAEUFT;
    for (int top = 1; running; top = !top) {
        publish(field[!top], top);
        messen();
        next += 0.02;
        double wait = next - now();
        if (wait > 0) usleep((useconds_t)(wait * 1e6));
    }
    return 0;
}

// ------------------------------------------------------------- USB-Thread --

static int stick_da(void)
{
    libusb_context *c;
    libusb_device **list;
    int da = 0;
    if (libusb_init_context(&c, NULL, 0) < 0) return 0;
    ssize_t n = libusb_get_device_list(c, &list);
    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) == 0 &&
            d.idVendor == EZ_VID && d.idProduct == EZ_PID) da = 1;
    }
    if (n >= 0) libusb_free_device_list(list, 1);
    libusb_exit(c);
    return da;
}

static void pause_ms(int ms)
{
    for (; running && ms > 0; ms -= 100) usleep(100000);
}

// Sucht den Stick, bis er da und frei ist, und empfaengt dann bis tapr_stop().
static void *usb_thread(void *arg)
{
    (void)arg;
    const char *tb = getenv("TAPR_TESTBILD");
    if (tb && testbild(tb) == 0) return NULL;

    while (running) {
        if (!stick_da()) {
            state = TAPR_FEHLT;
            pause_ms(1000);
            continue;
        }
        in_field = 0;
        if (ez_open(0) < 0 || ez_stream_start(7, on_packet) < 0) {
            ez_close();
            state = TAPR_BELEGT;
            pause_ms(1000);
            continue;
        }
        messen_start();
        regs_load(1);
        state = TAPR_LAEUFT;
        for (double t_signal = 0; running; ) {
            ez_stream_poll(50);
            regs_write();
            if (now() - t_signal >= 0.5) {         // I2C nur hier im USB-Thread, nie von der Oberflaeche
                signal_ok = ez_signal_locked();
                t_signal = now();
            }
            messen();
        }
        regs_ok = 0;
        ez_stream_stop();
        ez_close();
        signal_ok = rate = 0;
    }
    return NULL;
}

void tapr_start(void)
{
    if (running) return;
    running = 1;
    pthread_create(&thread, NULL, usb_thread, NULL);
}

void tapr_stop(void)
{
    if (!running) return;
    running = 0;
    pthread_join(thread, NULL);
}

int tapr_state(void) { return state; }
