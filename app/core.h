// core.h – what the easycap app (Swift) sees of the stick. Plain C without libusb types,
// so Swift can import it directly.

#pragma once
#include <stdint.h>

enum {
    CORE_WIDTH = 720,
    CORE_HEIGHT = 576,
    CORE_FIELD_LINES = 288,
    CORE_LINE_BYTES = 720 * 2,                  // YUYV
    CORE_FIELD_BYTES = 720 * 2 * 288,
};

enum {
    CORE_SEARCHING,                             // starting up, about to begin
    CORE_MISSING,                               // no stick plugged in
    CORE_BUSY,                                  // stick is there but can't be opened (another process?)
    CORE_RUNNING,                               // receiving
};

void core_start(void);                          // start its own USB thread, finds the stick by itself
void core_stop(void);                           // stop receiving, release the stick
int  core_state(void);
int  core_signal(void);                         // 1 = decoder is locked to a video signal
int  core_rate(void);                           // fields per second from the stick (PAL: 50)
long core_usb_errors(void);                     // broken USB packets since connecting

// Glitch controls: the same decoder registers as in ezcap.c (0x03 0x08 0x09 0x0b ...).
enum { CORE_R03, CORE_R08, CORE_R09, CORE_R0B, CORE_R0C, CORE_R0D, CORE_R0E, CORE_R0F, CORE_R11, CORE_NREG };
int  core_reg(int i);                           // wanted value, -1 = not connected
int  core_reg_start(int i);                     // value at connect time (= defaults)
void core_reg_set(int i, int value);            // written shortly after on the USB thread

// Recording: frames (top field first, YUYV, max. 25/s) go through their own writer thread
// into fd (ffmpeg's stdin). A 2 s buffer absorbs stalls; when it's full, frames are dropped,
// USB reception never waits. core_rec_stop drains the buffer, closes fd and only then
// returns.
int  core_rec_start(int fd);                    // 0 = running, fd belongs to the core from now on
void core_rec_stop(void);
void core_rec_swap(int swap);                   // swap fields, takes effect from the next field
int  core_rec_active(void);                     // 0 = off, or the writer thread has quit
long core_rec_frames(void);                     // frames written
long core_rec_lost(void);                       // frames lost because the buffer was full

// Playback: read frames like the recorded ones from fd (ffmpeg's stdout) and show them at
// 50 fields/s instead of the live picture. USB reception keeps running alongside.
int  core_play_start(int fd);                   // 0 = running, fd belongs to the core from now on
void core_play_stop(void);
int  core_play_active(void);                    // 0 = off, or ffmpeg stopped delivering

// Copy the next field after number 'seen' into dst (CORE_FIELD_BYTES, lines one after
// another). If the caller is more than one behind, it gets the newest right away.
// Returns its sequence number; if that == seen, nothing was copied.
// *top = 1 for the top field (it sits on the even lines of the frame).
long core_field(long seen, uint8_t *dst, int *top);
