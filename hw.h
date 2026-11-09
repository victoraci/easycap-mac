// hw.h – everything that talks to the stick directly (EM2860 + SAA7113).

#pragma once
#include <stdint.h>
#include <libusb.h>

#define EZ_VID 0xeb1a
#define EZ_PID 0x2861
#define EZ_EP_VIDEO 0x82

#define EZ_WIDTH 720
#define EZ_HEIGHT 576
#define EZ_LINE_BYTES (EZ_WIDTH * 2)                    // YUYV: 2 bytes per pixel
#define EZ_FIELD_BYTES (EZ_LINE_BYTES * EZ_HEIGHT / 2)  // one field = 288 lines

// Called for every non-empty isochronous packet (including the 4-byte header).
typedef void (*ez_packet_fn)(const uint8_t *p, int len);

struct ez_stats { long packets, empty, errors, bytes; };
extern struct ez_stats ez_stats;

int  ez_open(int svideo);                       // open, interface 0, bridge + decoder init
int  ez_stream_start(int alt, ez_packet_fn fn); // alt setting + capture on, returns packet size
void ez_stream_poll(int ms);                    // handle USB events (calls fn)
void ez_stream_stop(void);                      // capture off, alt 0
void ez_close(void);

int  ez_reg_read(uint8_t reg);
int  ez_saa_read(uint8_t reg);
int  ez_saa_write(uint8_t reg, uint8_t val);
int  ez_signal_locked(void);                    // 1 = decoder is locked to a video signal
