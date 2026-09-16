//
//  vhid.c — publish a virtual HID digitizer and see whether macOS claims it.
//
//  This is E1/E2 of the native-touch spike. macOS 27 delivers native touch only from
//  devices the AppleMultitouch driver binds to; Sidecar gets there by publishing a
//  virtual HID device. This tool publishes candidate devices so we can find out which
//  shape, if any, gets claimed.
//
//  Modes:
//      vhid --dump-real <out.bin>      copy an attached digitizer's report descriptor
//      vhid --publish ...              publish a virtual device and optionally feed it
//
//  Publishing requires com.apple.developer.hid.virtual.device, which AMFI treats as
//  restricted — without amfi_get_out_of_my_way=1 the process is killed before main().
//
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void SetNum(CFMutableDictionaryRef d, const char *k, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    CFDictionarySetValue(d, key, n);
    CFRelease(n); CFRelease(key);
}

static void SetData(CFMutableDictionaryRef d, const char *k, const uint8_t *bytes, size_t len) {
    CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    CFDataRef val = CFDataCreate(NULL, bytes, (CFIndex)len);
    CFDictionarySetValue(d, key, val);
    CFRelease(key); CFRelease(val);
}

static void SetBool(CFMutableDictionaryRef d, const char *k, bool v) {
    CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    CFDictionarySetValue(d, key, v ? kCFBooleanTrue : kCFBooleanFalse);
    CFRelease(key);
}

/**
 The surface geometry an AppleMultitouchDevice carries when it works.

 Our claimed device has none of this, which is the leading explanation for why it is
 adopted and then emits nothing: there is no surface to map a contact onto. The values
 and the opaque blobs are copied from the built-in trackpad of the machine the spike
 runs on — a guess in their particulars, but the right *shape*, which is what is being
 tested. Family ID is separate (--family): claiming one commits to that family's frame
 format, which is a bigger promise than the rest of these.
 */
static void AddSensorGeometry(CFMutableDictionaryRef props) {
    static const uint8_t surfaceDescriptor[] = {
        0x79, 0x2e, 0x00, 0x00, 0x6c, 0x1f, 0x00, 0x00,
        0x3a, 0xeb, 0x63, 0xff, 0x9b, 0x16, 0xbe, 0x1b,
    };
    static const uint8_t regionDescriptor[] = {
        0x02, 0x01, 0x00, 0x10, 0x01, 0x00, 0x18, 0x00,
        0x02, 0x10, 0x02, 0x01, 0x0b, 0x02, 0x00,
    };
    static const uint8_t regionParam[] = { 0x00, 0x00, 0x03, 0x00, 0x00, 0x02 };

    SetNum(props, "Sensor Surface Width", 11897);
    SetNum(props, "Sensor Surface Height", 8044);
    SetNum(props, "Sensor Rows", 18);
    SetNum(props, "Sensor Columns", 24);
    SetData(props, "Sensor Surface Descriptor", surfaceDescriptor, sizeof(surfaceDescriptor));
    SetData(props, "Sensor Region Descriptor", regionDescriptor, sizeof(regionDescriptor));
    SetData(props, "Sensor Region Param", regionParam, sizeof(regionParam));
    SetNum(props, "VersionNumber", 2357);
    SetNum(props, "bcdVersion", 1328);
    SetBool(props, "MTHIDDevice", true);
    SetBool(props, "HSTouchHIDService", true);
}

static void SetStr(CFMutableDictionaryRef d, const char *k, const char *v) {
    CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    CFStringRef val = CFStringCreateWithCString(NULL, v, kCFStringEncodingUTF8);
    CFDictionarySetValue(d, key, val);
    CFRelease(key); CFRelease(val);
}

#pragma mark - Reading a real panel's descriptor

static int DumpRealDescriptor(const char *outPath) {
    // Enumerating real devices is *listening* to input, which Input Monitoring gates.
    // Without it the device list comes back empty — which reads exactly like "nothing is
    // plugged in", and the two must not be confused.
    IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    if (access != kIOHIDAccessTypeGranted) {
        printf("Input Monitoring is %s for this process.\n",
               access == kIOHIDAccessTypeDenied ? "DENIED" : "not granted");
        printf("Requesting it now — approve the prompt, then run this again.\n");
        printf("(System Settings > Privacy & Security > Input Monitoring, for the app you\n");
        printf(" launched this from, usually Terminal.)\n");
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        return 3;
    }

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!mgr) { fprintf(stderr, "IOHIDManagerCreate failed\n"); return 1; }

    // Digitizer page, any of the three usages Touch Up itself matches.
    CFMutableArrayRef matches = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    const int usages[] = { 0x04 /* TouchScreen */, 0x05 /* TouchPad */, 0x01 /* Digitizer */ };
    for (size_t i = 0; i < sizeof(usages) / sizeof(usages[0]); i++) {
        CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        SetNum(m, "DeviceUsagePage", 0x0D);
        SetNum(m, "DeviceUsage", usages[i]);
        CFArrayAppendValue(matches, m);
        CFRelease(m);
    }
    IOHIDManagerSetDeviceMatchingMultiple(mgr, matches);
    CFRelease(matches);

    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef devices = IOHIDManagerCopyDevices(mgr);
    if (!devices || CFSetGetCount(devices) == 0) {
        printf("no digitizer found, and Input Monitoring IS granted — so nothing is plugged in.\n");
        printf("B4 (cloned real descriptor) will be skipped\n");
        if (devices) CFRelease(devices);
        return 2;
    }

    CFIndex count = CFSetGetCount(devices);
    const void **list = calloc((size_t)count, sizeof(void *));
    CFSetGetValues(devices, list);

    int status = 2;
    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef dev = (IOHIDDeviceRef)list[i];
        CFTypeRef desc = IOHIDDeviceGetProperty(dev, CFSTR("ReportDescriptor"));
        CFTypeRef product = IOHIDDeviceGetProperty(dev, CFSTR("Product"));
        CFTypeRef manufacturer = IOHIDDeviceGetProperty(dev, CFSTR("Manufacturer"));

        char productBuf[256] = "(unnamed)", manufacturerBuf[256] = "(none)";
        if (product && CFGetTypeID(product) == CFStringGetTypeID())
            CFStringGetCString(product, productBuf, sizeof(productBuf), kCFStringEncodingUTF8);
        if (manufacturer && CFGetTypeID(manufacturer) == CFStringGetTypeID())
            CFStringGetCString(manufacturer, manufacturerBuf, sizeof(manufacturerBuf), kCFStringEncodingUTF8);

        if (desc && CFGetTypeID(desc) == CFDataGetTypeID()) {
            CFIndex len = CFDataGetLength(desc);
            printf("real digitizer: \"%s\" by \"%s\", descriptor %ld bytes\n",
                   productBuf, manufacturerBuf, (long)len);
            FILE *f = fopen(outPath, "wb");
            if (f) {
                fwrite(CFDataGetBytePtr(desc), 1, (size_t)len, f);
                fclose(f);
                printf("wrote %s\n", outPath);
                status = 0;
            }
            break;
        }
        printf("digitizer \"%s\" exposes no ReportDescriptor property\n", productBuf);
    }

    free(list);
    CFRelease(devices);
    return status;
}

#pragma mark - Report packing (Sidecar's 81-byte layout)

// See TouchUpCore/TUCVirtualDigitizerDescriptor.h for the decode this mirrors.
#define kSidecarReportLength 81

typedef struct { uint8_t index; bool touching; uint16_t x, y; } Contact;

/**
 Where the pointer is, which is the one oracle that depends on nothing.

 A window can be the wrong size, behind something, or not focused, and a gesture
 recognizer then reports nothing whether or not events were delivered. The pointer is
 none of those things: if our reports are reaching the system as input of any kind, this
 moves. Reading it needs no permission.
 */
static CGPoint PointerLocation(void) {
    CGEventRef probe = CGEventCreate(NULL);
    CGPoint where = CGEventGetLocation(probe);
    CFRelease(probe);
    return where;
}

static void PackSidecarReport(uint8_t *out, const Contact *contacts, size_t count, uint16_t scanTime) {
    memset(out, 0, kSidecarReportLength);
    out[0] = 5;   // report ID

    if (count > 0) {
        const Contact *c = &contacts[0];
        out[1] = (uint8_t)((c->index & 0x1F) | (c->touching ? 0x40 : 0) | (c->touching ? 0x80 : 0));
        out[2] = (uint8_t)(c->x & 0xFF);  out[3] = (uint8_t)(c->x >> 8);
        out[4] = (uint8_t)(c->y & 0xFF);  out[5] = (uint8_t)(c->y >> 8);
    }
    if (count > 1) {
        const Contact *c = &contacts[1];
        out[6] = (uint8_t)((c->index & 0x0F) | (c->touching ? 0x10 : 0) | (c->touching ? 0x20 : 0));
        out[7] = (uint8_t)(c->x & 0xFF);  out[8] = (uint8_t)(c->x >> 8);
        out[9] = (uint8_t)(c->y & 0xFF);  out[10] = (uint8_t)(c->y >> 8);
    }

    out[11] = (uint8_t)count;                      // contact count
    out[12] = (uint8_t)(scanTime & 0xFF);          // relative scan time
    out[13] = (uint8_t)(scanTime >> 8);
    // bytes 14..80 stay zero: the 63-byte 0xFF1A blob and the trailing vendor fields.
}

#define kStandardReportLength 14

/**
 A report in the ordinary shape a Windows-style touchscreen sends.

 The point of contrast with Sidecar's layout: standard digitizer usages — tip switch,
 in-range, contact identifier, 16-bit X/Y, contact count — which is what the generic
 AppleUserHIDEventDriver knows how to parse.
 */
static void PackStandardReport(uint8_t *out, const Contact *contacts, size_t count) {
    memset(out, 0, kStandardReportLength);
    out[0] = 1;   // report ID

    for (size_t i = 0; i < 2; i++) {
        uint8_t *slot = out + 1 + (i * 6);
        if (i < count) {
            const Contact *c = &contacts[i];
            slot[0] = (uint8_t)((c->touching ? 0x01 : 0x00) | (c->touching ? 0x02 : 0x00));
            slot[1] = c->index;
            slot[2] = (uint8_t)(c->x & 0xFF);  slot[3] = (uint8_t)(c->x >> 8);
            slot[4] = (uint8_t)(c->y & 0xFF);  slot[5] = (uint8_t)(c->y >> 8);
        }
    }
    out[13] = (uint8_t)count;
}

static void FeedStandardSweep(IOHIDUserDeviceRef dev) {
    CGPoint pointerBefore = PointerLocation();
    uint8_t report[kStandardReportLength];
    const int frames = 60;
    printf("feeding %d frames of a two-contact sweep (standard digitizer layout)...\n", frames);
    fflush(stdout);

    for (int i = 0; i < frames; i++) {
        double t = (double)i / (double)(frames - 1);
        uint16_t x = (uint16_t)(0x1000 + t * 0x5000);
        uint16_t y = (uint16_t)(0x1000 + t * 0x4000);
        Contact contacts[2] = {
            { .index = 1, .touching = true, .x = x, .y = y },
            { .index = 2, .touching = true, .x = (uint16_t)(x + 0x0800), .y = y },
        };
        PackStandardReport(report, contacts, 2);
        IOReturn r = IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(),
                                                             report, sizeof(report));
        if (r != kIOReturnSuccess && i == 0) printf("  HandleReport returned 0x%08x\n", r);
        usleep(16000);
    }

    PackStandardReport(report, NULL, 0);
    IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), report, sizeof(report));

    CGPoint pointerAfter = PointerLocation();
    printf("sweep done; pointer %.0f,%.0f -> %.0f,%.0f  POINTER %s\n",
           pointerBefore.x, pointerBefore.y, pointerAfter.x, pointerAfter.y,
           (pointerBefore.x != pointerAfter.x || pointerBefore.y != pointerAfter.y)
               ? "MOVED — the system is acting on our reports"
               : "did not move");
    fflush(stdout);
}

static void FeedSidecarSweep(IOHIDUserDeviceRef dev) {
    CGPoint pointerBefore = PointerLocation();
    uint8_t report[kSidecarReportLength];
    const int frames = 60;
    printf("feeding %d frames of a two-contact sweep...\n", frames);
    fflush(stdout);

    for (int i = 0; i < frames; i++) {
        double t = (double)i / (double)(frames - 1);
        uint16_t x = (uint16_t)(0x1000 + t * 0x5000);
        uint16_t y = (uint16_t)(0x1000 + t * 0x4000);
        Contact contacts[2] = {
            { .index = 1, .touching = true, .x = x, .y = y },
            { .index = 2, .touching = true, .x = (uint16_t)(x + 0x0800), .y = y },
        };
        PackSidecarReport(report, contacts, 2, (uint16_t)(i * 100));
        IOReturn r = IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(),
                                                             report, sizeof(report));
        if (r != kIOReturnSuccess && i == 0) printf("  HandleReport returned 0x%08x\n", r);
        usleep(16000);   // ~60 Hz
    }

    // Lift: contact count zero, nothing touching.
    PackSidecarReport(report, NULL, 0, (uint16_t)(frames * 100));
    IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), report, sizeof(report));

    CGPoint pointerAfter = PointerLocation();
    printf("sweep done; pointer %.0f,%.0f -> %.0f,%.0f  POINTER %s\n",
           pointerBefore.x, pointerBefore.y, pointerAfter.x, pointerAfter.y,
           (pointerBefore.x != pointerAfter.x || pointerBefore.y != pointerAfter.y)
               ? "MOVED — the system is acting on our reports"
               : "did not move");
    fflush(stdout);
}

#pragma mark - Publishing

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "--dump-real") == 0) {
        return DumpRealDescriptor(argv[2]);
    }

    const char *descPath = NULL, *manufacturer = "Touch Up", *layout = "auto";
    int usagePage = 0x0D, usage = 0x04, hold = 25, family = 0;
    bool mtProps = false, feed = false, geometry = false;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--desc")         && i + 1 < argc) descPath     = argv[++i];
        else if (!strcmp(argv[i], "--usage-page")   && i + 1 < argc) usagePage    = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--usage")        && i + 1 < argc) usage        = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--manufacturer") && i + 1 < argc) manufacturer = argv[++i];
        else if (!strcmp(argv[i], "--hold")         && i + 1 < argc) hold         = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--family")        && i + 1 < argc) family       = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mt-props"))                      mtProps      = true;
        else if (!strcmp(argv[i], "--geometry"))                      geometry     = true;
        else if (!strcmp(argv[i], "--layout")        && i + 1 < argc) layout       = argv[++i];
        else if (!strcmp(argv[i], "--feed"))                          feed         = true;
    }
    if (!descPath) {
        fprintf(stderr,
            "usage: %s --desc <file> [--usage-page N] [--usage N] [--manufacturer S]\n"
            "          [--mt-props] [--geometry] [--family N] [--layout standard|sidecar]\n"
            "          [--feed] [--hold seconds]\n"
            "       %s --dump-real <out.bin>\n", argv[0], argv[0]);
        return 2;
    }

    FILE *f = fopen(descPath, "rb");
    if (!f) { perror(descPath); return 2; }
    static uint8_t desc[4096];
    size_t descLen = fread(desc, 1, sizeof(desc), f);
    fclose(f);

    CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef descData = CFDataCreate(NULL, desc, (CFIndex)descLen);
    CFDictionarySetValue(props, CFSTR("ReportDescriptor"), descData);
    SetNum(props, "PrimaryUsagePage", usagePage);
    SetNum(props, "PrimaryUsage", usage);
    SetNum(props, "VendorID", 0x1234);
    SetNum(props, "ProductID", 0x5678);
    SetStr(props, "Manufacturer", manufacturer);
    SetStr(props, "Product", "Touch Up Virtual Digitizer");
    SetStr(props, "Transport", "USB");
    // The guard Touch Up itself would use to avoid re-adopting its own twin.
    SetStr(props, "SerialNumber", "TouchUp-Virtual-0001");

    if (mtProps) {
        // MTUserDevice carries no DefaultMultitouchProperties, so a device matching it
        // has to bring the parser properties itself.
        SetNum(props, "parser-type", 1);
        SetNum(props, "parser-options", 16);
        CFDictionarySetValue(props, CFSTR("HIDServiceSupport"), kCFBooleanTrue);
    }

    if (geometry) AddSensorGeometry(props);
    if (family)   SetNum(props, "Family ID", family);

    printf("publishing: descriptor %zu bytes, usage %#x/%#x, manufacturer \"%s\"%s%s%s\n",
           descLen, usagePage, usage, manufacturer,
           mtProps ? ", +mt-props" : "", geometry ? ", +geometry" : "", family ? ", +family" : "");
    fflush(stdout);

    IOHIDUserDeviceRef dev = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, props, 0);
    if (!dev) {
        printf("RESULT: create returned NULL — the kernel refused the device\n");
        return 1;
    }
    dispatch_queue_t queue = dispatch_queue_create("de.schafe.touchup.vhid", DISPATCH_QUEUE_SERIAL);
    IOHIDUserDeviceSetDispatchQueue(dev, queue);
    IOHIDUserDeviceActivate(dev);

    printf("RESULT: created and activated; holding %d seconds\n", hold);
    fflush(stdout);

    // Give the driver matching a moment before anything inspects the registry.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.0, false);

    if (feed) {
        if (!strcmp(layout, "standard")) {
            FeedStandardSweep(dev);
        } else if (!strcmp(layout, "sidecar") || (usagePage == 0x0D && descLen == 256)) {
            FeedSidecarSweep(dev);
        } else {
            printf("no known report layout for this descriptor; publishing only\n");
        }
    }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, (CFTimeInterval)hold, false);

    IOHIDUserDeviceCancel(dev);
    printf("retired\n");
    return 0;
}
