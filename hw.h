// hw.h – alles, was direkt mit dem Stick redet (EM2860 + SAA7113).

#pragma once
#include <stdint.h>
#include <libusb.h>

#define EZ_VID 0xeb1a
#define EZ_PID 0x2861
#define EZ_EP_VIDEO 0x82

#define EZ_WIDTH 720
#define EZ_HEIGHT 576
#define EZ_LINE_BYTES (EZ_WIDTH * 2)                    // YUYV: 2 Bytes pro Pixel
#define EZ_FIELD_BYTES (EZ_LINE_BYTES * EZ_HEIGHT / 2)  // ein Halbbild = 288 Zeilen

// Wird fuer jedes nicht-leere isochrone Paket aufgerufen (inkl. 4-Byte-Kopf).
typedef void (*ez_packet_fn)(const uint8_t *p, int len);

struct ez_stats { long packets, empty, errors, bytes; };
extern struct ez_stats ez_stats;

int  ez_open(int svideo);                       // oeffnen, Interface 0, Bridge + Decoder init
int  ez_stream_start(int alt, ez_packet_fn fn); // Alt-Setting + Capture an, liefert Paketgroesse
void ez_stream_poll(int ms);                    // USB-Ereignisse abarbeiten (ruft fn auf)
void ez_stream_stop(void);                      // Capture aus, Alt 0
void ez_close(void);

int  ez_reg_read(uint8_t reg);
int  ez_saa_read(uint8_t reg);
int  ez_saa_write(uint8_t reg, uint8_t val);
int  ez_signal_locked(void);                    // 1 = Decoder ist auf ein Videosignal eingerastet
