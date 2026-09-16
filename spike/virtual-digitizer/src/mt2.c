//
//  mt2.c — publish a virtual device that impersonates a Magic Trackpad 2, well enough
//  that Apple's own multitouch driver adopts it and emits real gestures.
//
//  Why this shape: rounds 1–5 showed the multitouch driver will adopt a virtual device
//  and then stay silent. VoodooInput (acidanthera) does the same thing from a kext and
//  is driven successfully by the stock driver, which tells us what was missing — before
//  emitting anything, the driver interrogates the device with GET_REPORT requests for
//  its sensor geometry. A device that answers nothing has told it nothing, so it waits.
//
//  Two protocol sources, which agree with each other field for field:
//    - linux/drivers/hid/hid-magicmouse.c  (the read side)
//    - acidanthera/VoodooInput, VoodooInputSimulatorDevice.{hpp,cpp}  (the write side)
//
//  Every GET/SET report request is logged whatever happens. Even a total failure leaves
//  a map of what the driver actually asks a multitouch device for, which is the thing
//  no amount of reading Apple's binaries has given us.
//
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// VoodooInput's descriptor, verbatim. Mouse collection on report ID 0x02 (the multitouch
// payload rides on the same ID, longer than declared — the driver accepts that), a
// digitizer/touchpad collection on 0x3F, and a vendor image channel on 0x44.
static const uint8_t kReportDescriptor[] = {
    0x05,0x01, 0x09,0x02, 0xa1,0x01, 0x09,0x01, 0xa1,0x00, 0x05,0x09, 0x19,0x01, 0x29,0x03,
    0x15,0x00, 0x25,0x01, 0x85,0x02, 0x95,0x03, 0x75,0x01, 0x81,0x02, 0x95,0x01, 0x75,0x05,
    0x81,0x01, 0x05,0x01, 0x09,0x30, 0x09,0x31, 0x15,0x81, 0x25,0x7f, 0x75,0x08, 0x95,0x02,
    0x81,0x06, 0x95,0x04, 0x75,0x08, 0x81,0x01, 0xc0, 0xc0,
    0x05,0x0d, 0x09,0x05, 0xa1,0x01, 0x06,0x00,0xff, 0x09,0x0c, 0x15,0x00, 0x26,0xff,0x00,
    0x75,0x08, 0x95,0x10, 0x85,0x3f, 0x81,0x22, 0xc0,
    0x06,0x00,0xff, 0x09,0x0c, 0xa1,0x01, 0x06,0x00,0xff, 0x09,0x0c, 0x15,0x00, 0x26,0xff,0x00,
    0x85,0x44, 0x75,0x08, 0x96,0x6b,0x05, 0x81,0x00, 0xc0,
};

// Sensor surface, in hundredths of a millimetre: a real Magic Trackpad 2.
#define kSurfaceWidth  0x3CF0   /* 15.600 cm */
#define kSurfaceHeight 0x2B20   /* 11.040 cm */
#define kMT2MaxX 8134
#define kMT2MaxY 5206

// Touch state, as VoodooInput names it; the bits agree with hid-magicmouse's reading.
#define kStateInactive 0x0
#define kStateStart    0x3   /* NEAR | TRANSITION */
#define kStateActive   0x4   /* CONTACT           */
#define kStateStop     0x7   /* CONTACT|NEAR|TRANS */

static void SetNum(CFMutableDictionaryRef d, const char *k, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    CFDictionarySetValue(d, key, n);
    CFRelease(n); CFRelease(key);
}

static void SetStr(CFMutableDictionaryRef d, const char *k, const char *v) {
    CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    CFStringRef val = CFStringCreateWithCString(NULL, v, kCFStringEncodingUTF8);
    CFDictionarySetValue(d, key, val);
    CFRelease(key); CFRelease(val);
}

static CGPoint PointerLocation(void) {
    CGEventRef probe = CGEventCreate(NULL);
    CGPoint where = CGEventGetLocation(probe);
    CFRelease(probe);
    return where;
}

#pragma mark - The interrogation the driver performs

/// Canned answer for a directly-addressed GET_REPORT, as VoodooInput replies. Returns the
/// length written, or 0 for a report id we have nothing to say about.
static size_t AnswerDirect(uint32_t reportID, uint8_t *out, size_t capacity) {
    #define EMIT(...) do { \
        const uint8_t bytes[] = { __VA_ARGS__ }; \
        if (sizeof(bytes) > capacity) return 0; \
        memcpy(out, bytes, sizeof(bytes)); \
        return sizeof(bytes); \
    } while (0)

    switch (reportID) {
        case 0x00: EMIT(0x00, 0x01);
        case 0xD1: EMIT(0xD1, 0x81);                                   // Family ID 0x81
        case 0xD3: EMIT(0xD3, 0x01, 0x16, 0x1E, 0x03, 0x95, 0x00,      // 0x16 rows,
                        0x14, 0x1E, 0x62, 0x05, 0x00, 0x00);           // 0x1E columns
        case 0xD0: EMIT(0xD0, 0x02, 0x01, 0x00, 0x14, 0x01, 0x00, 0x1E, 0x00,
                        0x02, 0x14, 0x02, 0x01, 0x0E, 0x02, 0x00);     // region descriptor
        case 0xA1: EMIT(0xA1, 0x00, 0x00, 0x05, 0x00, 0xFC, 0x01);     // region param
        case 0xD9: EMIT(0xD9,
                        kSurfaceWidth & 0xFF, (kSurfaceWidth >> 8) & 0xFF, 0x00, 0x00,
                        kSurfaceHeight & 0xFF, (kSurfaceHeight >> 8) & 0xFF, 0x00, 0x00,
                        0x44, 0xE3, 0x52, 0xFF, 0xBD, 0x1E, 0xE4, 0x26);
        case 0x7F: EMIT(0x7F, 0x00, 0x00, 0x00, 0x00);
        case 0xC8: EMIT(0xC8, 0x08);
        case 0x02: EMIT(0x02, 0x01);
        default: return 0;
    }
    #undef EMIT
}

/// The 0xDB aggregate: every descriptor block, each preceded by a little-endian length.
static size_t AnswerAggregate(uint8_t *out, size_t capacity) {
    static const uint8_t blob[] = {
        0xDB, 0x01, 0x02, 0x00,
        0xD1, 0x81,
        0x0D, 0x00,
        0xD3, 0x01, 0x16, 0x1E, 0x03, 0x95, 0x00, 0x14, 0x1E, 0x62, 0x05, 0x00, 0x00,
        0x10, 0x00,
        0xD0, 0x02, 0x01, 0x00, 0x14, 0x01, 0x00, 0x1E, 0x00, 0x02, 0x14, 0x02, 0x01, 0x0E, 0x02, 0x00,
        0x07, 0x00,
        0xA1, 0x00, 0x00, 0x05, 0x00, 0xFC, 0x01,
        0x11, 0x00,
        0xD9, kSurfaceWidth & 0xFF, (kSurfaceWidth >> 8) & 0xFF, 0x00, 0x00,
              kSurfaceHeight & 0xFF, (kSurfaceHeight >> 8) & 0xFF, 0x00, 0x00,
              0x44, 0xE3, 0x52, 0xFF, 0xBD, 0x1E, 0xE4, 0x26,
        0x7F, 0x00, 0x00, 0x00, 0x00,
    };
    if (sizeof(blob) > capacity) return 0;
    memcpy(out, blob, sizeof(blob));
    return sizeof(blob);
}

/// Length announcement for a selector, the answer to "how big is block X".
static size_t AnswerSelector(uint8_t selector, uint8_t *out, size_t capacity) {
    uint8_t length;
    switch (selector) {
        case 0xDB: length = 0x49; break;
        case 0xD1: length = 0x01; break;
        case 0xD3: length = 0x0C; break;
        case 0xD0: length = 0x0F; break;
        case 0xA1: length = 0x06; break;
        case 0x7F: length = 0x04; break;
        case 0xC8: length = 0x01; break;
        default: return 0;
    }
    if (capacity < 5) return 0;
    out[0] = 0x01; out[1] = selector; out[2] = 0x00; out[3] = length; out[4] = 0x00;
    return 5;
}

#pragma mark - Input reports

typedef struct { int16_t x, y; uint8_t identifier, state; } Finger;

static void PackFinger(uint8_t *out, const Finger *f) {
    uint32_t word = 0;
    word |= ((uint32_t)f->x & 0x1FFF);          // bits  0..12, signed 13
    word |= ((uint32_t)f->y & 0x1FFF) << 13;    // bits 13..25, signed 13
    word |= ((uint32_t)1 & 0x7) << 26;          // finger index (1 = index finger)
    word |= ((uint32_t)f->state & 0x7) << 29;   // state
    out[0] = word & 0xFF; out[1] = (word >> 8) & 0xFF;
    out[2] = (word >> 16) & 0xFF; out[3] = (word >> 24) & 0xFF;

    bool down = (f->state == kStateActive || f->state == kStateStart);
    out[4] = down ? 20 : 0;      // touch major
    out[5] = down ? 20 : 0;      // touch minor
    out[6] = down ? 10 : 0;      // size
    out[7] = down ? 5 : 0;       // pressure
    out[8] = (uint8_t)((f->identifier & 0x0F) | (0x4 << 5));   // id + angle (pi/2)
}

static size_t BuildReport(uint8_t *out, const Finger *fingers, size_t count,
                          uint32_t milliseconds, bool anythingActive) {
    memset(out, 0, 12);
    out[0] = 0x02;                       // report ID
    out[1] = 0x00;                       // button
    out[7] = anythingActive ? 0x03 : 0x02;
    out[8] = 0x31;                       // inner multitouch report id
    out[9]  = (uint8_t)((milliseconds << 3) | 0x4);
    out[10] = (uint8_t)((milliseconds >> 5) & 0xFF);
    out[11] = (uint8_t)((milliseconds >> 13) & 0xFF);
    for (size_t i = 0; i < count; i++) PackFinger(out + 12 + (i * 9), &fingers[i]);
    return 12 + (count * 9);
}

int main(int argc, char **argv) {
    int hold = 25;
    const char *gesture = "drag";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hold") && i + 1 < argc) hold = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--gesture") && i + 1 < argc) gesture = argv[++i];
    }

    CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef desc = CFDataCreate(NULL, kReportDescriptor, sizeof(kReportDescriptor));
    CFDictionarySetValue(props, CFSTR("ReportDescriptor"), desc);
    SetNum(props, "VendorID", 0x05AC);
    SetNum(props, "ProductID", 0x0265);          // Magic Trackpad 2, USB
    SetNum(props, "VersionNumber", 0x0110);
    SetStr(props, "Manufacturer", "Apple Inc.");
    SetStr(props, "Product", "Magic Trackpad 2");
    SetStr(props, "SerialNumber", "TouchUp-Virtual-0001");
    SetStr(props, "Transport", "USB");
    SetNum(props, "PrimaryUsagePage", 0x01);
    SetNum(props, "PrimaryUsage", 0x02);

    printf("publishing Magic Trackpad 2 emulation: descriptor %zu bytes, VID 0x05AC PID 0x0265\n",
           sizeof(kReportDescriptor));
    fflush(stdout);

    IOHIDUserDeviceRef dev = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, props, 0);
    if (!dev) { printf("RESULT: create returned NULL — the kernel refused the device\n"); return 1; }

    // Registered before activation, as the header requires. Every request is logged: the
    // sequence itself is the finding, whether or not any of the answers satisfy the driver.
    __block int getCount = 0, setCount = 0;
    __block uint8_t pendingSelector = 0;

    IOHIDUserDeviceRegisterGetReportBlock(dev,
        ^IOReturn(IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex *reportLength) {
            size_t written = 0;
            if (reportID == 0x01)      written = AnswerSelector(pendingSelector, report, (size_t)*reportLength);
            else if (reportID == 0xDB) written = AnswerAggregate(report, (size_t)*reportLength);
            else                       written = AnswerDirect(reportID, report, (size_t)*reportLength);

            getCount++;
            printf("  GET  type=%d id=0x%02X capacity=%ld -> %s%zu bytes\n",
                   (int)type, reportID, (long)*reportLength,
                   written ? "answered " : "UNHANDLED ", written);
            fflush(stdout);

            if (!written) return kIOReturnUnsupported;
            *reportLength = (CFIndex)written;
            return kIOReturnSuccess;
        });

    IOHIDUserDeviceRegisterSetReportBlock(dev,
        ^IOReturn(IOHIDReportType type, uint32_t reportID, const uint8_t *report, CFIndex reportLength) {
            setCount++;
            if (reportID == 0x01 && reportLength > 1) pendingSelector = report[1];
            printf("  SET  type=%d id=0x%02X length=%ld%s\n", (int)type, reportID, (long)reportLength,
                   (reportID == 0x01 && reportLength > 1) ? " (selector recorded)" : "");
            fflush(stdout);
            return kIOReturnSuccess;
        });

    dispatch_queue_t queue = dispatch_queue_create("de.schafe.touchup.mt2", DISPATCH_QUEUE_SERIAL);
    IOHIDUserDeviceSetDispatchQueue(dev, queue);
    IOHIDUserDeviceActivate(dev);

    printf("RESULT: created and activated\n");
    fflush(stdout);

    // Let the driver interrogate the device before anything is sent.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 4.0, false);
    printf("interrogation so far: %d get, %d set\n", getCount, setCount);
    fflush(stdout);

    CGPoint before = PointerLocation();
    uint8_t report[12 + 9 * 4];
    const int frames = 90;
    uint32_t ms = 100;

    // One finger moves the pointer; two fingers scroll and never move it. That difference
    // is the whole basis of the hybrid: absolute positioning stays with the existing
    // event synthesis, and only multi-finger gestures are handed to this device.
    bool twoFingers = (strcmp(gesture, "scroll") == 0);
    printf("feeding %d frames of a %s...\n", frames, twoFingers ? "two-finger scroll" : "one-finger drag");
    fflush(stdout);

    for (int i = 0; i < frames; i++) {
        double t = (double)i / (double)(frames - 1);
        Finger fingers[2];
        size_t count = twoFingers ? 2 : 1;

        if (twoFingers) {
            // Both fingers travel together up the surface: a scroll, not a drag.
            int16_t y = (int16_t)(-1500 + t * 3000);
            fingers[0] = (Finger){ .x = -600, .y = y, .identifier = 1,
                                   .state = (i == 0) ? kStateStart : kStateActive };
            fingers[1] = (Finger){ .x =  600, .y = y, .identifier = 2,
                                   .state = (i == 0) ? kStateStart : kStateActive };
        } else {
            fingers[0] = (Finger){ .x = (int16_t)(-2000 + t * 4000),
                                   .y = (int16_t)(-1000 + t * 2000), .identifier = 1,
                                   .state = (i == 0) ? kStateStart : kStateActive };
        }

        size_t length = BuildReport(report, fingers, count, ms, true);
        IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), report, (CFIndex)length);
        ms += 8;
        usleep(8000);
    }

    // VoodooInput's liftoff: zeroed sizes, then inactive, then a bare header.
    size_t liftCount = twoFingers ? 2 : 1;
    Finger lift[2] = {
        { .x = twoFingers ? -600 : 2000, .y = 1500, .identifier = 1, .state = kStateStop },
        { .x = 600, .y = 1500, .identifier = 2, .state = kStateStop },
    };
    IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), report,
                                             (CFIndex)BuildReport(report, lift, liftCount, ms += 10, true));
    lift[0].state = lift[1].state = kStateInactive;
    IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), report,
                                             (CFIndex)BuildReport(report, lift, liftCount, ms += 10, false));
    IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), report,
                                             (CFIndex)BuildReport(report, NULL, 0, ms += 10, false));

    usleep(400000);
    CGPoint after = PointerLocation();
    printf("sweep done; pointer %.0f,%.0f -> %.0f,%.0f  POINTER %s\n",
           before.x, before.y, after.x, after.y,
           (before.x != after.x || before.y != after.y)
               ? "MOVED — the system is acting on our reports"
               : "did not move");
    printf("totals: %d get requests, %d set requests\n", getCount, setCount);
    fflush(stdout);

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, (CFTimeInterval)hold, false);
    IOHIDUserDeviceCancel(dev);
    printf("retired\n");
    return 0;
}
