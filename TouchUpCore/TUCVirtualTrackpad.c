//
//  TUCVirtualTrackpad.c
//  Touch Up Core
//

#include "TUCVirtualTrackpad.h"
#include "HIDInterpreter.h"

#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <string.h>

/**
 The device is a Magic Trackpad 2, in every respect macOS checks.

 It has to be. `AppleMultitouchTrackpadHIDEventDriver` is what turns contacts into
 gestures, and it matches on Apple's vendor and product — a device that says who it really
 is gets adopted by the generic HID driver instead and produces nothing at all. Six rounds
 of the spike established that there is no honest variant of this, which is a real cost and
 recorded as one.

 The descriptor is VoodooInput's, whose whole purpose is being driven by this same stock
 driver, and the report layout is corroborated field for field by Linux's `hid-magicmouse`.
 */
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

/// Sensor surface, in hundredths of a millimetre. The figures are a real Magic Trackpad 2's;
/// what matters is only that they are consistent with the coordinates we then report.
#define kSurfaceWidth   0x3CF0
#define kSurfaceHeight  0x2B20
#define kTrackpadMaxX   8134
#define kTrackpadMaxY   5206

#define kStateInactive  0x0
#define kStateStart     0x3   /* near | transition */
#define kStateActive    0x4   /* contact           */
#define kStateStop      0x7   /* contact | near | transition */

#define kMaxContacts    4
#define kHeaderLength   12
#define kFingerLength   9

/// Marks the device as ours, so the digitizer matching in `HIDInterpreter.c` can refuse it
/// rather than adopting our own twin as a touchscreen and feeding itself.
#define kVirtualSerialNumber "TouchUp-Virtual-Trackpad"

static IOHIDUserDeviceRef gDevice;
static dispatch_queue_t gQueue;
static bool gGestureInFlight;
static uint32_t gTimestampMilliseconds;

/// The block the driver last named, before asking for it. File scope rather than captured,
/// because the two report handlers are separate blocks that have to agree about it.
static uint8_t gPendingSelector;

#pragma mark - Answering what the driver asks

/*
 The part that took six rounds of the spike to find.

 Before it emits anything, the driver interrogates the device about its sensor: how large
 the surface is, how many rows and columns it has, which family it belongs to. A device
 with no answers is adopted and then waits forever, which is exactly what ours did until
 these existed. The values are VoodooInput's, and the driver reads them straight back out —
 they turn up in the registry on the multitouch device it creates.
*/

static size_t AnswerDirect(uint32_t reportID, uint8_t *out, size_t capacity) {
    #define EMIT(...) do { \
        static const uint8_t bytes[] = { __VA_ARGS__ }; \
        if (sizeof(bytes) > capacity) return 0; \
        memcpy(out, bytes, sizeof(bytes)); \
        return sizeof(bytes); \
    } while (0)

    switch (reportID) {
        case 0x00: EMIT(0x00, 0x01);
        case 0xD1: EMIT(0xD1, 0x81);                                        // family
        case 0xD3: EMIT(0xD3, 0x01, 0x16, 0x1E, 0x03, 0x95, 0x00,           // 22 rows,
                        0x14, 0x1E, 0x62, 0x05, 0x00, 0x00);                // 30 columns
        case 0xD0: EMIT(0xD0, 0x02, 0x01, 0x00, 0x14, 0x01, 0x00, 0x1E, 0x00,
                        0x02, 0x14, 0x02, 0x01, 0x0E, 0x02, 0x00);          // region descriptor
        case 0xA1: EMIT(0xA1, 0x00, 0x00, 0x05, 0x00, 0xFC, 0x01);          // region param
        case 0xD9: EMIT(0xD9,
                        kSurfaceWidth & 0xFF, (kSurfaceWidth >> 8) & 0xFF, 0x00, 0x00,
                        kSurfaceHeight & 0xFF, (kSurfaceHeight >> 8) & 0xFF, 0x00, 0x00,
                        0x44, 0xE3, 0x52, 0xFF, 0xBD, 0x1E, 0xE4, 0x26);    // surface descriptor
        case 0x7F: EMIT(0x7F, 0x00, 0x00, 0x00, 0x00);
        case 0xC8: EMIT(0xC8, 0x08);
        case 0x02: EMIT(0x02, 0x01);
        default:   return 0;
    }
    #undef EMIT
}

/// Every block at once, each behind a little-endian length.
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

/// How long a block is, asked before the block itself.
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
        default:   return 0;
    }
    if (capacity < 5) return 0;
    out[0] = 0x01; out[1] = selector; out[2] = 0x00; out[3] = length; out[4] = 0x00;
    return 5;
}

#pragma mark - Building a frame

static void SetNumber(CFMutableDictionaryRef properties, const char *key, int value) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &value);
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFDictionarySetValue(properties, name, number);
    CFRelease(number);
    CFRelease(name);
}

static void SetString(CFMutableDictionaryRef properties, const char *key, const char *value) {
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFStringRef text = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
    CFDictionarySetValue(properties, name, text);
    CFRelease(name);
    CFRelease(text);
}

/// Contacts are centred on the surface and the vertical axis runs the other way, so a
/// finger near the top of the glass is a large positive Y here.
static void PackFinger(uint8_t *out, const TUCVirtualContact *contact, uint8_t state) {
    double clampedX = contact->x < 0.0 ? 0.0 : (contact->x > 1.0 ? 1.0 : contact->x);
    double clampedY = contact->y < 0.0 ? 0.0 : (contact->y > 1.0 ? 1.0 : contact->y);

    int16_t x = (int16_t)((clampedX - 0.5) * kTrackpadMaxX);
    int16_t y = (int16_t)(-(clampedY - 0.5) * kTrackpadMaxY);

    uint32_t word = 0;
    word |= ((uint32_t)x & 0x1FFF);
    word |= ((uint32_t)y & 0x1FFF) << 13;
    word |= ((uint32_t)1 & 0x7) << 26;              // finger type; the driver does not mind
    word |= ((uint32_t)state & 0x7) << 29;

    out[0] = (uint8_t)(word & 0xFF);
    out[1] = (uint8_t)((word >> 8) & 0xFF);
    out[2] = (uint8_t)((word >> 16) & 0xFF);
    out[3] = (uint8_t)((word >> 24) & 0xFF);

    bool down = (state == kStateActive || state == kStateStart);
    out[4] = down ? 20 : 0;     // touch major
    out[5] = down ? 20 : 0;     // touch minor
    out[6] = down ? 10 : 0;     // size
    out[7] = down ? 5  : 0;     // pressure — a resting finger, not a click
    // Identifier, a spare bit, then the ellipse angle as a right angle.
    uint8_t identifier = contact->identifier ? ((contact->identifier - 1) % 15) + 1 : 1;
    out[8] = (uint8_t)((identifier & 0x0F) | (0x4 << 5));
}

static size_t BuildFrame(uint8_t *out, const TUCVirtualContact *contacts, size_t count,
                         uint8_t state, bool anythingActive) {
    if (count > kMaxContacts) count = kMaxContacts;

    memset(out, 0, kHeaderLength);
    out[0] = 0x02;                              // report ID
    out[1] = 0x00;                              // no physical button
    out[7] = anythingActive ? 0x03 : 0x02;
    out[8] = 0x31;                              // the multitouch report inside this one

    // Must advance, every time. The stack discards frames whose timestamp repeats, and a
    // stalled clock reads to it as a device that has stopped saying anything new.
    gTimestampMilliseconds += 8;
    out[9]  = (uint8_t)((gTimestampMilliseconds << 3) | 0x4);
    out[10] = (uint8_t)((gTimestampMilliseconds >> 5) & 0xFF);
    out[11] = (uint8_t)((gTimestampMilliseconds >> 13) & 0xFF);

    for (size_t i = 0; i < count; i++) {
        PackFinger(out + kHeaderLength + (i * kFingerLength), &contacts[i], state);
    }
    return kHeaderLength + (count * kFingerLength);
}

static void SendFrame(const uint8_t *frame, size_t length) {
    if (!gDevice) return;
    IOHIDUserDeviceHandleReportWithTimeStamp(gDevice, mach_absolute_time(), frame, (CFIndex)length);
}

#pragma mark - Lifetime

bool TUCVirtualTrackpadPublish(void) {
    if (gDevice) return true;

    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef descriptor = CFDataCreate(NULL, kReportDescriptor, sizeof(kReportDescriptor));
    CFDictionarySetValue(properties, CFSTR("ReportDescriptor"), descriptor);
    CFRelease(descriptor);

    SetNumber(properties, "VendorID", 0x05AC);
    SetNumber(properties, "ProductID", 0x0265);
    SetNumber(properties, "VersionNumber", 0x0110);
    SetString(properties, "Manufacturer", "Apple Inc.");
    SetString(properties, "Product", "Magic Trackpad 2");
    SetString(properties, "SerialNumber", kVirtualSerialNumber);
    SetString(properties, "Transport", "USB");
    SetNumber(properties, "PrimaryUsagePage", 0x01);
    SetNumber(properties, "PrimaryUsage", 0x02);

    gDevice = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties, 0);
    CFRelease(properties);

    if (!gDevice) {
        LogToHIDDiagnostics("virtual trackpad: the kernel refused the device — most likely the "
                            "com.apple.developer.hid.virtual.device entitlement is missing");
        return false;
    }

    // Registered before activation, as the API requires: a request that arrives with no
    // handler is an unanswered question, and an unanswered question is a silent device.
    gPendingSelector = 0;

    IOHIDUserDeviceRegisterGetReportBlock(gDevice,
        ^IOReturn(IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex *reportLength) {
            (void)type;
            size_t written;
            if (reportID == 0x01)      written = AnswerSelector(gPendingSelector, report, (size_t)*reportLength);
            else if (reportID == 0xDB) written = AnswerAggregate(report, (size_t)*reportLength);
            else                       written = AnswerDirect(reportID, report, (size_t)*reportLength);

            if (!written) return kIOReturnUnsupported;
            *reportLength = (CFIndex)written;
            return kIOReturnSuccess;
        });

    IOHIDUserDeviceRegisterSetReportBlock(gDevice,
        ^IOReturn(IOHIDReportType type, uint32_t reportID, const uint8_t *report, CFIndex reportLength) {
            (void)type;
            // The driver names the block it is about to ask for, then asks for it.
            if (reportID == 0x01 && reportLength > 1) gPendingSelector = report[1];
            return kIOReturnSuccess;
        });

    gQueue = dispatch_queue_create("de.schafe.touchup.virtualtrackpad", DISPATCH_QUEUE_SERIAL);
    IOHIDUserDeviceSetDispatchQueue(gDevice, gQueue);
    IOHIDUserDeviceActivate(gDevice);

    gGestureInFlight = false;
    gTimestampMilliseconds = 100;

    LogToHIDDiagnostics("virtual trackpad: published");
    return true;
}

void TUCVirtualTrackpadRetire(void) {
    if (!gDevice) return;

    TUCVirtualTrackpadLiftoff();
    IOHIDUserDeviceCancel(gDevice);
    CFRelease(gDevice);
    gDevice = NULL;
    gQueue = NULL;
    gGestureInFlight = false;

    LogToHIDDiagnostics("virtual trackpad: retired");
}

bool TUCVirtualTrackpadIsPublished(void) {
    return gDevice != NULL;
}

bool TUCVirtualTrackpadIsDriven(void) {
    if (!gDevice) return false;

    // The multitouch device the driver creates carries our serial number, which is the
    // cheapest proof that something adopted us rather than merely that we exist.
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("AppleMultitouchDevice"),
                                     &iterator) != KERN_SUCCESS) {
        return false;
    }

    bool driven = false;
    io_service_t service;
    while (!driven && (service = IOIteratorNext(iterator))) {
        CFTypeRef serial = IORegistryEntryCreateCFProperty(service,
                                                           CFSTR("Multitouch Serial Number"),
                                                           kCFAllocatorDefault, 0);
        if (serial) {
            if (CFGetTypeID(serial) == CFStringGetTypeID()
                && CFStringCompare((CFStringRef)serial, CFSTR(kVirtualSerialNumber), 0) == kCFCompareEqualTo) {
                driven = true;
            }
            CFRelease(serial);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return driven;
}

#pragma mark - Gestures

void TUCVirtualTrackpadSubmit(const TUCVirtualContact *contacts, size_t count) {
    if (!gDevice || count == 0) return;

    uint8_t frame[kHeaderLength + (kMaxContacts * kFingerLength)];
    uint8_t state = gGestureInFlight ? kStateActive : kStateStart;
    size_t length = BuildFrame(frame, contacts, count, state, true);
    SendFrame(frame, length);
    gGestureInFlight = true;
}

void TUCVirtualTrackpadLiftoff(void) {
    if (!gDevice || !gGestureInFlight) return;

    // Three reports, as a real one ends: the contacts stop, then go inactive, then the
    // frame carries nobody at all. Without the full sequence the paths stay open and the
    // next gesture is read as a continuation of this one.
    TUCVirtualContact resting = { .x = 0.5, .y = 0.5, .identifier = 1 };
    uint8_t frame[kHeaderLength + (kMaxContacts * kFingerLength)];

    SendFrame(frame, BuildFrame(frame, &resting, 1, kStateStop, true));
    SendFrame(frame, BuildFrame(frame, &resting, 1, kStateInactive, false));
    SendFrame(frame, BuildFrame(frame, NULL, 0, kStateInactive, false));

    gGestureInFlight = false;
}
