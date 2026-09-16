//
//  TUCVirtualTrackpad.c
//  Touch Up Core
//

#include "TUCVirtualTrackpad.h"
#include "HIDInterpreter.h"

#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <dispatch/dispatch.h>
#include <Block.h>
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

/// The fingers as last reported, so the gesture can be ended where they actually were.
/// Lifting from anywhere else is a real movement as far as the system is concerned, and a
/// long one arriving in a single frame is read as a flick.
static TUCVirtualContact gLastContacts[kMaxContacts];
static size_t gLastContactCount;

/// Real elapsed time, not a count of frames.
///
/// The system works out how fast a gesture was moving from the distance between frames and
/// the time between them, so inventing the time invents the speed with it: a panel
/// reporting at 60 Hz would appear to move twice as fast as it did, and the momentum of
/// every flick would be wrong in proportion. Which defeats the point of handing gestures
/// over in the first place.
static uint64_t gPublishTime;
static mach_timebase_info_data_t gTimebase;
static uint32_t gLastTimestamp;

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

/**
 Every block at once, each behind a little-endian length.

 Two things here are not quite right and are kept anyway. The blob is 72 bytes while the
 length announced for it is 0x49, and the trailing 0x7F block carries no length prefix
 where every other block does. Both are inherited from VoodooInput, both are plainly
 inconsistent, and the driver accepts them: it read this aggregate, asked for nothing more,
 and switched the device into multitouch mode. Tidying an undocumented protocol on the
 strength of it looking untidy is how a working handshake stops working.
 */
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

/// Milliseconds since the device was published, never repeating: two frames inside the
/// same millisecond would otherwise carry the same stamp, and the stack discards a frame
/// whose timestamp it has already seen.
static uint32_t ElapsedMilliseconds(void) {
    uint64_t elapsed = mach_absolute_time() - gPublishTime;
    uint32_t milliseconds = (uint32_t)((elapsed * gTimebase.numer) / (gTimebase.denom * 1000000ULL));
    if (milliseconds <= gLastTimestamp) {
        milliseconds = gLastTimestamp + 1;
    }
    gLastTimestamp = milliseconds;
    return milliseconds;
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

    uint32_t milliseconds = ElapsedMilliseconds();
    out[9]  = (uint8_t)((milliseconds << 3) | 0x4);
    out[10] = (uint8_t)((milliseconds >> 5) & 0xFF);
    out[11] = (uint8_t)((milliseconds >> 13) & 0xFF);

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

    // One queue for the life of the process. Publishing and retiring can happen repeatedly
    // as the setting is turned on and off, and a fresh queue each time would be one leaked
    // each time — this file is plain C, so nothing reclaims it.
    static dispatch_once_t queueOnce;
    dispatch_once(&queueOnce, ^{
        gQueue = dispatch_queue_create("de.schafe.touchup.virtualtrackpad", DISPATCH_QUEUE_SERIAL);
    });
    IOHIDUserDeviceSetDispatchQueue(gDevice, gQueue);

    // Released here and nowhere else. The header is explicit that the reference may only be
    // let go once cancellation has finished, because the asynchronous machinery is still
    // holding it until then; releasing at the point of cancelling is a use-after-free that
    // would land on whoever turned the setting off mid-interrogation.
    IOHIDUserDeviceRef device = gDevice;
    dispatch_block_t cancelHandler = dispatch_block_create(0, ^{
        CFRelease(device);
    });
    IOHIDUserDeviceSetCancelHandler(gDevice, cancelHandler);
    Block_release(cancelHandler);

    IOHIDUserDeviceActivate(gDevice);

    gGestureInFlight = false;
    gLastContactCount = 0;
    gLastTimestamp = 0;
    gPublishTime = mach_absolute_time();
    if (gTimebase.denom == 0) {
        mach_timebase_info(&gTimebase);
    }

    LogToHIDDiagnostics("virtual trackpad: published");
    return true;
}

void TUCVirtualTrackpadRetire(void) {
    if (!gDevice) return;

    TUCVirtualTrackpadLiftoff();

    // The cancel handler owns the release; letting go of the reference here as well would
    // be one release too many.
    IOHIDUserDeviceCancel(gDevice);
    gDevice = NULL;
    gGestureInFlight = false;
    gLastContactCount = 0;

    LogToHIDDiagnostics("virtual trackpad: retired");
}

bool TUCVirtualTrackpadIsPublished(void) {
    return gDevice != NULL;
}

/// Whether `service` or anything below it is one of the multitouch drivers.
static bool SubtreeHasMultitouchDriver(io_service_t service, int depth) {
    if (depth > 6) {
        return false;
    }

    io_name_t className = "";
    if (IOObjectGetClass(service, className) == KERN_SUCCESS) {
        if (strcmp(className, "AppleMultitouchTrackpadHIDEventDriver") == 0
            || strcmp(className, "AppleMultitouchDevice") == 0
            || strcmp(className, "AppleMultitouchHIDService") == 0) {
            return true;
        }
    }

    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) != KERN_SUCCESS) {
        return false;
    }

    bool found = false;
    io_service_t child;
    while (!found && (child = IOIteratorNext(children))) {
        found = SubtreeHasMultitouchDriver(child, depth + 1);
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
    return found;
}


/**
 Whether the multitouch driver has adopted our device.

 Asked by walking down from the device itself, found by the serial number nothing else
 carries. The obvious shortcut — look for a multitouch device and check whose it is — does
 not work: on this path the multitouch device exposes no serial at all, so there is nothing
 on it to compare against, and a real Magic Trackpad attached to the same Mac would look
 exactly like success. Which is worth spelling out, because the first version of this did
 precisely that and reported failure every time while the trackpad underneath was working.
 */
bool TUCVirtualTrackpadIsDriven(void) {
    if (!gDevice) {
        return false;
    }

    CFMutableDictionaryRef matching = IOServiceMatching("IOHIDDevice");
    if (!matching) {
        return false;
    }

    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(properties, CFSTR("SerialNumber"), CFSTR(kVirtualSerialNumber));
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), properties);
    CFRelease(properties);

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return false;
    }

    bool driven = false;
    io_service_t device;
    while (!driven && (device = IOIteratorNext(iterator))) {
        driven = SubtreeHasMultitouchDriver(device, 0);
        IOObjectRelease(device);
    }
    IOObjectRelease(iterator);
    return driven;
}


#pragma mark - Gestures

void TUCVirtualTrackpadSubmit(const TUCVirtualContact *contacts, size_t count) {
    if (!gDevice || count == 0) return;

    if (count > kMaxContacts) count = kMaxContacts;

    uint8_t frame[kHeaderLength + (kMaxContacts * kFingerLength)];
    uint8_t state = gGestureInFlight ? kStateActive : kStateStart;
    size_t length = BuildFrame(frame, contacts, count, state, true);
    SendFrame(frame, length);

    memcpy(gLastContacts, contacts, count * sizeof(TUCVirtualContact));
    gLastContactCount = count;
    gGestureInFlight = true;
}

void TUCVirtualTrackpadLiftoff(void) {
    if (!gDevice || !gGestureInFlight) return;

    // Three reports, as a real one ends: the contacts stop, then go inactive, then the
    // frame carries nobody at all. Without the full sequence the paths stay open and the
    // next gesture is read as a continuation of this one.
    //
    // Every finger that was down, at the position it was last seen at. Ending a two-finger
    // scroll with one invented contact in the middle of the surface would be a finger
    // travelling half the pad in a single frame — a flick nobody made — and would leave the
    // other finger's path open, never having been told it ended.
    uint8_t frame[kHeaderLength + (kMaxContacts * kFingerLength)];
    size_t count = gLastContactCount;

    if (count > 0) {
        SendFrame(frame, BuildFrame(frame, gLastContacts, count, kStateStop, true));
        SendFrame(frame, BuildFrame(frame, gLastContacts, count, kStateInactive, false));
    }
    SendFrame(frame, BuildFrame(frame, NULL, 0, kStateInactive, false));

    gLastContactCount = 0;

    gGestureInFlight = false;
}
