// hw.c – registers, I2C, decoder init and isochronous reception.
// Rebuilt from Linux em28xx + saa7115.
// Messages go to stderr, because ezcap reserves stdout for the video.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "hw.h"

#define SAA 0x4a                    // I2C address of the decoder (8 bit)
#define NUM_XFERS 16                // this many transfers "in flight" at once
#define PKTS_PER_XFER 64            // 64 microframes = 8 ms per transfer

static libusb_context *ctx;
static libusb_device_handle *h;
static struct libusb_transfer *xf[NUM_XFERS];
static ez_packet_fn on_packet;
static volatile int streaming;
static int inflight;
struct ez_stats ez_stats;

// --------------------------------------------------------------- Registers --

static int reg_write(uint8_t reg, uint8_t val)
{
    return libusb_control_transfer(h, 0x40, 0, 0, reg, &val, 1, 1000);
}

int ez_reg_read(uint8_t reg)
{
    uint8_t v;
    int r = libusb_control_transfer(h, 0xc0, 0, 0, reg, &v, 1, 1000);
    return r == 1 ? v : -1;
}

// After every I2C access, register 0x05 reports whether the receiver said "ACK".
static int i2c_wait(void)
{
    for (int i = 0; i < 20; i++) {
        int st = ez_reg_read(0x05);
        if (st == 0) return 0;
        if (st == 0x10) return -1;          // nobody answered
        usleep(5000);
    }
    return -1;
}

// req 2 = I2C with a stop at the end, req 3 = without stop (a read follows)
static int i2c_send(uint8_t addr, uint8_t *buf, int len, int stop)
{
    if (libusb_control_transfer(h, 0x40, stop ? 2 : 3, 0, addr, buf, len, 1000) != len)
        return -1;
    return i2c_wait();
}

int ez_saa_write(uint8_t reg, uint8_t val)
{
    uint8_t b[2] = { reg, val };
    return i2c_send(SAA, b, 2, 1);
}

int ez_saa_read(uint8_t reg)
{
    uint8_t v;
    if (i2c_send(SAA, &reg, 1, 0) < 0) return -1;
    if (libusb_control_transfer(h, 0xc0, 2, 0, SAA, &v, 1, 1000) != 1) return -1;
    return i2c_wait() == 0 ? v : -1;
}

// Status byte 0x1f (datasheet table 56): bit 6 HLVLN = 0 means locked,
// bit 0 RDCAP = 1 means all control loops have settled. Interlaced (bit 7) doesn't matter.
int ez_signal_locked(void)
{
    int s = ez_saa_read(0x1f);
    return s >= 0 && (s & 0x41) == 0x01;
}

// ----------------------------------------------------------------- Decoder --

// From Linux saa7115.c. Base values first, then the 50 Hz (PAL) values.
static const uint8_t saa7113_init[] = {
    0x01, 0x08, 0x02, 0xc2, 0x03, 0x30, 0x04, 0x00, 0x05, 0x00, 0x06, 0x89,
    0x07, 0x0d, 0x08, 0x88, 0x09, 0x01, 0x0a, 0x80, 0x0b, 0x47, 0x0c, 0x40,
    0x0d, 0x00, 0x0e, 0x01, 0x0f, 0x2a, 0x10, 0x08, 0x11, 0x0c, 0x12, 0x07,
    0x13, 0x00, 0x15, 0x00, 0x16, 0x00, 0x17, 0x00,
};
static const uint8_t gm7113c_init[] = {
    0x01, 0x08, 0x02, 0xc0, 0x03, 0x33, 0x04, 0x00, 0x05, 0x00, 0x06, 0xe9,
    0x07, 0x0d, 0x08, 0x98, 0x09, 0x01, 0x0a, 0x80, 0x0b, 0x47, 0x0c, 0x40,
    0x0d, 0x00, 0x0e, 0x01, 0x0f, 0x2a, 0x10, 0x00, 0x11, 0x0c, 0x12, 0x01,
    0x13, 0x00, 0x15, 0x00, 0x16, 0x00, 0x17, 0x00,
};
// The part of saa7115_cfg_50hz_video the SAA7113 actually has
static const uint8_t saa7113_pal[] = {
    0x15, 0x37, 0x16, 0x16, 0x17, 0x99, 0x08, 0x28, 0x0e, 0x07, 0x5a, 0x03,
};

static int write_table(const uint8_t *t, int n)
{
    for (int i = 0; i < n; i += 2)
        if (ez_saa_write(t[i], t[i + 1]) < 0) {
            fprintf(stderr, "I2C write to decoder register 0x%02x failed\n", t[i]);
            return -1;
        }
    return 0;
}

// Linux trick: write register 0 sixteen times with an index and read it back.
// A real Philips chip returns "?f7113...", the GM7113C clone only zeros.
static int decoder_is_gm7113c(void)
{
    char name[17];
    for (int i = 0; i < 16; i++) {
        ez_saa_write(0x00, i);
        int v = ez_saa_read(0x00);
        int c = (v < 0 ? 0 : v) & 0x0f;
        name[i] = c < 10 ? '0' + c : 'a' + c - 10;
    }
    name[16] = 0;
    fprintf(stderr, "Decoder ID: %s -> ", name);
    if (!memcmp(name + 1, "f7113", 5)) { fprintf(stderr, "real SAA7113\n"); return 0; }
    if (!memcmp(name, "0000", 4))       { fprintf(stderr, "GM7113C (clone)\n"); return 1; }
    fprintf(stderr, "unknown, using SAA7113 values\n");
    return 0;
}

static int decoder_init(int svideo)
{
    int gm = decoder_is_gm7113c();
    if (gm) {
        if (write_table(gm7113c_init, sizeof gm7113c_init) < 0) return -1;
        ez_saa_write(0x08, ez_saa_read(0x08) & ~0xc0);     // PAL fixed, no auto-detection
    } else {
        if (write_table(saa7113_init, sizeof saa7113_init) < 0) return -1;
        if (write_table(saa7113_pal, sizeof saa7113_pal) < 0) return -1;
    }
    // Input: composite (mode 0) or S-Video (mode 9)
    ez_saa_write(0x02, (ez_saa_read(0x02) & 0xf0) | (svideo ? 9 : 0));
    ez_saa_write(0x09, (ez_saa_read(0x09) & 0x7f) | (svideo ? 0x80 : 0));
    return 0;
}

// ------------------------------------------------------------------ Bridge --

static void bridge_init(void)
{
    reg_write(0x0f, 0x27);      // XCLK: 12 MHz (Linux default)
    reg_write(0x06, 0x40);      // I2C: 100 kHz + clock stretching
    usleep(50000);
}

static void bridge_video_setup(void)
{
    reg_write(0x27, 0x34);      // output format YUYV (0x14) + bit 5 like the Windows driver
    reg_write(0x10, 0x10);      // input from the decoder: CbYCrY (= UYVY)
    reg_write(0x11, 0x11);      // interlaced + CCIR656 (sync is embedded in the data stream)

    // Color controls neutral, sharpness OFF (we don't want to "improve" the look)
    reg_write(0x20, 0x10); reg_write(0x21, 0x00); reg_write(0x22, 0x10);
    reg_write(0x23, 0x00); reg_write(0x24, 0x00); reg_write(0x25, 0x00);
    reg_write(0x14, 0x20); reg_write(0x15, 0x20); reg_write(0x16, 0x20);
    reg_write(0x17, 0x20); reg_write(0x18, 0x00); reg_write(0x19, 0x00);
    reg_write(0x1a, 0x00);

    // "Accumulator" + capture window: full 720x576, from pixel 0 / line 0
    reg_write(0x28, 1); reg_write(0x29, (EZ_WIDTH - 4) >> 2);
    reg_write(0x2a, 1); reg_write(0x2b, (EZ_HEIGHT - 4) >> 2);
    reg_write(0x1c, 0); reg_write(0x1d, 0);
    reg_write(0x1e, EZ_WIDTH >> 2); reg_write(0x1f, EZ_HEIGHT >> 2);
    reg_write(0x1b, ((EZ_HEIGHT >> 9) & 2) | ((EZ_WIDTH >> 10) & 1));

    // Scaler off
    reg_write(0x30, 0); reg_write(0x31, 0); reg_write(0x32, 0); reg_write(0x33, 0);
    reg_write(0x26, 0x00);
}

static void capture(int on)
{
    int r = ez_reg_read(0x0c);
    reg_write(0x0c, on ? (r | 0x10) : (r & ~0x10));
    if (on) {
        reg_write(0x48, 0x00);
        reg_write(0x12, 0x67);  // video input on
        usleep(10000);
    } else {
        reg_write(0x12, 0x27);  // video input off
    }
}

// ------------------------------------------------------------ Open/close --

int ez_open(int svideo)
{
    if (libusb_init_context(&ctx, NULL, 0) < 0) return -1;
    h = libusb_open_device_with_vid_pid(ctx, EZ_VID, EZ_PID);
    if (!h) {
        fprintf(stderr, "Device %04x:%04x not found / can't be opened\n", EZ_VID, EZ_PID);
        return -1;
    }
    int r = libusb_claim_interface(h, 0);
    if (r < 0) {
        fprintf(stderr, "Claiming interface 0: %s\n", libusb_error_name(r));
        return -1;
    }
    if (ez_reg_read(0x0a) != 34)
        fprintf(stderr, "Warning: chip ID is not 34 (EM2860)\n");

    bridge_init();
    if (decoder_init(svideo) < 0) return -1;
    bridge_video_setup();
    return 0;
}

void ez_close(void)
{
    if (h) {
        libusb_release_interface(h, 0);
        libusb_close(h);
    }
    if (ctx) libusb_exit(ctx);
    h = NULL;
    ctx = NULL;
}

// --------------------------------------------------------------- Receiving --

static void LIBUSB_CALL xfer_cb(struct libusb_transfer *x)
{
    if (x->status == LIBUSB_TRANSFER_COMPLETED) {
        for (int i = 0; i < x->num_iso_packets; i++) {
            struct libusb_iso_packet_descriptor *d = &x->iso_packet_desc[i];
            ez_stats.packets++;
            if (d->status != LIBUSB_TRANSFER_COMPLETED) { ez_stats.errors++; continue; }
            if (d->actual_length == 0) { ez_stats.empty++; continue; }
            ez_stats.bytes += d->actual_length;
            on_packet(libusb_get_iso_packet_buffer_simple(x, i), d->actual_length);
        }
    } else if (x->status != LIBUSB_TRANSFER_CANCELLED) {
        fprintf(stderr, "Transfer status %d\n", x->status);
    }
    if (streaming && libusb_submit_transfer(x) == 0) return;
    inflight--;
}

int ez_stream_start(int alt, ez_packet_fn fn)
{
    int r = libusb_set_interface_alt_setting(h, 0, alt);
    if (r < 0) {
        fprintf(stderr, "Alt setting %d: %s\n", alt, libusb_error_name(r));
        return -1;
    }
    int pkt = libusb_get_max_alt_packet_size(libusb_get_device(h), 0, alt, EZ_EP_VIDEO);
    if (pkt <= 0) {
        fprintf(stderr, "Alt setting %d has no bandwidth for video\n", alt);
        return -1;
    }

    on_packet = fn;
    streaming = 1;
    capture(1);

    for (int i = 0; i < NUM_XFERS; i++) {
        xf[i] = libusb_alloc_transfer(PKTS_PER_XFER);
        libusb_fill_iso_transfer(xf[i], h, EZ_EP_VIDEO, malloc(pkt * PKTS_PER_XFER),
                                 pkt * PKTS_PER_XFER, PKTS_PER_XFER, xfer_cb, NULL, 0);
        xf[i]->flags = LIBUSB_TRANSFER_FREE_BUFFER;
        libusb_set_iso_packet_lengths(xf[i], pkt);
        r = libusb_submit_transfer(xf[i]);
        if (r < 0) {
            fprintf(stderr, "Submit %d: %s\n", i, libusb_error_name(r));
            ez_stream_stop();
            return -1;
        }
        inflight++;
    }
    return pkt;
}

void ez_stream_poll(int ms)
{
    struct timeval tv = { ms / 1000, (ms % 1000) * 1000 };
    libusb_handle_events_timeout_completed(ctx, &tv, NULL);
}

void ez_stream_stop(void)
{
    streaming = 0;
    for (int i = 0; i < NUM_XFERS; i++)
        if (xf[i]) libusb_cancel_transfer(xf[i]);
    while (inflight > 0) ez_stream_poll(100);
    for (int i = 0; i < NUM_XFERS; i++) {
        if (xf[i]) libusb_free_transfer(xf[i]);
        xf[i] = NULL;
    }
    capture(0);
    libusb_set_interface_alt_setting(h, 0, 0);
}
