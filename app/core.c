// core.c – reception for the easycap app: find the stick, collect fields, hand them to Swift.
// Packet logic as in ezcap.c, except that every field goes out on its own here (50/s)
// instead of finished interlaced frames. ezcap.c itself stays untouched.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>
#include "../hw.h"
#include "core.h"

_Static_assert(CORE_FIELD_BYTES == EZ_FIELD_BYTES, "field size doesn't match hw.h");

static volatile int running, state = CORE_SEARCHING;
static pthread_t thread;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// ---------------------------------------------------------------- Readings --

// Only the USB thread writes, the interface reads twice a second.
static volatile int signal_ok, rate;
static long fields_total;                       // finished fields since connecting
static double field_at;                         // when the last one finished
static double rate_t, rate_field_at;
static long rate_n;

static void stats_reset(void)
{
    memset(&ez_stats, 0, sizeof ez_stats);
    fields_total = 0;
    field_at = 0;
    signal_ok = rate = 0;
    rate_t = now();
    rate_n = 0;
    rate_field_at = 0;
}

// Work out fields/s once a second. Measured from field to field instead of simply
// counted per second, otherwise the display jumps between 49, 50 and 51.
static void stats_update(void)
{
    double t = now();
    if (t - rate_t < 1) return;
    long n = fields_total - rate_n;
    if (n <= 0) rate = 0;
    else if (rate_field_at > 0) rate = (int)(n / (field_at - rate_field_at) + 0.5);
    else rate = (int)(n / (t - rate_t) + 0.5);      // first reading after connecting
    rate_t = t;
    rate_n = fields_total;
    rate_field_at = field_at;
}

int  core_signal(void) { return signal_ok; }
int  core_rate(void) { return rate; }
long core_usb_errors(void) { return ez_stats.errors; }

// --------------------------------------------------------- Glitch controls --

// The same decoder registers as in ezcap.c, bits see there (checked against the datasheet).
// The interface only says which value it wants. Writing happens on the USB thread, and always
// only the newest wish: while dragging a slider, the values in between simply drop out.
static const uint8_t reg_addr[CORE_NREG] = { 0x03, 0x08, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x11 };
static volatile uint8_t reg_want[CORE_NREG], reg_hw[CORE_NREG], reg_start[CORE_NREG];
static volatile int regs_ok;

// State after the decoder setup in hw.c (SAA7113, PAL, composite). For the test frame.
static const uint8_t reg_default[CORE_NREG] = { 0x30, 0x28, 0x01, 0x47, 0x40, 0x00, 0x07, 0x2a, 0x0c };

static void regs_load(int from_chip)
{
    for (int i = 0; i < CORE_NREG; i++) {
        int v = from_chip ? ez_saa_read(reg_addr[i]) : -1;
        reg_want[i] = reg_hw[i] = reg_start[i] = v < 0 ? reg_default[i] : v;
    }
    regs_ok = 1;
}

static void regs_write(void)
{
    for (int i = 0; i < CORE_NREG; i++) {
        uint8_t v = reg_want[i];
        if (v == reg_hw[i]) continue;
        ez_saa_write(reg_addr[i], v);
        reg_hw[i] = v;
    }
}

int core_reg(int i) { return regs_ok && i >= 0 && i < CORE_NREG ? reg_want[i] : -1; }
int core_reg_start(int i) { return regs_ok && i >= 0 && i < CORE_NREG ? reg_start[i] : -1; }

void core_reg_set(int i, int value)
{
    if (i >= 0 && i < CORE_NREG) reg_want[i] = (uint8_t)value;
}

// --------------------------------------------------------------- Recording --

// Like ezcap.c: both fields make a frame, finished after the bottom one. If something is
// missing, the old lines stay. Capped at 25/s (in 60 Hz mode about 30 come in).
#define REC_BYTES (CORE_LINE_BYTES * CORE_HEIGHT)
#define REC_SLOTS 50                            // buffer USB -> writer thread (= 2 s)

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

// Runs on the USB thread (or the test frame thread) and never blocks on ffmpeg.
static void rec_feed(const uint8_t *f, int top)
{
    if (!rec_on) return;
    if (!rec_begun) {                           // start with a top field, otherwise frame 1 is half empty
        if (!top) return;
        rec_begun = 1;
    }
    int row_offset = (top != rec_swap) ? 0 : 1;
    for (int line = 0; line < CORE_FIELD_LINES; line++)
        memcpy(rec_work + (line * 2 + row_offset) * CORE_LINE_BYTES, f + line * CORE_LINE_BYTES, CORE_LINE_BYTES);
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
            return 0;                           // ffmpeg is gone (EPIPE)
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
    close(rec_fd);                              // ffmpeg sees end of file and finishes the MKV cleanly
    rec_fd = -1;
    return NULL;
}

int core_rec_start(int fd)
{
    signal(SIGPIPE, SIG_IGN);                   // crashed ffmpeg = write error instead of the app quitting
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

void core_rec_stop(void)
{
    if (!rec_started) return;
    pthread_mutex_lock(&rec_lock);
    rec_on = 0;                                 // no new frames, what's left in the buffer still goes out
    rec_stopping = 1;
    pthread_cond_signal(&rec_wake);
    pthread_mutex_unlock(&rec_lock);
    pthread_join(rec_thread, NULL);
    rec_started = 0;
}

void core_rec_swap(int swap) { rec_swap = swap != 0; }
int  core_rec_active(void) { return rec_on; }
long core_rec_frames(void) { return rec_out; }
long core_rec_lost(void) { return rec_lost; }

// ------------------------------------------------------------------ Fields --

// One buffer each for the top and bottom field. If a packet goes missing, the
// old lines stay – as in ezcap.c.
static uint8_t field[2][CORE_FIELD_BYTES];     // [0] top, [1] bottom
static long pos;
static int in_field, cur_top, field_closed;

// The last finished fields for the display. USB delivers in 8 ms chunks, so two fields
// sometimes arrive almost at once. The display still picks them up in order, one per
// screen refresh, instead of skipping the first.
#define RING 4
static uint8_t ring[RING][CORE_FIELD_BYTES];
static int ring_top[RING];
static long latest_seq;                         // number of the newest field, 0 = none yet
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static volatile int play_on;                    // playback running: don't show the live picture

static void ring_put(const uint8_t *f, int top)
{
    pthread_mutex_lock(&lock);
    long seq = latest_seq + 1;
    memcpy(ring[seq % RING], f, CORE_FIELD_BYTES);
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

// ---------------------------------------------------------------- Playback --

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

// Top field first, the way the file is stored. Fixed 20 ms steps like the test frame.
static void *play_reader(void *arg)
{
    (void)arg;
    static uint8_t frame[REC_BYTES], f[2][CORE_FIELD_BYTES];
    double next = now();
    while (play_on && play_read_all(frame, REC_BYTES)) {
        for (int line = 0; line < CORE_FIELD_LINES; line++)
            for (int t = 0; t < 2; t++)
                memcpy(f[t] + line * CORE_LINE_BYTES, frame + (line * 2 + t) * CORE_LINE_BYTES, CORE_LINE_BYTES);
        for (int t = 0; t < 2 && play_on; t++) {
            ring_put(f[t], t == 0);
            next += 0.02;
            double wait = next - now();
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
            else if (wait < -0.2) next = now();     // don't race to catch up after a stall
        }
    }
    play_on = 0;
    close(play_fd);
    play_fd = -1;
    return NULL;
}

int core_play_start(int fd)
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

void core_play_stop(void)
{
    if (!play_started) return;
    play_on = 0;
    pthread_join(play_thread, NULL);
    play_started = 0;
}

int core_play_active(void) { return play_on; }

long core_field(long seen, uint8_t *dst, int *top)
{
    pthread_mutex_lock(&lock);
    long want = seen + 1;
    if (latest_seq - want >= 2) want = latest_seq;  // display is behind: catch up, keep the delay small
    if (want > latest_seq) want = seen;             // nothing new
    else {
        memcpy(dst, ring[want % RING], CORE_FIELD_BYTES);
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

// Header: 22 5a xx 88 = new field (bit 0 of xx: 0 = top), 88 88 88 88 = continuation,
// end marker c6 93 93 93. See streamtest.c.
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

// -------------------------------------------------------------- Test frame --

// Developing without a VCR: EASYCAP_TESTFRAME=frame.yuyv plays a saved frame
// (720x576 YUYV, e.g. from streamtest) as a stream of fields at 50/s.
static int test_frame(const char *path)
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
    // Fixed 20 ms steps from the start, otherwise usleep's oversleeping adds up
    double next = now();
    stats_reset();
    regs_load(0);                                   // controls can be used but act on nothing
    signal_ok = 1;
    state = CORE_RUNNING;
    for (int top = 1; running; top = !top) {
        publish(field[!top], top);
        stats_update();
        next += 0.02;
        double wait = next - now();
        if (wait > 0) usleep((useconds_t)(wait * 1e6));
    }
    return 0;
}

// -------------------------------------------------------------- USB thread --

static int stick_present(void)
{
    libusb_context *c;
    libusb_device **list;
    int present = 0;
    if (libusb_init_context(&c, NULL, 0) < 0) return 0;
    ssize_t n = libusb_get_device_list(c, &list);
    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) == 0 &&
            d.idVendor == EZ_VID && d.idProduct == EZ_PID) present = 1;
    }
    if (n >= 0) libusb_free_device_list(list, 1);
    libusb_exit(c);
    return present;
}

static void pause_ms(int ms)
{
    for (; running && ms > 0; ms -= 100) usleep(100000);
}

// Looks for the stick until it's there and free, then receives until core_stop().
static void *usb_thread(void *arg)
{
    (void)arg;
    const char *tf = getenv("EASYCAP_TESTFRAME");
    if (tf && test_frame(tf) == 0) return NULL;

    while (running) {
        if (!stick_present()) {
            state = CORE_MISSING;
            pause_ms(1000);
            continue;
        }
        in_field = 0;
        if (ez_open(0) < 0 || ez_stream_start(7, on_packet) < 0) {
            ez_close();
            state = CORE_BUSY;
            pause_ms(1000);
            continue;
        }
        stats_reset();
        regs_load(1);
        state = CORE_RUNNING;
        for (double t_signal = 0; running; ) {
            ez_stream_poll(50);
            regs_write();
            if (now() - t_signal >= 0.5) {         // I2C only here on the USB thread, never from the interface
                signal_ok = ez_signal_locked();
                t_signal = now();
            }
            stats_update();
        }
        regs_ok = 0;
        ez_stream_stop();
        ez_close();
        signal_ok = rate = 0;
    }
    return NULL;
}

void core_start(void)
{
    if (running) return;
    running = 1;
    pthread_create(&thread, NULL, usb_thread, NULL);
}

void core_stop(void)
{
    if (!running) return;
    running = 0;
    pthread_join(thread, NULL);
}

int core_state(void) { return state; }
