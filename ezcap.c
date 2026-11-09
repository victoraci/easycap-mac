// ezcap.c – live video from the grabber as raw data on stdout, with glitch controls.
//
// Output: 720x576, YUYV (ffmpeg: yuyv422), 25 frames/s,
//         fields interlaced line by line, top field first.
// Status line every second on stderr. Keys in the terminal change the decoder live
// (list with "h"). Nothing is permanent: unplugging and replugging the stick = factory state.
//
// Example: ./ezcap | ffplay -f rawvideo -pixel_format yuyv422 -video_size 720x576 -framerate 25 -i -
// (ready-made in preview.sh)
//
// Build: make ezcap
// Run:   ./ezcap [-a alt] [-t seconds] [-s] [-q] [-r reg=value ...] [-R file]
//   -s  S-Video instead of composite     -q  no status line
//   -r  set a decoder register directly (hex), e.g. -r 08=2c
//   -R  REC display with running time and size of this file (for record.sh)

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
#define SLOTS 4                     // buffer between USB and output (= 160 ms)

static volatile int running = 1;

// --------------------------------------------------------- Building frames --

// Fields are written straight into this frame. If one goes missing, the old
// lines simply stay – like afterglow on a CRT.
static uint8_t work[FRAME_BYTES];
static long pos;                    // bytes in the current field
static int in_field, cur_top, field_closed, swap_fields;

// Ring buffer USB -> writer thread
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
    if (cur_top) return;            // a frame is only complete after the bottom field

    // Cap: never more than 25 frames/s out. In forced 60 Hz mode about 30 arrive,
    // they would otherwise pile up in ffplay and make the preview lag more and more.
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
        frames_dropped++;           // the consumer (ffplay/ffmpeg) can't keep up
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
    put_video(p, len);
    pos += len;
    if (pos >= EZ_FIELD_BYTES) field_end();
}

// ------------------------------------------------------------------ Output --

static int write_all(const uint8_t *p, size_t n)
{
    while (n > 0) {
        ssize_t w = write(1, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return 0;               // e.g. ffplay window closed (EPIPE)
        }
        p += w; n -= w;
    }
    return 1;
}

// Its own thread, so a slow consumer never blocks USB reception.
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

// --------------------------------------------------------- Glitch controls --
//
// All bits from the SAA7113H datasheet (Rev. 02, 2005), section 9.2:
//   0x08 sync (table 36): D7 AUFD 50/60 auto, D6 FSEL 0=50/1=60 Hz,
//        D4-D3 HTC line PLL 00 TV / 01 VTR / 11 fast, D2 HPLL 1 = PLL open,
//        D1-D0 VNOI vertical 00 normal / 01 fast / 10 free-running / 11 off
//   0x03 (table 31) D3 HOLDG: freeze the luma AGC
//   0x09 (table 37) D7 BYPS:  chroma trap off
//   0x0B (table 39) contrast, signed: negative = inverted brightness
//   0x0C (table 40) saturation, signed: negative = inverted colors
//   0x0D (table 41) hue, -180 to +178.6 degrees (1.4 degrees per step)
//   0x0E (table 42) D1-D0 CHBW: chroma bandwidth 620 / 800 / 920 / 1000 kHz
//   0x0F (table 44) D7 ACGC:  1 = chroma AGC off, fixed gain
//   0x11 (table 49) D0 COLO:  force color (no color killer)

enum { R03, R08, R09, R0B, R0C, R0D, R0E, R0F, R11, NREG };
static const uint8_t reg_addr[NREG] = { 0x03, 0x08, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x11 };
static uint8_t reg[NREG], reg0[NREG];  // current / start value for "0"

static const char *htc_name[] = { "TV", "VTR", "?", "fast" };
static const char *vnoi_name[] = { "normal", "fast", "free", "off" };
static const char *chbw_name[] = { "narrow", "normal", "medium", "wide" };

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
    case 's': {                                         // TV -> VTR -> fast -> TV
        int htc = (reg[R08] >> 3) & 3;
        htc = htc == 0 ? 1 : htc == 1 ? 3 : 0;
        set(R08, (reg[R08] & ~0x18) | (htc << 3));
        break;
    }
    case 'p': set(R08, reg[R08] ^ 0x04); break;
    case 'v': set(R08, (reg[R08] & ~0x03) | ((reg[R08] + 1) & 0x03)); break;
    case 'n': set(R08, (reg[R08] & ~0x80) ^ 0x40); break;   // auto off, toggle 50/60
    case 'a': set(R03, reg[R03] ^ 0x08); break;
    case 'g': set(R0F, reg[R0F] ^ 0x80); break;
    case 'c': set(R11, reg[R11] ^ 0x01); break;
    case 't': set(R09, reg[R09] ^ 0x80); break;
    case 'b': set(R0E, (reg[R0E] & ~0x03) | ((reg[R0E] + 1) & 0x03)); break;
    case 'u': set(R0D, reg[R0D] + 32); break;              // +45 degrees
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
        "\nKeys (here in the terminal):\n"
        "  Sync   s line PLL TV/VTR/fast   p PLL open (picture tears)\n"
        "         v vertical normal/fast/free/off   n force 50/60 Hz (rolls)\n"
        "  Level  a freeze brightness AGC   g freeze color AGC\n"
        "  Color  c force color   t chroma trap off   b chroma bandwidth\n"
        "         u hue +45 degrees   k invert colors\n"
        "  Image  i negative   f swap fields\n"
        "         0 reset all   h help   Ctrl+C quit\n\n");
}

// One line, only what differs from the defaults. Abbreviations = keys.
static void print_status(long fps, int locked)
{
    char s[256];
    int n = 0;
#define ADD(...) n += snprintf(s + n, sizeof s - n, __VA_ARGS__)
    uint8_t d08 = reg[R08] ^ reg0[R08];
    if (d08 & 0x18) ADD(" s:%s", htc_name[(reg[R08] >> 3) & 3]);
    if (d08 & 0x04) ADD(" p:%s", (reg[R08] & 0x04) ? "open" : "closed");
    if (d08 & 0x03) ADD(" v:%s", vnoi_name[reg[R08] & 3]);
    if (d08 & 0xc0) ADD(" n:%s", (reg[R08] & 0x80) ? "auto" : (reg[R08] & 0x40) ? "60" : "50");
    if ((reg[R03] ^ reg0[R03]) & 0x08) ADD(" a:%s", (reg[R03] & 0x08) ? "frozen" : "on");
    if ((reg[R0F] ^ reg0[R0F]) & 0x80) ADD(" g:%s", (reg[R0F] & 0x80) ? "frozen" : "on");
    if ((reg[R11] ^ reg0[R11]) & 0x01) ADD(" c:%s", (reg[R11] & 0x01) ? "always" : "auto");
    if ((reg[R09] ^ reg0[R09]) & 0x80) ADD(" t:%s", (reg[R09] & 0x80) ? "off" : "on");
    if ((reg[R0E] ^ reg0[R0E]) & 0x03) ADD(" b:%s", chbw_name[reg[R0E] & 3]);
    if (reg[R0D] != reg0[R0D]) ADD(" u:%+.0f deg", (int8_t)reg[R0D] * 180.0 / 128);
    if (reg[R0C] != reg0[R0C]) ADD(" k:inverted");
    if (reg[R0B] != reg0[R0B]) ADD(" i:negative");
    if (swap_fields) ADD(" f:swapped");
    if (frames_dropped) ADD(" | dropped %ld", frames_dropped);
#undef ADD
    fprintf(stderr, "\r\033[K");
    if (rec_path) {
        struct stat sb;
        long t = (long)(now() - t_start);
        double gb = stat(rec_path, &sb) == 0 ? sb.st_size / 1e9 : 0;
        fprintf(stderr, "REC %ld:%02ld:%02ld %.2f GB | ", t / 3600, t / 60 % 60, t % 60, gb);
    }
    fprintf(stderr, "%2ld fps %-9s |%s", fps, locked ? "signal" : "no signal",
            n ? s : " defaults");
}

// ---------------------------------------------------------------- Terminal --

static struct termios tio_orig;
static int tio_set;

static void term_restore(void)
{
    if (tio_set) tcsetattr(0, TCSANOW, &tio_orig);
}

// Read keys immediately (no Enter), without echo. Ctrl+C keeps working.
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

// -------------------------------------------------------------------- main --

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
            fprintf(stderr, "Usage: %s [-a alt] [-t seconds] [-s] [-q] [-r reg=value] [-R file]\n", argv[0]);
            return 1;
        }
    }
    if (isatty(1)) {
        fprintf(stderr, "stdout is a terminal. Pipe it into ffplay/ffmpeg, e.g. ./preview.sh\n");
        return 1;
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (ez_open(svideo) < 0) return 1;
    for (int i = 0; i < npoke; i++) {
        ez_saa_write(poke_reg[i], poke_val[i]);
        fprintf(stderr, "Decoder register 0x%02x = 0x%02x\n", poke_reg[i], poke_val[i]);
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

    fprintf(stderr, "\nDone: %ld frames out, %ld dropped, %ld capped, %ld USB errors\n",
            frames_out, frames_dropped, frames_capped, ez_stats.errors);
    return 0;
}
