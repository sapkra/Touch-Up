//
//  TUCScreen.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 21.03.23.
//

#import "TUCScreen.h"
#import <dlfcn.h>

@interface TUCScreen ()
+ (nullable NSScreen *)systemScreenForDisplayID:(CGDirectDisplayID)displayID;
- (nullable NSString *)edidNameForDisplayID:(CGDirectDisplayID)displayID;
@end

NSString *TUCPhysicalSizeSourceName(TUCPhysicalSizeSource source) {
    switch (source) {
        case TUCPhysicalSizeSourceEDID:    return @"EDID";
        case TUCPhysicalSizeSourceAssumed: return @"assumed";
    }
    return @"unknown";
}


/**
 Points per millimetre to assume when a panel will not say how big it is.

 macOS mostly holds the *point* density of a display steady — a dense panel is driven at a doubled
 backing scale rather than by shrinking everything — so a guess about points travels further than a
 guess about pixels would. Across the machines this runs on it lands between roughly 3.9 pt/mm (a
 non-Retina external at ~100 dpi), 4.3 (a 27" external at "looks like 2560×1440") and 5.0 (a 14"
 MacBook Pro), so the middle of that range is the least-wrong single number.

 The previous 4.0 was the bottom of it — the 2005 non-Retina desktop case — which made every
 millimetre threshold read ~12% wide on typical modern hardware.

 What no constant can cover is a dense panel driven at its *native* grid with no scaling, where the
 true figure is nearer 11 pt/mm and every threshold in the app is consequently ~2.5× too large at
 once. That is not a better-guess problem; it is why `-physicalSizeSource` exists, so a diagnostics
 report says the number was guessed instead of quietly presenting it as measured.
 */
static const CGFloat kAssumedPointsPerMM = 4.5;


@implementation TUCScreen

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
               frameOfFirstScreen:(CGRect)firstFrame {
    if (self = [super init]) {
        self.id = displayID;

        CFUUIDRef cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID);
        if (cfUUID) {
            self.uuid = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, cfUUID);
            CFRelease(cfUUID);
        }

        self.rotation = CGDisplayRotation(displayID);

        // Native physical size (mm) of this exact panel — mirror-independent (it is the
        // panel's own EDID, not the shared mirror content). Note: `CGDisplayScreenSize`
        // swaps width/height with the panel's rotation, so this is in the same on-screen
        // orientation as `rotation`/`frame`, not the built-in orientation.
        self.nativePhysicalSize = CGDisplayScreenSize(displayID);

        // Native pixel resolution: the *largest* mode the panel advertises, not the
        // current one. While mirroring, the current mode is forced to the shared mirror
        // resolution, which is not this panel's own grid; the max mode is the panel's own.
        // Like the physical size, mode dimensions swap with rotation.
        self.nativeResolution = [self largestModePixelSizeForDisplayID:displayID];

        // The name belongs to this exact panel. Prefer its own NSScreen's localized name,
        // but a hardware-mirrored secondary has no NSScreen — fall back to its EDID product
        // name (read by display ID, independent of mirroring), then to a generic label.
        NSScreen *ownScreen = [TUCScreen systemScreenForDisplayID:displayID];
        if (@available(macOS 10.15, *)) {
            self.name = ownScreen.localizedName;
        }
        if (self.name == nil) {
            self.name = [self edidNameForDisplayID:displayID];
        }
        if (self.name == nil) {
            self.name = [NSString stringWithFormat:@"Display %u", displayID];
        }

        // Logical layout comes from the backing NSScreen. A hardware-mirrored secondary
        // panel has no NSScreen of its own — it shows the master's content — so fall back
        // to the master's NSScreen.
        NSScreen *backing = [self systemScreen];
        if (backing) {
            CGRect thisFrame = backing.frame;
            // Flip from AppKit's bottom-left origin to a top-left-origin space.
            self.frame = CGRectMake(thisFrame.origin.x,
                                    thisFrame.origin.y + thisFrame.size.height - firstFrame.size.height,
                                    thisFrame.size.width,
                                    thisFrame.size.height);
            self.logicalResolution = CGSizeMake(thisFrame.size.width * backing.backingScaleFactor,
                                                thisFrame.size.height * backing.backingScaleFactor);
        }
    }

    return self;
}

- (CGSize)largestModePixelSizeForDisplayID:(CGDirectDisplayID)displayID {
    CGSize largest = CGSizeZero;

    NSArray *modes = (__bridge_transfer NSArray *)CGDisplayCopyAllDisplayModes(displayID, NULL);
    for (id m in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
        CGSize size = CGSizeMake(CGDisplayModeGetPixelWidth(mode),
                                 CGDisplayModeGetPixelHeight(mode));
        if (size.width * size.height > largest.width * largest.height) {
            largest = size;
        }
    }

    // Fallback to the current mode if the panel advertises no enumerable modes.
    if (CGSizeEqualToSize(largest, CGSizeZero)) {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
        if (mode) {
            largest = CGSizeMake(CGDisplayModeGetPixelWidth(mode),
                                 CGDisplayModeGetPixelHeight(mode));
            CGDisplayModeRelease(mode);
        }
    }

    return largest;
}

- (nullable NSString *)edidNameForDisplayID:(CGDirectDisplayID)displayID {
    // `CoreDisplay_DisplayCreateInfoDictionary` is a private symbol that returns the
    // panel's EDID info keyed by display ID, so it works even for a mirrored secondary
    // that has no NSScreen. We resolve it via dlsym (rather than linking the private
    // CoreDisplay framework) and degrade gracefully if it is absent or sandbox-blocked.
    typedef CFDictionaryRef (*InfoDictFunc)(CGDirectDisplayID);
    static InfoDictFunc createInfo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createInfo = (InfoDictFunc)dlsym(RTLD_DEFAULT, "CoreDisplay_DisplayCreateInfoDictionary");
    });
    if (createInfo == NULL) {
        return nil;
    }

    NSDictionary *info = (__bridge_transfer NSDictionary *)createInfo(displayID);
    id productNames = info[@"DisplayProductName"];

    if ([productNames isKindOfClass:[NSString class]]) {
        return productNames;
    }
    if ([productNames isKindOfClass:[NSDictionary class]]) {
        // A locale -> name map. Prefer the current locale, then English, then anything.
        NSDictionary<NSString *, NSString *> *names = productNames;
        return names[[[NSLocale currentLocale] localeIdentifier]]
            ?: names[@"en_US"]
            ?: names.allValues.firstObject;
    }
    return nil;
}

+ (nullable NSScreen *)systemScreenForDisplayID:(CGDirectDisplayID)displayID {
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = [[screen deviceDescription] valueForKey:@"NSScreenNumber"];
        if ([number unsignedIntValue] == displayID) {
            return screen;
        }
    }
    return nil;
}

- (nullable NSScreen *)systemScreen {
    NSScreen *own = [TUCScreen systemScreenForDisplayID:(CGDirectDisplayID)self.id];
    if (own) {
        return own;
    }

    // Mirrored secondary: its content lives on the mirror master's NSScreen.
    CGDirectDisplayID master = CGDisplayMirrorsDisplay((CGDirectDisplayID)self.id);
    if (master != kCGNullDirectDisplay) {
        return [TUCScreen systemScreenForDisplayID:master];
    }
    return nil;
}


- (CGFloat)pixelsPerMM {
    // `frame` and `nativePhysicalSize` are both reported in the same (rotated) on-screen
    // orientation, so their widths line up directly — no manual swap needed.
    return self.frame.size.width / [self effectivePhysicalSize].width;
}

- (TUCPhysicalSizeSource)physicalSizeSource {
    CGSize size = self.nativePhysicalSize;
    return (size.width > 0 && size.height > 0) ? TUCPhysicalSizeSourceEDID
                                               : TUCPhysicalSizeSourceAssumed;
}

- (CGSize)effectivePhysicalSize {
    if ([self physicalSizeSource] == TUCPhysicalSizeSourceEDID) {
        return self.nativePhysicalSize;
    }

    // Virtual displays, some capture devices and the occasional panel with a broken EDID
    // report a zero physical size. Taken literally that turns every millimetre threshold in
    // the app into either 0 or infinity, so derive a plausible size from the logical frame
    // instead — approximate, but in the right order of magnitude, which is all these
    // thresholds need. Callers who need to know that it *is* approximate ask
    // `-physicalSizeSource`.
    return CGSizeMake(self.frame.size.width / kAssumedPointsPerMM,
                      self.frame.size.height / kAssumedPointsPerMM);
}

- (CGFloat)millimetreDistanceBetweenRelativePoint:(CGPoint)p1 and:(CGPoint)p2 {
    CGSize physicalSize = [self effectivePhysicalSize];

    CGFloat dx = (p1.x - p2.x) * physicalSize.width;
    CGFloat dy = (p1.y - p2.y) * physicalSize.height;

    return sqrt(dx * dx + dy * dy);
}

- (CGPoint)convertPointRelativeToAbsolute:(CGPoint)relativePoint {
    CGPoint screenOrigin = self.frame.origin;
    CGSize screenSize = self.frame.size;


    CGPoint absLoc = CGPointMake(relativePoint.x * screenSize.width + screenOrigin.x,
                                 relativePoint.y * screenSize.height - screenOrigin.y);

    return absLoc;
}

- (CGSize)contentFractionOfGlass {
    CGFloat glassAspect   = self.nativeResolution.width / self.nativeResolution.height;
    CGFloat contentAspect = self.frame.size.width / self.frame.size.height;
    if (glassAspect <= 0 || contentAspect <= 0) {
        return CGSizeMake(1.0, 1.0);
    }

    // Aspect-fit the content into the glass: it fills one axis fully and is centred on the
    // other, the remaining strip being the black letterbox/pillarbox bars.
    return CGSizeMake((contentAspect >= glassAspect) ? 1.0 : contentAspect / glassAspect,
                      (contentAspect >= glassAspect) ? glassAspect / contentAspect : 1.0);
}

- (CGPoint)convertGlassPointToContentPoint:(CGPoint)glassPoint {
    CGFloat glassAspect   = self.nativeResolution.width / self.nativeResolution.height;
    CGFloat contentAspect = self.frame.size.width / self.frame.size.height;
    if (glassAspect <= 0 || contentAspect <= 0) {
        return glassPoint;
    }

    CGSize fraction = [self contentFractionOfGlass];
    CGFloat fracW = fraction.width;
    CGFloat fracH = fraction.height;

    CGFloat x = (glassPoint.x - (1.0 - fracW) / 2.0) / fracW;
    CGFloat y = (glassPoint.y - (1.0 - fracH) / 2.0) / fracH;

    // A touch landing on a bar falls outside the content; snap it to the nearest edge.
    x = MAX(0.0, MIN(1.0, x));
    y = MAX(0.0, MIN(1.0, y));
    return CGPointMake(x, y);
}



- (NSString *)debugDescription {
    CGDirectDisplayID master = CGDisplayMirrorsDisplay((CGDirectDisplayID)self.id);
    NSString *mirror = (master != kCGNullDirectDisplay)
        ? [NSString stringWithFormat:@"mirrors #%u", master]
        : @"not mirrored";

    return [NSString stringWithFormat:
            @"<TUCScreen #%lu \"%@\"\n"
            "   uuid:     %@\n"
            "   native:   %.0f×%.0f px, %.0f×%.0f mm, rotation %.0f°\n"
            "   logical:  %.0f×%.0f px, %.2f pt/mm\n"
            "   physical: %.0f×%.0f mm (%@)\n"
            "   content:  %.3f×%.3f of glass%@\n"
            "   frame:    %@\n"
            "   mirror:   %@>",
            (unsigned long)self.id, self.name,
            self.uuid,
            self.nativeResolution.width, self.nativeResolution.height,
            self.nativePhysicalSize.width, self.nativePhysicalSize.height, self.rotation,
            self.logicalResolution.width, self.logicalResolution.height, [self pixelsPerMM],
            [self effectivePhysicalSize].width, [self effectivePhysicalSize].height,
            TUCPhysicalSizeSourceName([self physicalSizeSource]),
            [self contentFractionOfGlass].width, [self contentFractionOfGlass].height,
            // Anything but 1×1 means touches near the letterboxed edges are being rescaled, which
            // is worth saying out loud rather than leaving to be inferred from two decimals.
            (fabs([self contentFractionOfGlass].width  - 1.0) < 0.001 &&
             fabs([self contentFractionOfGlass].height - 1.0) < 0.001) ? @"" : @"  ← LETTERBOXED",
            NSStringFromRect(self.frame),
            mirror];
}

+ (NSArray<TUCScreen *> *)allScreens {
    // Use the *online* display list rather than `[NSScreen screens]`: the latter only
    // returns active (drawable) displays and collapses a hardware-mirror set to its
    // master, so the mirrored panels would be invisible to us. The online list has one
    // entry per physically connected panel — exactly one TUCScreen each.
    uint32_t capacity = 0;
    CGGetOnlineDisplayList(0, NULL, &capacity);

    CGDirectDisplayID *displays = calloc(capacity, sizeof(CGDirectDisplayID));
    uint32_t returned = 0;
    CGGetOnlineDisplayList(capacity, displays, &returned);

    // `returned` can exceed `capacity` if a display is connected between the two calls;
    // never read past the buffer.
    uint32_t count = MIN(returned, capacity);

    // The primary display (origin) anchors the AppKit -> top-left coordinate flip.
    NSArray<NSScreen *> *nsScreens = [NSScreen screens];
    CGRect firstFrame = CGRectZero;
    if ([nsScreens count] > 0) {
        firstFrame = [nsScreens objectAtIndex:0].frame;
    }

    NSMutableArray<TUCScreen *> *myScreens = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        TUCScreen *e = [[TUCScreen alloc] initWithDisplayID:displays[i]
                                         frameOfFirstScreen:firstFrame];
        [myScreens addObject:e];
    }

    free(displays);
    return myScreens;
}

@end
