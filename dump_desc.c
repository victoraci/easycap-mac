// dump_desc.c – reads the grabber's complete USB configuration descriptor
// and shows all interfaces, alternate settings and endpoints.
// Read only, nothing is written: macOS already fetched and cached the descriptor
// when the stick was plugged in, we only read that copy.
//
// Build: make dump_desc

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

        if (type == 2) {            // configuration
            printf("Configuration %d: %d interfaces, total length %d bytes, max %d mA\n",
                   d[5], d[4], d[2] | d[3] << 8, d[8] * 2);
        } else if (type == 4) {     // interface
            printf("\n  Interface %d, alt %d: class 0x%02x/0x%02x/0x%02x, %d endpoints\n",
                   d[2], d[3], d[5], d[6], d[7], d[4]);
        } else if (type == 5) {     // endpoint
            int addr = d[2], attr = d[3];
            int mps = d[4] | d[5] << 8;
            int size = mps & 0x7ff;
            int mult = ((mps >> 11) & 3) + 1;   // packets per microframe (high bandwidth)
            int interval = d[6];
            printf("    EP 0x%02x %-3s %-9s  %4d bytes x %d", addr, (addr & 0x80) ? "IN" : "OUT",
                   xfer_type[attr & 3], size, mult);
            if ((attr & 3) == 1) {
                // High speed: 8000 microframes/s, bInterval = 2^(n-1) microframes
                double per_s = 8000.0 / (1 << (interval - 1));
                printf("  -> %.1f MB/s", size * mult * per_s / 1e6);
            }
            printf("  (bInterval %d)\n", interval);
        } else {                    // class-specific (e.g. audio), only shown raw
            printf("      [type 0x%02x, %d bytes]", type, len);
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
    if (!svc) { fprintf(stderr, "Device %04x:%04x not found\n", VID, PID); return 1; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plug, &score) != kIOReturnSuccess) {
        fprintf(stderr, "Plug-in failed\n"); return 1;
    }
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) { fprintf(stderr, "Device interface failed\n"); return 1; }

    IOUSBConfigurationDescriptorPtr cfg;
    if ((*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg) != kIOReturnSuccess) {
        fprintf(stderr, "Configuration descriptor not readable\n"); return 1;
    }
    dump((const uint8_t *)cfg, USBToHostWord(cfg->wTotalLength));

    (*dev)->Release(dev);
    IOObjectRelease(svc);
    return 0;
}
