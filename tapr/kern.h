// kern.h – was die TAPR-App (Swift) vom Stick sieht. Reines C, ohne libusb-Typen,
// damit Swift es direkt importieren kann.

#pragma once
#include <stdint.h>

enum {
    TAPR_WIDTH = 720,
    TAPR_HEIGHT = 576,
    TAPR_FIELD_LINES = 288,
    TAPR_LINE_BYTES = 720 * 2,                  // YUYV
    TAPR_FIELD_BYTES = 720 * 2 * 288,
};

enum {
    TAPR_SUCHT,                                 // Start, gleich geht's los
    TAPR_FEHLT,                                 // kein Stick eingesteckt
    TAPR_BELEGT,                                // Stick da, aber nicht zu oeffnen (anderer Prozess?)
    TAPR_LAEUFT,                                // Empfang laeuft
};

void tapr_start(void);                          // eigenen USB-Thread starten, sucht den Stick selbst
void tapr_stop(void);                           // Empfang aus, Stick freigeben
int  tapr_state(void);
int  tapr_signal(void);                         // 1 = Decoder ist auf ein Videosignal eingerastet
int  tapr_rate(void);                           // Halbbilder pro Sekunde vom Stick (PAL: 50)
long tapr_usb_errors(void);                     // kaputte USB-Pakete seit dem Verbinden

// Glitch-Regler: dieselben Decoder-Register wie in ezcap.c (0x03 0x08 0x09 0x0b ...).
enum { TAPR_R03, TAPR_R08, TAPR_R09, TAPR_R0B, TAPR_R0C, TAPR_R0D, TAPR_R0E, TAPR_R0F, TAPR_R11, TAPR_NREG };
int  tapr_reg(int i);                           // gewuenschter Wert, -1 = nicht verbunden
int  tapr_reg_start(int i);                     // Wert beim Verbinden (= Grundeinstellung)
void tapr_reg_set(int i, int value);            // wird kurz darauf im USB-Thread geschrieben

// Aufnahme: Vollbilder (oberes Halbbild zuerst, YUYV, max. 25/s) gehen ueber einen eigenen
// Schreib-Thread in fd (stdin von ffmpeg). Ein Puffer von 2 s faengt Haenger ab; ist er voll,
// fallen Bilder weg, der USB-Empfang wartet nie. tapr_rec_stop schreibt den Puffer leer,
// schliesst fd und kommt erst dann zurueck.
int  tapr_rec_start(int fd);                    // 0 = laeuft, fd gehoert ab jetzt dem Kern
void tapr_rec_stop(void);
void tapr_rec_swap(int swap);                   // Halbbilder tauschen, wirkt ab dem naechsten Halbbild
int  tapr_rec_active(void);                     // 0 = aus, oder der Schreib-Thread ist ausgestiegen
long tapr_rec_frames(void);                     // geschriebene Vollbilder
long tapr_rec_lost(void);                       // wegen vollem Puffer verlorene Vollbilder

// Wiedergabe: Vollbilder wie bei der Aufnahme aus fd lesen (stdout von ffmpeg) und mit 50
// Halbbildern/s anzeigen, statt des Live-Bilds. Der USB-Empfang laeuft nebenbei weiter.
int  tapr_play_start(int fd);                   // 0 = laeuft, fd gehoert ab jetzt dem Kern
void tapr_play_stop(void);
int  tapr_play_active(void);                    // 0 = aus, oder ffmpeg hat nichts mehr geliefert

// Naechstes Halbbild nach Nummer 'seen' nach dst kopieren (TAPR_FIELD_BYTES, Zeilen
// nacheinander). Haengt der Aufrufer mehr als eins hinterher, gibt's gleich das neueste.
// Gibt dessen laufende Nummer zurueck; ist sie == seen, wurde nichts kopiert.
// *top = 1 fuer das obere Halbbild (liegt im Vollbild auf den geraden Zeilen).
long tapr_field(long seen, uint8_t *dst, int *top);
