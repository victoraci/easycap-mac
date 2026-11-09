// dump_desc.c – liest den kompletten USB-Konfigurationsdeskriptor des Grabbers
// und zeigt alle Interfaces, Alternate Settings und Endpoints an.
// Nur lesen, nichts schreiben: macOS hat den Deskriptor beim Einstecken schon
// abgefragt und gecacht, wir lesen nur diese Kopie.
//
// Bauen: make dump_desc

#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define VID 0xeb1a
#define PID 0x2861

static const char *xfer_type[] = { "Control", "ISOCHRON", "Bulk", "Interrupt" };

static void dump(const uint8_t *p, int total)
{
    int off = 0;
    while (off + 2 <= total) {
        int len = p[off], type = p[off + 1];
        if (len < 2 || off + len > total) break;
        const uint8_t *d = p + off;

        if (type == 2) {            // Konfiguration
            printf("Konfiguration %d: %d Interfaces, Gesamtlaenge %d Bytes, max %d mA\n",
                   d[5], d[4], d[2] | d[3] << 8, d[8] * 2);
        } else if (type == 4) {     // Interface
            printf("\n  Interface %d, Alt %d: Klasse 0x%02x/0x%02x/0x%02x, %d Endpoints\n",
                   d[2], d[3], d[5], d[6], d[7], d[4]);
        } else if (type == 5) {     // Endpoint
            int addr = d[2], attr = d[3];
            int mps = d[4] | d[5] << 8;
            int size = mps & 0x7ff;
            int mult = ((mps >> 11) & 3) + 1;   // Pakete pro Microframe (High-Bandwidth)
            int interval = d[6];
            printf("    EP 0x%02x %-3s %-9s  %4d Bytes x %d", addr, (addr & 0x80) ? "IN" : "OUT",
                   xfer_type[attr & 3], size, mult);
            if ((attr & 3) == 1) {
                // High-Speed: 8000 Microframes/s, bInterval = 2^(n-1) Microframes
                double per_s = 8000.0 / (1 << (interval - 1));
                printf("  -> %.1f MB/s", size * mult * per_s / 1e6);
            }
            printf("  (bInterval %d)\n", interval);
        } else {                    // Klassen-spezifisch (z. B. Audio), nur roh zeigen
            printf("      [Typ 0x%02x, %d Bytes]", type, len);
            for (int i = 2; i < len; i++) printf(" %02x", d[i]);
            printf("\n");
        }
        off += len;
    }
}

int main(void)
{
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    int vid = VID, pid = PID;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR("idVendor"), v);
    CFDictionarySetValue(match, CFSTR("idProduct"), p);

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc) { fprintf(stderr, "Geraet %04x:%04x nicht gefunden\n", VID, PID); return 1; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plug, &score) != kIOReturnSuccess) {
        fprintf(stderr, "PlugIn fehlgeschlagen\n"); return 1;
    }
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) { fprintf(stderr, "DeviceInterface fehlgeschlagen\n"); return 1; }

    IOUSBConfigurationDescriptorPtr cfg;
    if ((*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg) != kIOReturnSuccess) {
        fprintf(stderr, "Konfigurationsdeskriptor nicht lesbar\n"); return 1;
    }
    dump((const uint8_t *)cfg, USBToHostWord(cfg->wTotalLength));

    (*dev)->Release(dev);
    IOObjectRelease(svc);
    return 0;
}
