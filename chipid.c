// chipid.c – reads a few registers from the eMPIA chip and scans the I2C bus.
// READ requests only, just like the Linux em28xx driver does when the stick is plugged in.
//
// Build: make chipid

#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define VID 0xeb1a
#define PID 0x2861

static IOUSBDeviceInterface **dev;

// Vendor request IN: em28xx uses bRequest 0 = read register, 2 = read I2C.
static int vendor_in(uint8_t req, uint16_t index, uint8_t *buf, uint16_t len)
{
    IOUSBDevRequest r = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice),
        .bRequest = req, .wValue = 0, .wIndex = index, .wLength = len, .pData = buf,
    };
    IOReturn kr = (*dev)->DeviceRequest(dev, &r);
    return kr == kIOReturnSuccess ? (int)r.wLenDone : -1;
}

static int reg_read(uint8_t reg)
{
    uint8_t v;
    return vendor_in(0, reg, &v, 1) == 1 ? v : -1;
}

static const char *chip_name(int id)
{
    switch (id) {
    case 7:  return "EM2800";
    case 18: return "EM2820 / EM2710";
    case 20: return "EM2840";
    case 33: return "EM2750";
    case 34: return "EM2860";
    case 35: return "EM2870";
    case 36: return "EM2883";
    case 37: return "EM2882 / EM2881";
    case 54: return "EM2765";
    case 65: return "EM2874";
    case 68: return "EM2884";
    default: return "unknown";
    }
}

static const char *i2c_name(int addr8)
{
    switch (addr8) {
    case 0x4a: return "SAA7113 / GM7113C (video decoder)";
    case 0x48: return "SAA711x (alternative address)";
    case 0xb8: case 0xba: return "TVP5150 (video decoder)";
    case 0xa0: return "EEPROM";
    case 0x88: return "MSP34xx (audio)";
    default: return "?";
    }
}

int main(void)
{
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    int vid = VID, pid = PID;
    CFDictionarySetValue(match, CFSTR("idVendor"), CFNumberCreate(NULL, kCFNumberIntType, &vid));
    CFDictionarySetValue(match, CFSTR("idProduct"), CFNumberCreate(NULL, kCFNumberIntType, &pid));
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc) { fprintf(stderr, "Device not found\n"); return 1; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plug, &score)) {
        fprintf(stderr, "Plug-in failed\n"); return 1;
    }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) return 1;

    int id = reg_read(0x0a);
    if (id < 0) { fprintf(stderr, "Register read failed\n"); return 1; }
    printf("Chip ID (reg 0x0a): %d -> %s\n", id, chip_name(id));

    int cfg = reg_read(0x00);
    int i2c = reg_read(0x06);
    printf("Reg 0x00 CHIPCFG : 0x%02x\n", cfg);
    printf("Reg 0x06 I2C_CLK : 0x%02x  (EEPROM on board: %s)\n", i2c, (i2c & 0x08) ? "yes" : "no");
    printf("Reg 0x08 GPIO    : 0x%02x\n", reg_read(0x08));

    printf("\nI2C scan:\n");
    int found = 0;
    for (int a7 = 1; a7 < 0x78; a7++) {
        uint8_t b;
        int a8 = a7 << 1;
        if (vendor_in(2, a8, &b, 1) < 0) continue;
        int st = reg_read(0x05);   // I2C status: 0 = ACK, 0x10 = nobody there
        if (st == 0) {
            printf("  0x%02x  %s\n", a8, i2c_name(a8));
            found++;
        }
    }
    if (!found) printf("  (nothing found)\n");

    (*dev)->Release(dev);
    IOObjectRelease(svc);
    return 0;
}
