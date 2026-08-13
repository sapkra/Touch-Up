//
//  HIDInterpreter.c
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#include "HIDInterpreter.h"
#include "TUCTouchInputManager-C.h"

#include <mach/mach_port.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>

#include <CoreGraphics/CoreGraphics.h>

#include <stdarg.h>

#pragma mark - Per-Device State

#define kMaxTouchscreens 4

typedef struct {
    IOHIDDeviceRef          device;     // unique identity of this HID interface
    uint32_t                locationID; // shared across interfaces of the same USB device
    CFIndex                 contactCollectionCount; // how many real multitouch contacts this interface reports
    Boolean                 isActive;
    Boolean                 seized;     // whether we hold an exclusive (seized) open on this device

    IOHIDQueueRef           queue;
    Boolean                 areElementRefsSet;
    
    IOHIDElementRef         applicationCollectionElement;
    IOHIDElementRef         scanTimeElement;
    CFMutableArrayRef       touchCollectionElements;
    
    /**
     stores values for the touch collections: cookie -> latest value
     in hybrid mode (especially if order of touches moves) this data has to be set to last state per collection element receiving touches now
     */
    CFMutableDictionaryRef  storedInputValues;
    
    CFMutableArrayRef       contactIdentifiers;
    
    CFIndex                 contactCount;
    CFIndex                 hybridOffset;
    Boolean                 touchscreenUsesHybridMode;

    /// Set once we have complained about this interface reporting unusable coordinates, so the
    /// warning does not repeat at report rate and flood the diagnostics transcript.
    Boolean                 didWarnAboutMissingAxes;

    /// Whether this interface is allowed to move the pointer. Touches are always read and
    /// published (so the device is visible and testable); this gates only the mouse events.
    Boolean                 drivesPointer;

    /// What the descriptor called this interface: `kHIDUsage_Dig_TouchScreen`, `…_TouchPad`, or a
    /// bare `…_Digitizer`. Kept rather than only the boolean it feeds, because "why is this device
    /// inert?" is the most common question a bug report asks, and the answer is almost always this.
    uint32_t                primaryUsage;
} HIDDeviceState;

static HIDDeviceState gDevices[kMaxTouchscreens];
static int gDeviceCount = 0;

#pragma mark - Global variables

static void* gTouchManager;

static CFRunLoopRef gRunLoopRef;

static IOHIDManagerRef gHidManager;

// When true, accepted touch interfaces are opened exclusively (seized) so macOS and other
// apps no longer receive their events — Touch Up becomes the sole handler. Opt-in.
static Boolean gSeizeTouchDevices = false;


#pragma mark - Diagnostics Transcript

/**
 A bounded in-memory transcript of what the interpreter discovers about the connected HID
 devices.

 All of this was always produced — as `printf` to stdout — but an app launched from Finder has
 no stdout anybody can read, so in practice the information never reached the one person who
 needed it. That is why almost every device-specific report on the tracker stalls on "how can
 I help you debug this?". Capturing the same output makes it copyable from the settings window.

 Written only from the HID callbacks, which all run on the main run loop, so no locking.
 */

#define kDiagnosticsCapacity (128 * 1024)

static char    gDiagnostics[kDiagnosticsCapacity];
static size_t  gDiagnosticsLength = 0;
static Boolean gDiagnosticsDidTruncate = false;

static void DiagLog(const char *format, ...) __printflike(1, 2);

static void DiagLog(const char *format, ...) {
    va_list args;
    va_start(args, format);

    // Still mirrored to stdout, which is worth having when running from Xcode.
    va_list stdoutArgs;
    va_copy(stdoutArgs, args);
    vprintf(format, stdoutArgs);
    va_end(stdoutArgs);

    size_t remaining = kDiagnosticsCapacity - gDiagnosticsLength;
    if (remaining > 1) {
        int written = vsnprintf(gDiagnostics + gDiagnosticsLength, remaining, format, args);
        if (written < 0) {
            // On failure the written contents are undefined; keep the transcript a valid string.
            gDiagnostics[gDiagnosticsLength] = '\0';
            gDiagnosticsDidTruncate = true;
        } else if ((size_t)written >= remaining) {
            // vsnprintf reports what it *would* have written; the buffer is now full.
            gDiagnosticsLength = kDiagnosticsCapacity - 1;
            gDiagnosticsDidTruncate = true;
        } else {
            gDiagnosticsLength += (size_t)written;
        }
    } else {
        gDiagnosticsDidTruncate = true;
    }

    va_end(args);
}

const char *HIDDiagnostics(void) {
    return gDiagnostics;
}

bool HIDDiagnosticsDidTruncate(void) {
    return gDiagnosticsDidTruncate;
}

void ResetHIDDiagnostics(void) {
    gDiagnostics[0] = '\0';
    gDiagnosticsLength = 0;
    gDiagnosticsDidTruncate = false;
}

void LogToHIDDiagnostics(const char *message) {
    if (message) {
        DiagLog("%s\n", message);
    }
}


/// Copies a string device property, or "-" when the device does not publish it.
static void CopyDeviceStringProperty(IOHIDDeviceRef dev, CFStringRef key, char *out, size_t outSize) {
    out[0] = '\0';

    CFTypeRef value = IOHIDDeviceGetProperty(dev, key);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)value, out, (CFIndex)outSize, kCFStringEncodingUTF8);
    }

    if (out[0] == '\0') {
        snprintf(out, outSize, "-");
    }
}


/// Formats a numeric device property as hex, or "-" when the device does not publish it.
static void CopyDeviceHexProperty(IOHIDDeviceRef dev, CFStringRef key, char *out, size_t outSize) {
    CFTypeRef value = IOHIDDeviceGetProperty(dev, key);
    long number = 0;

    if (value && CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)value, kCFNumberLongType, &number)) {
        snprintf(out, outSize, "%#04lx", number);
    } else {
        snprintf(out, outSize, "-");
    }
}


/**
 Records what this HID interface says about itself. The usage page/usage pair is the most
 valuable line: a panel that reports usage 0x05 (TouchPad) rather than 0x04 (TouchScreen) is
 the one macOS drives as a trackpad, and knowing which of the two a device claims to be
 explains most "it behaves like a giant trackpad" reports without any guesswork.
 */
static void DiagLogDeviceIdentity(IOHIDDeviceRef dev, uint32_t locationID, CFIndex contactCollections) {
    char product[128], manufacturer[128], transport[64], serial[128];
    char vendorID[16], productID[16], usagePage[16], usage[16];

    CopyDeviceStringProperty(dev, CFSTR(kIOHIDProductKey),      product,      sizeof(product));
    CopyDeviceStringProperty(dev, CFSTR(kIOHIDManufacturerKey), manufacturer, sizeof(manufacturer));
    CopyDeviceStringProperty(dev, CFSTR(kIOHIDTransportKey),    transport,    sizeof(transport));
    CopyDeviceStringProperty(dev, CFSTR(kIOHIDSerialNumberKey), serial,       sizeof(serial));

    CopyDeviceHexProperty(dev, CFSTR(kIOHIDVendorIDKey),          vendorID,  sizeof(vendorID));
    CopyDeviceHexProperty(dev, CFSTR(kIOHIDProductIDKey),         productID, sizeof(productID));
    CopyDeviceHexProperty(dev, CFSTR(kIOHIDPrimaryUsagePageKey),  usagePage, sizeof(usagePage));
    CopyDeviceHexProperty(dev, CFSTR(kIOHIDPrimaryUsageKey),      usage,     sizeof(usage));

    DiagLog("\n===== HID interface at locationID %#010x =====\n", locationID);
    DiagLog("  product:    %s\n", product);
    DiagLog("  vendor:     %s (%s), product %s\n", manufacturer, vendorID, productID);
    DiagLog("  serial:     %s\n", serial);
    DiagLog("  transport:  %s\n", transport);
    DiagLog("  usage:      page %s, usage %s\n", usagePage, usage);
    DiagLog("  contact collections: %ld\n", contactCollections);

    if (contactCollections == 0) {
        DiagLog("  note: no collection here reports a ContactIdentifier, so this interface is\n"
                "        single-contact at best. Touch extraction is still attempted; see the\n"
                "        element tree below for whether any usable collection was found.\n");
    }
}


#pragma mark - Device State Management


// State is keyed by the IOHIDDeviceRef, not the locationID: a combo digitizer presents
// several HID interfaces that all share one locationID, so the device ref is the only
// reliable per-interface identity.
HIDDeviceState* DeviceStateForRef(IOHIDDeviceRef device) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].device == device) {
            return &gDevices[i];
        }
    }
    return NULL;
}

// Returns the single interface we've accepted as *the* touchscreen for this locationID
// (the one with the most contact collections), or NULL if none is registered yet.
HIDDeviceState* RegisteredDeviceForLocationID(uint32_t locationID) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].locationID == locationID) {
            return &gDevices[i];
        }
    }
    return NULL;
}


HIDDeviceState* AllocateDeviceState(IOHIDDeviceRef device, uint32_t locationID) {
    if (gDeviceCount >= kMaxTouchscreens) {
        DiagLog("Maximum number of touchscreens (%d) reached.\n", kMaxTouchscreens);
        return NULL;
    }

    HIDDeviceState *state = &gDevices[gDeviceCount];
    memset(state, 0, sizeof(HIDDeviceState));

    state->device = device;
    state->locationID = locationID;
    state->isActive = TRUE;
    state->contactCount = 1;
    state->touchCollectionElements = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    state->contactIdentifiers = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    state->storedInputValues = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    
    gDeviceCount++;
    return state;
}


void DeallocateDeviceState(IOHIDDeviceRef device) {
    int index = -1;
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive && gDevices[i].device == device) {
            index = i;
            break;
        }
    }
    if (index < 0) return;
    
    HIDDeviceState *state = &gDevices[index];

    if (state->seized) {
        IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
        state->seized = false;
    }

    if (state->queue) {
        IOHIDQueueStop(state->queue);
        CFRelease(state->queue);
    }
    if (state->touchCollectionElements) CFRelease(state->touchCollectionElements);
    if (state->contactIdentifiers) CFRelease(state->contactIdentifiers);
    if (state->storedInputValues) CFRelease(state->storedInputValues);
    
    // move last element into gap to keep array compact
    gDeviceCount--;
    if (index < gDeviceCount) {
        gDevices[index] = gDevices[gDeviceCount];
    }
    memset(&gDevices[gDeviceCount], 0, sizeof(HIDDeviceState));
}


#pragma mark General Debug Utilities




void PrintAddress(UInt8 *ptr, UInt64 length) {
    for (int i=0; i<length; i++) {
        DiagLog("%02x ", ptr[i]);
        if ((i+1)%8 == 0) DiagLog("  ");
        if ((i+1)%32 == 0) DiagLog("\n");
    }
    DiagLog("\n");
}


void PrintInput(IOHIDValueRef inHIDValue) {
    IOHIDElementRef elem = IOHIDValueGetElement(inHIDValue);
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    CFIndex value = IOHIDValueGetIntegerValue(inHIDValue);
    
    IOHIDElementCookie cookie = IOHIDElementGetCookie(elem);
    
    char pageDescr[6]  = "(---)";
    char usageDescr[10] = "(-------)";
    
    if (page == kHIDPage_GenericDesktop) {
        strcpy(pageDescr, "(GD) ");
        if (usage == kHIDUsage_GD_X) {
            strcpy(usageDescr, "(X)      ");
        } else if (usage == kHIDUsage_GD_Y) {
            strcpy(usageDescr, "(Y)      ");
        }
        
    } else if (page == kHIDPage_Digitizer) {
        strcpy(pageDescr, "(Dig)");
        
        if (usage == kHIDUsage_Dig_TipSwitch) {
            strcpy(usageDescr, "(Tip)    ");
        } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
            strcpy(usageDescr, "(Cont ID)");
        } else if (usage == kHIDUsage_Dig_ContactCount) {
            strcpy(usageDescr, "(ContCnt)");
        } else if (usage == kHIDUsage_Dig_TouchValid) {
            strcpy(usageDescr, "(IsValid)");
        } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
            strcpy(usageDescr, "(ScnTime)");
        } else if (usage == kHIDUsage_Dig_Width) {
            strcpy(usageDescr, "(Width)  ");
        } else if (usage == kHIDUsage_Dig_Height) {
            strcpy(usageDescr, "(Height) ");
        } else if (usage == kHIDUsage_Dig_Azimuth) {
            strcpy(usageDescr, "(Azimuth)");
        }
    }
    
    CFIndex  lMin = IOHIDElementGetLogicalMin(elem);
    CFIndex lMax = IOHIDElementGetLogicalMax(elem);
    
    DiagLog("%u\t| %#02lx %s\t| %#02lx %s\t|%8ld\t(%ld-%ld)\n", cookie, page, pageDescr, usage, usageDescr, value, lMin, lMax);
}





#pragma mark - Storing Values


int64_t StorageKeyForElement(IOHIDElementRef element) {
    return IOHIDElementGetCookie(element);
}



CFIndex ValueOfElement(HIDDeviceState *device, IOHIDElementRef element) {
    
    if (!element) {
        return kCFNotFound;
    }
    
    int64_t hash = StorageKeyForElement(element);
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &hash);
    
    if (CFDictionaryContainsKey(device->storedInputValues, key)) {
        CFIndex value;
        CFNumberRef num = CFDictionaryGetValue(device->storedInputValues, key);
        CFNumberGetValue(num, kCFNumberCFIndexType, &value);
        CFRelease(key);
        return value;
        
    }
    CFRelease(key);
    return kCFNotFound;
    
}



void StoreInputValue(HIDDeviceState *device, IOHIDValueRef hidValue) {
    
    CFIndex value = IOHIDValueGetIntegerValue(hidValue);
    IOHIDElementRef elem = IOHIDValueGetElement(hidValue);
    
    CFIndex keyValue = StorageKeyForElement(elem);
    
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyValue);
    
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &value);
    
    CFDictionarySetValue(device->storedInputValues, key, num);
    
    CFRelease(num);
    CFRelease(key);
    
    
    // special case: contact count could be zero in hybrid mode
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    
    if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
        // hybrid mode can only exist if the old value is larger than the number of collections that can be communicated at once
        CFIndex numCollections = CFArrayGetCount(device->touchCollectionElements);
        
        if (device->contactCount > numCollections && value == 0 && device->hybridOffset > 0) {
            device->touchscreenUsesHybridMode = TRUE;
            
        } else {
            device->contactCount = value;
            device->hybridOffset = 0;
        }
    }
}




/**
 Fallback for descriptors that carry their touch data directly in the application collection
 instead of wrapping it in a logical collection.

 Multitouch descriptors give each simultaneous contact its own logical collection, and those
 are what the loop below harvests. A single-contact digitizer has no reason to introduce that
 grouping and frequently does not, leaving X/Y/TipSwitch as direct children of the application
 collection — in which case nothing is harvested at all, and the device connects, reports
 itself present, and then silently never delivers a touch for as long as it stays plugged in.

 `DispatchTouchDataForCollection` reads a collection's direct children, so the application
 collection can simply stand in as the one and only contact.

 TipSwitch is required rather than assumed: without it there is no signal for the finger
 leaving the glass, and a touch that can begin but never end is worse than none at all.
 */
static void AdoptApplicationCollectionIfSingleContact(HIDDeviceState *device,
                                                      IOHIDElementRef applicationCollection,
                                                      Boolean printTree) {
    if (CFArrayGetCount(device->touchCollectionElements) > 0) {
        return;
    }

    Boolean hasX = false, hasY = false, hasTipSwitch = false;

    CFArrayRef children = IOHIDElementGetChildren(applicationCollection);
    for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);

        if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_X) hasX = true;
        if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Y) hasY = true;
        if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_TipSwitch) hasTipSwitch = true;
    }

    if (hasX && hasY && hasTipSwitch) {
        CFArrayAppendValue(device->touchCollectionElements, applicationCollection);
        DiagLog("Treating the application collection of %#010x as a single contact: it carries\n"
                "  X, Y and TipSwitch directly, with no logical collection to group them.\n",
                device->locationID);

    } else if (printTree) {
        DiagLog("No logical collection, and the application collection cannot stand in for one\n"
                "  (X:%s Y:%s TipSwitch:%s).\n",
                hasX ? "yes" : "no", hasY ? "yes" : "no", hasTipSwitch ? "yes" : "no");
    }
}


/**
 We need to inspect the HID tree as a whole once to see which elements are grouped into logical groups of touch data.
 Just pass in any element of the tree, the function will walk up the tree, search for the logical groups and rememeber them in the global variables.
 */
void IdentifyElements(HIDDeviceState *device, IOHIDElementRef anyElement, Boolean printTree) {
    
    IOHIDElementRef applicationCollection = anyElement;
    IOHIDElementType type = kIOHIDElementTypeOutput;
    
    while (type != kIOHIDElementTypeCollection) {
        IOHIDElementRef next = IOHIDElementGetParent(applicationCollection);
        if (next) {
            applicationCollection = next;
            type = IOHIDElementGetType(applicationCollection);
        } else {
            break;
        }
    }
    device->applicationCollectionElement = applicationCollection;
    
    
    CFArrayRef children = IOHIDElementGetChildren(applicationCollection);
    CFIndex numChildren = CFArrayGetCount(children);
    
    if (printTree) {
        DiagLog("# parent (type %u) has %ld children:\n", type, numChildren);
    }
    
    
    for (CFIndex i=0; i<numChildren; i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        IOHIDElementType type =  IOHIDElementGetType(element);
        IOHIDElementCollectionType collectionType = IOHIDElementGetCollectionType(element);
        
        if (type == kIOHIDElementTypeCollection && collectionType == kIOHIDElementCollectionTypeLogical) {
            CFArrayAppendValue(device->touchCollectionElements, element);
            
            if (printTree) {
                DiagLog(" > Logical collection %ld\n", i);
                CFArrayRef grandchildren = IOHIDElementGetChildren(element);
                for( CFIndex j=0; j<CFArrayGetCount(grandchildren); j++) {
                    IOHIDElementRef gch = (IOHIDElementRef)CFArrayGetValueAtIndex(grandchildren, j);
                    CFIndex page = IOHIDElementGetUsagePage(gch);
                    CFIndex usage = IOHIDElementGetUsage(gch);
                    CFIndex cookie= IOHIDElementGetCookie(gch);
                    
                    DiagLog("    > %#02lx %#02lx  [%ld]\n", page, usage, cookie);
                }
            }
            
        } // logical collection
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
            if (printTree) {
                DiagLog(" > Contact Count\n");
            }
        }
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_RelativeScanTime) {
            device->scanTimeElement = element;
            if (printTree) {
                DiagLog(" > Scan Time\n");
            }
        }
        
        else {
            if (printTree) {
                DiagLog(" > %#02lx %#02lx\n", page, usage);
            }
        }
    }

    AdoptApplicationCollectionIfSingleContact(device, applicationCollection, printTree);

    if (CFArrayGetCount(device->touchCollectionElements) == 0) {
        DiagLog("WARNING: %#010x exposes no collection that touch data can be read from.\n"
                "         It will report itself connected and then never deliver a touch.\n"
                "         Please include this element tree in a bug report.\n",
                device->locationID);
    }
}









#pragma mark - Propagate Touch Data to next layer


void PrintTouchCollection(HIDDeviceState *device, IOHIDElementRef collection) {
    CFArrayRef children = IOHIDElementGetChildren(collection);
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex cookie = IOHIDElementGetCookie(element);
        CFIndex value = ValueOfElement(device, element);
        
        char pageDescr[6]  = "(---)";
        char usageDescr[10] = "(-------)";
        
        if (page == kHIDPage_GenericDesktop) {
            strcpy(pageDescr, "(GD) ");
            if (usage == kHIDUsage_GD_X) {
                strcpy(usageDescr, "(X)      ");
            } else if (usage == kHIDUsage_GD_Y) {
                strcpy(usageDescr, "(Y)      ");
            }
            
        } else if (page == kHIDPage_Digitizer) {
            strcpy(pageDescr, "(Dig)");
            
            if (usage == kHIDUsage_Dig_TipSwitch) {
                strcpy(usageDescr, "(Tip)    ");
            } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
                strcpy(usageDescr, "(Cont ID)");
            } else if (usage == kHIDUsage_Dig_ContactCount) {
                strcpy(usageDescr, "(ContCnt)");
            } else if (usage == kHIDUsage_Dig_TouchValid) {
                strcpy(usageDescr, "(IsValid)");
            } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
                strcpy(usageDescr, "(ScnTime)");
            } else if (usage == kHIDUsage_Dig_Width) {
                strcpy(usageDescr, "(Width)  ");
            } else if (usage == kHIDUsage_Dig_Height) {
                strcpy(usageDescr, "(Height) ");
            } else if (usage == kHIDUsage_Dig_Azimuth) {
                strcpy(usageDescr, "(Azimuth)");
            }
        }
        
        
        
        DiagLog("[%ld]\t%#02lx\t%#02lx %s\t %8ld\n", (long)cookie, page, usage, usageDescr,  value);
    }
    DiagLog("\n");
}


/**
 Normalises an axis value against its element's logical range, into 0...1.

 Returns false when the descriptor cannot support the conversion, i.e. when it declares an
 empty logical range. Dividing by that range regardless yielded infinity or NaN, which then
 travelled all the way to a synthesized mouse event.
 */
static Boolean NormalizedAxisValue(IOHIDElementRef element, CFIndex value, CGFloat *outNormalized) {
    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);

    if (max <= min) {
        return false;
    }

    // Note there is deliberately no `+ min` here. It used to be added back after dividing,
    // which is a no-op for the overwhelmingly common min == 0 and an offset for everything
    // else, pushing the result outside 0...1 on any device with a non-zero logical minimum.
    *outNormalized = ((CGFloat)value - min) / (max - min);
    return true;
}


/**
 Dispatches touch data for the given collection, but only if all values needed were received
 */

void DispatchTouchDataForCollection(HIDDeviceState *device, IOHIDElementRef collection) {

    CFArrayRef children = IOHIDElementGetChildren(collection);

    CGFloat x = -1;
    CGFloat y = -1;
    Boolean hasX = false;
    Boolean hasY = false;

    CFIndex contactID = 0;
    CFIndex tipSwitch = 0;
    CFIndex isValid = 0;

    CFIndex width   = kCFNotFound;
    CFIndex height  = kCFNotFound;
    CFIndex azimuth = kCFNotFound;

    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);

        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex value = ValueOfElement(device, element);

        if (value != kCFNotFound) {
            if (page == kHIDPage_GenericDesktop) {
                if (usage == kHIDUsage_GD_X) {
                    hasX = NormalizedAxisValue(element, value, &x);
                }

                else if (usage == kHIDUsage_GD_Y) {
                    hasY = NormalizedAxisValue(element, value, &y);
                }
            } //kHIDPage_GenericDesktop

            else if (page == kHIDPage_Digitizer) {
                if (usage == kHIDUsage_Dig_ContactIdentifier) {
                    contactID = value;
                } else if (usage == kHIDUsage_Dig_TipSwitch) {
                    tipSwitch = value;
                } else if (usage == kHIDUsage_Dig_TouchValid) {
                    isValid = value;
                } else if (usage == kHIDUsage_Dig_Width) {
                    width = value;
                } else if (usage == kHIDUsage_Dig_Height) {
                    height = value;
                } else if (usage == kHIDUsage_Dig_Azimuth) {
                    azimuth = value;
                }
            } // kHIDPage_Digitizer
        }
    }
    // Honour what this function has always claimed to do. Without the check, a collection
    // carrying no usable X/Y still dispatched, at the sentinel (-1, -1) — and the letterbox
    // correction downstream clamps to 0...1, turning that into a perfectly plausible (0, 0).
    // The result is a screen whose every touch lands in the top-left corner with nothing
    // anywhere to say why, which is what "clicks only register at 0,0" is.
    //
    // `ignoreOriginTouches` cannot cover this: it compares the raw digitizer point against
    // zero, before the clamp is what produces the zero.
    if (!hasX || !hasY) {
        if (!device->didWarnAboutMissingAxes) {
            device->didWarnAboutMissingAxes = true;
            DiagLog("WARNING: a touch collection of %#010x reported no usable %s%s%s.\n"
                    "         Its reports are being dropped rather than sent to the corner.\n"
                    "         Either the descriptor omits the axis or it declares an empty\n"
                    "         logical range (min >= max).\n",
                    device->locationID,
                    hasX ? "" : "X", (!hasX && !hasY) ? " or " : "", hasY ? "" : "Y");
        }
        return;
    }

    TouchInputManagerUpdateTouchPosition(gTouchManager, device->locationID, contactID, x, y, (int)tipSwitch, (int)isValid);
    
    //    if (width != kCFNotFound && height != kCFNotFound && azimuth != kCFNotFound) {
    //        TouchInputManagerUpdateTouchSize(gTouchManager, contactID, (CGFloat)width, (CGFloat)height, (CGFloat)azimuth);
    //    }
    
}



void DispatchTouches(HIDDeviceState *device) {
    
    CFIndex numCollections = CFArrayGetCount(device->touchCollectionElements);
    CFIndex remainingUpdates = device->contactCount - device->hybridOffset;
    
    CFIndex numUpdates = numCollections;
    if (remainingUpdates < numCollections) {
        numUpdates = remainingUpdates;
    }
    
    CFIndex numElementsToPost = CFArrayGetCount(device->touchCollectionElements);
    if (numUpdates < numElementsToPost)
        numElementsToPost = numUpdates;
    
    // update the touch data
    for (CFIndex i=0; i<numElementsToPost; i++) {
        IOHIDElementRef collection = (IOHIDElementRef)CFArrayGetValueAtIndex(device->touchCollectionElements, i);
        DispatchTouchDataForCollection(device, collection);
    }
    
    device->hybridOffset = device->hybridOffset + numUpdates;
    
    if (device->hybridOffset == device->contactCount) {
        device->hybridOffset = 0;
    }
    
    if (device->hybridOffset == 0) {
        TouchInputManagerDidProcessReport(gTouchManager, device->locationID);
    }
    
}



#pragma mark - Exclusive HID Usage (Seizing)

/*!
 Brings a device's exclusive-open state in line with gSeizeTouchDevices.
 Seizing routes the device's events to us alone (macOS stops receiving them); releasing returns it to shared use.
 Idempotent — only opens/closes when the state actually changes.
 */
static void ApplySeizeState(HIDDeviceState *state) {
    if (gSeizeTouchDevices && !state->seized) {
        IOReturn r = IOHIDDeviceOpen(state->device, kIOHIDOptionsTypeSeizeDevice);
        if (r == kIOReturnSuccess) {
            state->seized = true;
        } else {
            DiagLog("Failed to seize device 0x%08x (IOReturn 0x%08x)\n", state->locationID, r);
        }
    } else if (!gSeizeTouchDevices && state->seized) {
        IOHIDDeviceClose(state->device, kIOHIDOptionsTypeSeizeDevice);
        state->seized = false;
    }
}


/*!
 Opt-in exclusive access. When enabled, every accepted touch interface (current andfuture) is seized so macOS no longer receives its events.
 Applies immediately to all currently-connected touch devices; pen interfaces we never registered stay shared, so the pen keeps working through macOS.
 */
/*!
 Allows or forbids one interface to move the pointer. Touches keep being read and published
 either way, so a device can be watched in the test overlay before it is trusted with input.
 */
void SetTouchDeviceDrivesPointer(uint32_t locationID, bool drivesPointer) {
    HIDDeviceState *device = RegisteredDeviceForLocationID(locationID);
    if (!device) return;

    device->drivesPointer = drivesPointer;
    DiagLog("Interface %#010x %s drive the pointer\n",
            locationID, drivesPointer ? "may now" : "may no longer");
}


bool TouchDeviceDrivesPointer(uint32_t locationID) {
    HIDDeviceState *device = RegisteredDeviceForLocationID(locationID);
    return device ? device->drivesPointer : false;
}


uint32_t TouchDeviceHIDPrimaryUsage(uint32_t locationID) {
    HIDDeviceState *device = RegisteredDeviceForLocationID(locationID);
    return device ? device->primaryUsage : 0;
}


void SetTouchDevicesSeized(bool seize) {
    gSeizeTouchDevices = seize;
    for (int i = 0; i < gDeviceCount; i++) {
        if (gDevices[i].isActive) {
            ApplySeizeState(&gDevices[i]);
        }
    }
}



#pragma mark - Callbacks

/*!
 @param context void * pointer to your data, often a pointer to an object.
 @param result Completion result of desired operation.
 @param inSender Interface instance sending the completion routine.
 */

static void Handle_QueueValueAvailable(
    void * _Nullable        context,
    IOReturn                result,
    void * _Nullable        inSender
) {
    HIDDeviceState *device = DeviceStateForRef((IOHIDDeviceRef)context);
    if (!device) return;

    do {
        IOHIDValueRef valueRef = IOHIDQueueCopyNextValueWithTimeout((IOHIDQueueRef) inSender, 0.);
        if (!valueRef)  {
            // finished processing 1 report
            DispatchTouches(device);
            break;
        }
        // process the HID value reference
        StoreInputValue(device, valueRef);
        
        // Don't forget to release our HID value reference
        CFRelease(valueRef);
    } while (1) ;
}


static void Handle_InputValueCallback (
    void *          inContext,      // context from IOHIDManagerRegisterInputValueCallback
    IOReturn        inResult,       // completion result for the input value operation
    void *          inSender,       // the IOHIDManagerRef
    IOHIDValueRef   inIOHIDValueRef // the new element value
) {
    HIDDeviceState *device = DeviceStateForRef((IOHIDDeviceRef)inContext);
    if (!device) return;

    if(!device->areElementRefsSet) {
        IOHIDElementRef e = IOHIDValueGetElement(inIOHIDValueRef);
        IdentifyElements(device, e, TRUE);
        device->areElementRefsSet = TRUE;
    }
    
    //PrintInput(inIOHIDValueRef);
    IOHIDElementRef elem = IOHIDValueGetElement(inIOHIDValueRef);
    
    Boolean added = IOHIDQueueContainsElement(device->queue, elem);
    if(!added) {
        IOHIDQueueAddElement(device->queue, elem);
        StoreInputValue(device, inIOHIDValueRef);
    }
    
}








/**
 Counts the logical collections that contain a ContactIdentifier, i.e. the number of
 simultaneous touch contacts this HID interface can report. This is how we tell the real
 multitouch surface (several contacts) apart from a sibling interface that only exposes a
 single-pointer or pen path (one or zero contacts) under the same locationID.
 */
static CFIndex CountContactCollections(IOHIDDeviceRef dev) {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
    if (!elements) return 0;

    CFIndex contactCollections = 0;
    CFIndex count = CFArrayGetCount(elements);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        if (IOHIDElementGetType(el) != kIOHIDElementTypeCollection) continue;
        if (IOHIDElementGetCollectionType(el) != kIOHIDElementCollectionTypeLogical) continue;

        CFArrayRef kids = IOHIDElementGetChildren(el);
        for (CFIndex j = 0; j < CFArrayGetCount(kids); j++) {
            IOHIDElementRef kid = (IOHIDElementRef)CFArrayGetValueAtIndex(kids, j);
            if (IOHIDElementGetUsagePage(kid) == kHIDPage_Digitizer &&
                IOHIDElementGetUsage(kid) == kHIDUsage_Dig_ContactIdentifier) {
                contactCollections++;
                break;
            }
        }
    }
    CFRelease(elements);
    return contactCollections;
}



/**
 Devices we refuse to touch at all, however they describe themselves.

 Broadening the match set to include TouchPad brings Apple's own pointing devices into range,
 and a built-in trackpad that Touch Up starts driving — or worse, seizes — leaves the user with
 no pointer and no obvious way to undo it. Refusing them outright is deliberately stronger than
 defaulting them to off: there is no switch anywhere that can turn a trackpad into a
 touchscreen, so offering one would only be a way to break your Mac.

 The internal transports are excluded for the same reason. Nothing reachable over SPI or a
 FIFO is an external touch panel.
 */
static Boolean IsExcludedDevice(IOHIDDeviceRef dev) {
    enum { kAppleVendorID = 0x05AC };

    CFTypeRef vendor = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey));
    long vendorID = 0;
    if (vendor && CFGetTypeID(vendor) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)vendor, kCFNumberLongType, &vendorID)
        && vendorID == kAppleVendorID) {
        return true;
    }

    char transport[64];
    CopyDeviceStringProperty(dev, CFSTR(kIOHIDTransportKey), transport, sizeof(transport));
    if (strcmp(transport, "SPI") == 0 || strcmp(transport, "FIFO") == 0) {
        return true;
    }

    return false;
}


/**
 Whether a matched interface may drive the pointer as soon as it appears.

 Only a device that declares itself a TouchScreen does. Everything else is registered and
 listened to — so it shows up in the settings window and its touches can be watched in the
 test overlay — but posts no mouse events until the user says so. A device that lies about
 being a TouchPad is indistinguishable from one that really is a trackpad, and guessing wrong
 in that direction hijacks a working pointing device.
 */
/**
 What the interface calls itself, or 0 if it would not say.

 Split out from `ShouldDriveDeviceByDefault`, which read this and then threw everything but one
 comparison away. The distinction between a panel that declares itself a TouchScreen, one that
 claims to be a TouchPad, and one that only admits to being a Digitizer is the difference between
 a device that works on plugging in and one that sits there doing nothing until the user finds the
 switch — so it belongs in the diagnostics, and it lets a gesture be read differently on a device
 that may not be a screen at all.
 */
static uint32_t DevicePrimaryUsage(IOHIDDeviceRef dev) {
    CFTypeRef usage = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDPrimaryUsageKey));
    long primaryUsage = 0;

    if (usage && CFGetTypeID(usage) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)usage, kCFNumberLongType, &primaryUsage)) {
        return (uint32_t)primaryUsage;
    }

    return 0;
}


static Boolean ShouldDriveDeviceByDefault(IOHIDDeviceRef dev) {
    return DevicePrimaryUsage(dev) == kHIDUsage_Dig_TouchScreen;
}


// Allocates device state and wires up the queue + input callbacks for an interface we've
// decided to treat as the active touchscreen. The callback context is the device ref so
// callbacks resolve to the right per-interface state even when locationIDs collide.
static HIDDeviceState* RegisterTouchDevice(IOHIDDeviceRef dev, uint32_t locationID, CFIndex contactCount) {
    HIDDeviceState *device = AllocateDeviceState(dev, locationID);
    if (!device) return NULL;
    device->contactCollectionCount = contactCount;

    void *context = (void *)dev;

    IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, dev, 1000, kNilOptions);
    IOHIDQueueRegisterValueAvailableCallback(queue, Handle_QueueValueAvailable, context);
    IOHIDQueueStart(queue);
    device->queue = queue;
    IOHIDQueueScheduleWithRunLoop(queue, gRunLoopRef, kCFRunLoopCommonModes);

    IOHIDDeviceRegisterInputValueCallback(dev, Handle_InputValueCallback, context);

    ApplySeizeState(device);
    return device;
}


// this will be called when the HID Manager matches a new (hot plugged) HID device
static void Handle_DeviceMatchingCallback(
    void *          inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
    IOReturn        inResult,        // the result of the matching operation
    void *          inSender,        // the IOHIDManagerRef for the new device
    IOHIDDeviceRef  inIOHIDDeviceRef // the new HID device
) {
    // read the location ID for this device
    CFNumberRef locationRef = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDLocationIDKey));
    uint32_t locationID = 0;
    if (locationRef) {
        CFNumberGetValue(locationRef, kCFNumberSInt32Type, &locationID);
    }

    // A combo digitizer exposes several interfaces under one locationID. Keep only the one
    // that actually carries multitouch: the interface with the most contact collections.
    CFIndex contactCount = CountContactCollections(inIOHIDDeviceRef);
    HIDDeviceState *existing = RegisteredDeviceForLocationID(locationID);

    DiagLogDeviceIdentity(inIOHIDDeviceRef, locationID, contactCount);

    if (IsExcludedDevice(inIOHIDDeviceRef)) {
        DiagLog("  -> refused: an Apple or internally-connected pointing device is never a\n"
                "     touchscreen, and driving one would take over the pointer\n");
        return;
    }

    if (existing == NULL) {
        Boolean driveByDefault = ShouldDriveDeviceByDefault(inIOHIDDeviceRef);

        DiagLog("  -> accepted as the touchscreen for %#010x, %s\n", locationID,
                driveByDefault
                    ? "driving the pointer (declares itself a TouchScreen)"
                    : "NOT driving the pointer until enabled (does not declare itself a TouchScreen)");

        HIDDeviceState *registered = RegisterTouchDevice(inIOHIDDeviceRef, locationID, contactCount);
        if (registered) {
            registered->drivesPointer = driveByDefault;
            registered->primaryUsage = DevicePrimaryUsage(inIOHIDDeviceRef);
            TouchInputManagerDidConnectTouchscreen(gTouchManager, locationID, driveByDefault);
        } else {
            DiagLog("  -> FAILED to allocate device state; interface not driven\n");
        }
    } else if (contactCount > existing->contactCollectionCount) {
        // A better interface for an already-connected screen arrived (connect order is not
        // deterministic). Swap to it without bothering the upper layer — the locationID,
        // which is all the upper layer keys on, stays connected throughout.
        DiagLog("  -> switching primary interface for %#010x: %ld -> %ld contact collections\n",
               locationID, existing->contactCollectionCount, contactCount);
        // Carry the user's decision across the swap: it belongs to the screen, not to whichever
        // of its interfaces happens to be primary.
        Boolean drivesPointer = existing->drivesPointer;
        IOHIDDeviceRef oldDev = existing->device;
        IOHIDDeviceRegisterInputValueCallback(oldDev, NULL, NULL);
        DeallocateDeviceState(oldDev);
        HIDDeviceState *replacement = RegisterTouchDevice(inIOHIDDeviceRef, locationID, contactCount);
        if (replacement) {
            replacement->drivesPointer = drivesPointer;
            // Read from the interface we are switching *to*, not carried over: it is a different
            // interface of the same device and may well describe itself differently. Forgetting it
            // here is how the device kind would end up Unknown on a combo digitizer, and only
            // sometimes, since connect order is not deterministic.
            replacement->primaryUsage = DevicePrimaryUsage(inIOHIDDeviceRef);
        }
    } else {
        DiagLog("  -> ignored as a secondary interface of %#010x (%ld <= %ld contact collections)\n",
               locationID, contactCount, existing->contactCollectionCount);
    }
}   // Handle_DeviceMatchingCallback



// this will be called when a HID device is removed (unplugged)
static void Handle_RemovalCallback(
                                   void *         inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
                                   IOReturn       inResult,        // the result of the removing operation
                                   void *         inSender,        // the IOHIDManagerRef for the device being removed
                                   IOHIDDeviceRef inIOHIDDeviceRef // the removed HID device
) {
    // Only the interface we actually registered as the touchscreen has state. Secondary
    // interfaces we ignored at match time have none, so their removal is a no-op and must
    // not tell the upper layer the screen went away while the primary is still present.
    HIDDeviceState *device = DeviceStateForRef(inIOHIDDeviceRef);
    if (!device) return;

    uint32_t locationID = device->locationID;
    DiagLog("\nTouchscreen disconnected at locationID %#010x\n", locationID);

    DeallocateDeviceState(inIOHIDDeviceRef);

    TouchInputManagerDidDisconnectTouchscreen(gTouchManager, locationID);
}   // Handle_RemovalCallback



#pragma mark - Start / Stop


// function to create matching dictionary
static CFMutableDictionaryRef CreateDeviceMatchingDictionary(UInt32 inUsagePage, UInt32 inUsage) {
    // create a dictionary to add usage page/usages to
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
                                                              kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (result) {
        if (inUsagePage) {
            // Add key for device type to refine the matching dictionary.
            CFNumberRef pageCFNumberRef = CFNumberCreate(
                                                         kCFAllocatorDefault, kCFNumberIntType, &inUsagePage);
            if (pageCFNumberRef) {
                CFDictionarySetValue(result,
                                     CFSTR(kIOHIDDeviceUsagePageKey), pageCFNumberRef);
                CFRelease(pageCFNumberRef);
                
                // note: the usage is only valid if the usage page is also defined
                if (inUsage) {
                    CFNumberRef usageCFNumberRef = CFNumberCreate(
                                                                  kCFAllocatorDefault, kCFNumberIntType, &inUsage);
                    if (usageCFNumberRef) {
                        CFDictionarySetValue(result,
                                             CFSTR(kIOHIDDeviceUsageKey), usageCFNumberRef);
                        CFRelease(usageCFNumberRef);
                    } else {
                        DiagLog("%s: CFNumberCreate(usage) failed.", __PRETTY_FUNCTION__);
                    }
                }
            } else {
                DiagLog("%s: CFNumberCreate(usage page) failed.", __PRETTY_FUNCTION__);
            }
        }
    } else {
        DiagLog("%s: CFDictionaryCreateMutable failed.", __PRETTY_FUNCTION__);
    }
    return result;
}   // CreateDeviceMatchingDictionary





void OpenHIDManager(void *delegate) {
    gTouchManager = delegate;
    
    
    gHidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    
    if (CFGetTypeID(gHidManager) != IOHIDManagerGetTypeID()) {
        DiagLog("OH CRAP THIS IS NOT AN HID MANAGER");
    }
    
    
    // Matching only on kHIDUsage_Dig_TouchScreen meant a panel that declares itself a TouchPad
    // or a bare Digitizer was never even seen — and since macOS drives a TouchPad as a
    // trackpad, that is exactly the "it behaves like a giant trackpad and Touch Up makes no
    // difference" case. The declared usage is not trustworthy enough to be the sole filter, so
    // match all three and decide what to do with each once its descriptor can be inspected.
    //
    // Anything that is not a declared TouchScreen arrives disabled: see `IsExcludedDevice` for
    // what is refused outright, and `ShouldDriveDeviceByDefault` for what still needs a nod
    // from the user before it is allowed to move the pointer.
    CFMutableDictionaryRef matchesList[] = {
        CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_TouchScreen),
        CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_TouchPad),
        CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Digitizer),
    };

    CFIndex numMatches = sizeof(matchesList) / sizeof(matchesList[0]);

    CFArrayRef matches = CFArrayCreate(kCFAllocatorDefault,
                                       (const void **)matchesList, numMatches, NULL);
    IOHIDManagerSetDeviceMatchingMultiple(gHidManager, matches);
    CFRelease(matches);
    
    IOHIDManagerRegisterDeviceMatchingCallback(gHidManager, Handle_DeviceMatchingCallback, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(gHidManager, Handle_RemovalCallback, NULL);
    
    //    IOHIDManagerRegisterInputReportWithTimeStampCallback(gHidManager, Handle_ReportCallback, NULL);
    
    
    gRunLoopRef = CFRunLoopGetMain();
    
    IOHIDManagerScheduleWithRunLoop(gHidManager, gRunLoopRef,
                                    kCFRunLoopCommonModes);
    
    IOHIDManagerOpen(gHidManager, kIOHIDOptionsTypeNone);
}



void CloseHIDManager(void) {
    // clean up all active device states (DeallocateDeviceState releases any seize)
    while (gDeviceCount > 0) {
        DeallocateDeviceState(gDevices[0].device);
    }

    IOHIDManagerUnscheduleFromRunLoop(gHidManager, gRunLoopRef, kCFRunLoopCommonModes);
    IOHIDManagerClose(gHidManager, kIOHIDOptionsTypeNone);
}

