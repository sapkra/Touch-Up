//
//  TUCSurfaceProbe.m
//  Touch Up Core
//

#import "TUCSurfaceProbe.h"

#import <AppKit/AppKit.h>
#import <stdatomic.h>
#import <os/lock.h>


#pragma mark - Bounds

/**
 How long one whole probe may take.

 Checked between calls rather than enforced on any single one, because a classification is a hit test
 plus a role, plus a subrole, plus a walk up the ancestors with a role read at each — seven or more
 messages into another process. A per-call timeout cannot express a bound on the total, and it is the
 total that decides whether an answer is worth anything.

 Much tighter than the quarter-second the focus watcher allows itself, and for a reason: a late answer
 about where the keyboard focus is still useful, while a late answer about what a finger landed on is
 worthless — the gesture has already been decided. A long timeout here cannot help and can only keep
 the queue busy while the next touch waits behind it.
 */
static const NSTimeInterval kSurfaceProbeBudget = 0.12;

/**
 How long any single message into another process may take.

 Set on **every** element the probe holds, never once on the system-wide element. The timeout is a
 per-element setting and whether children inherit it is not clearly specified — which is why the focus
 watcher in the app layer also sets it separately on each element it obtains. Relying on inheritance
 here would mean the ancestor walk running unbounded against exactly the applications that need
 bounding.
 */
static const NSTimeInterval kSurfaceElementMessagingTimeout = 0.05;

/**
 How far up the ancestors to look before giving up.

 The element directly under a finger is usually not the interesting one: in a web view it is a run of
 static text inside a group inside a scroll area, and only the scroll area says what a drag there
 means. Six levels finds that reliably in native applications. It deliberately does not chase a DOM,
 where each level is another round trip and the answer is the same one the fourth level already gave.
 */
static const NSUInteger kSurfaceProbeMaxAncestors = 6;

/// How long a cached answer stays good. Blunt on purpose: interface changes under a resting hand, and
/// there is no cheap way to be told about most of the ways it can.
static const NSTimeInterval kSurfaceCacheLifetime = 2.0;

/// How many places to remember. A user touches a handful of distinct regions in a couple of seconds,
/// and scanning eight rectangles costs nothing next to one message to another process.
static const NSUInteger kSurfaceCacheCapacity = 8;

/**
 How long to leave an application alone after it failed to answer.

 This is the one real weakness of serving requests one at a time: an application that has stopped
 answering makes every probe queued behind it late as well, not just its own. Skipping it outright for
 a moment bounds that, and it can only ever cost an answer — never produce a wrong one.
 */
static const NSTimeInterval kSurfaceSuppressionInterval = 1.0;


#pragma mark - Request and reading

@implementation TUCSurfaceProbeRequest

- (instancetype)initWithScreenPoint:(CGPoint)screenPoint
                         generation:(uint64_t)generation
                            touchID:(NSUUID *)touchID {
    if (self = [super init]) {
        _screenPoint = screenPoint;
        _generation = generation;
        _touchID = touchID;
    }
    return self;
}

@end


@interface TUCSurfaceReading ()
@property (readwrite) TUCSurfaceKind surface;
@property (readwrite) TUCSurfaceSource source;
@property (readwrite) uint64_t generation;
@property (readwrite) NSUUID *touchID;
@property (readwrite) NSTimeInterval latency;
@property (readwrite) AXError error;
@property (readwrite, nullable) NSString *role;
@property (readwrite, nullable) NSString *ownerBundleID;
@end

@implementation TUCSurfaceReading
@end


#pragma mark - Cache entry

/// One remembered answer, valid over the element's own rectangle.
///
/// Keyed on the element's `kAXFrame` rather than on the touch point or on a grid, so the region the
/// answer is true for is exactly what the element said it was, instead of a guess around a point.
@interface TUCSurfaceCacheEntry : NSObject
@property CGRect elementFrame;
@property pid_t ownerPID;
@property CGWindowID windowNumber;
@property CGRect windowBounds;
@property TUCSurfaceKind surface;
@property NSTimeInterval recordedAt;
@property (nullable) NSString *role;
@property (nullable) NSString *ownerBundleID;
@end

@implementation TUCSurfaceCacheEntry
@end


#pragma mark - Queue-confined state

/**
 The cache, the suppression list and the coaxed-process set are touched only from `gProbeQueue`. The
 counters and the lock-guarded block further down are the two deliberate exceptions, each explained
 where it is declared.

 That confinement is what keeps it free of locks — the same reasoning the HID interpreter relies on
 for being main-thread-only. It is also fragile in exactly one way, so it is worth stating plainly:
 **the only operations permitted against `gProbeQueue` are dispatching onto it, and dispatching from
 it back to the main queue.** A `dispatch_sync` from the main thread would reintroduce precisely the
 stall this queue exists to remove, in a form far harder to notice than the synchronous call it
 replaced.
 */
static dispatch_queue_t gProbeQueue;

/// Answers remembered from earlier probes, newest first.
static NSMutableArray<TUCSurfaceCacheEntry *> *gCache;

/// Applications that failed to answer, and when they may be asked again.
static NSMutableDictionary<NSNumber *, NSNumber *> *gSuppressedUntil;

/// Applications already asked to build an accessibility tree at all.
static NSMutableSet<NSNumber *> *gCoaxedPIDs;

/**
 The newest generation any caller has mentioned, and the counters behind the diagnostics.

 Atomic rather than queue-confined, which is a deliberate exception to the paragraph above. The
 generation has to be readable from the queue and writable from the main thread — that is its whole
 job, letting a queued probe discover that the finger it was about has already lifted. The counters
 only ever feed a human-readable report, where a count that is one behind changes nothing.
 */
static atomic_uint_fast64_t gCurrentGeneration;
static atomic_uint_fast64_t gProbesFired;
static atomic_uint_fast64_t gProbesAnswered;
static atomic_uint_fast64_t gProbesAbandonedStale;
static atomic_uint_fast64_t gProbesOutOfBudget;
static atomic_uint_fast64_t gProbesSuppressed;
static atomic_uint_fast64_t gCacheHits;
static atomic_uint_fast64_t gCacheMisses;
static atomic_uint_fast64_t gCacheDroppedWindowChanged;

/// Latency in fixed buckets: <=1, <=2, <=4, <=8, <=16, <=32, <=64, <=128, and everything above.
/// Buckets rather than a running average, because the only question worth asking is whether an answer
/// ever takes longer than a gesture can wait, and an average hides exactly that.
#define kSurfaceLatencyBucketCount 9
static atomic_uint_fast64_t gLatencyBuckets[kSurfaceLatencyBucketCount];

/**
 The last answer and the applications that never gave one, for the diagnostics.

 These are the only pieces of state written on the probe queue and read from the main thread, so they
 are the only ones that need a lock. It is a real one rather than a comment claiming a torn read would
 be harmless: these are object pointers, and a retain racing a release does not misreport a line, it
 crashes.

 The lock is only ever held across a pointer copy or a set insertion — never across a call into
 another process. That is the rule that keeps it from becoming the very stall this queue exists to
 avoid, and it is why a lock is acceptable here at all.
 */
static os_unfair_lock gDiagnosticsLock = OS_UNFAIR_LOCK_INIT;
static NSString *gLastRole;              // guarded by gDiagnosticsLock
static NSString *gLastOwnerBundleID;     // guarded by gDiagnosticsLock
static AXError gLastError;               // guarded by gDiagnosticsLock
static NSMutableSet<NSString *> *gMuteBundleIDs;  // guarded by gDiagnosticsLock


#pragma mark - Role tables

/**
 Which roles mean what for the purpose of deciding what dragging there should do.

 **Not** the tables the on-screen keyboard uses to decide whether something takes typing, even though
 several roles appear in both. The two questions genuinely disagree: a scroll bar and a table are both
 things you cannot type into, but one has to be dragged and the other has to be scrolled. Merging the
 tables would look like a tidy-up and would break the keyboard the first time a scrolling role was
 added here.
 */
static TUCSurfaceKind SurfaceForRole(NSString *role, NSString *subrole) {
    static NSSet<NSString *> *controlRoles;
    static NSSet<NSString *> *textRoles;
    static NSSet<NSString *> *chromeRoles;
    static NSSet<NSString *> *scrollRoles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Must follow the finger from the first movement. Scrolling any of these does nothing at all,
        // which is the failure this whole mechanism is most visibly for.
        controlRoles = [NSSet setWithArray:@[
            (__bridge NSString *)kAXSliderRole,
            (__bridge NSString *)kAXScrollBarRole,
            (__bridge NSString *)kAXIncrementorRole,
            (__bridge NSString *)kAXSplitterRole,
            (__bridge NSString *)kAXColorWellRole,
            (__bridge NSString *)kAXDisclosureTriangleRole,
            // Neither of these has a constant in the SDK headers.
            @"AXStepper",
            @"AXValueIndicator",
        ]];

        textRoles = [NSSet setWithArray:@[
            (__bridge NSString *)kAXTextAreaRole,
            (__bridge NSString *)kAXTextFieldRole,
            @"AXSearchField",
            @"AXSecureTextField",
        ]];

        chromeRoles = [NSSet setWithArray:@[
            (__bridge NSString *)kAXToolbarRole,
            @"AXDockItem",
        ]];

        scrollRoles = [NSSet setWithArray:@[
            (__bridge NSString *)kAXScrollAreaRole,
            (__bridge NSString *)kAXTableRole,
            (__bridge NSString *)kAXOutlineRole,
            (__bridge NSString *)kAXListRole,
            @"AXWebArea",
        ]];
    });

    if (role == nil) {
        return TUCSurfaceKindUnknown;
    }

    if ([controlRoles containsObject:role]) return TUCSurfaceKindControl;
    if ([textRoles containsObject:role])    return TUCSurfaceKindTextArea;
    // Expressed as a subrole in several applications and as a role in others, so both are consulted.
    if (subrole && [textRoles containsObject:subrole]) return TUCSurfaceKindTextArea;

    if ([chromeRoles containsObject:role]) return TUCSurfaceKindWindowChrome;
    if (subrole && [subrole isEqualToString:@"AXTitleBar"]) return TUCSurfaceKindWindowChrome;

    // Deliberately no rule for a Finder icon.
    //
    // There was one, reading an icon owned by Finder as desktop so it could be dragged straight away.
    // It could never have helped and could only have hurt: the real desktop is established by the
    // window list finding no window at all, and that answer is returned without ever asking here — so
    // the only icons this could ever see are the ones inside a Finder *window*, where it turned every
    // flick that happened to start on a file into dragging that file instead of scrolling the folder.
    //
    // Falling through to the enclosing scroll area is both safer and what a tablet does: a flick over
    // a list scrolls it, and picking a file up is what holding first is for, which arrives separately
    // as `HoldAndDrag` and drags whatever the surface.
    if ([scrollRoles containsObject:role]) return TUCSurfaceKindScrollArea;

    // Long menus do scroll, and reading one as a scroll area would mean a tap that drifts a
    // millimetre scrolls the menu instead of choosing the item under the finger.
    if ([role isEqualToString:(__bridge NSString *)kAXMenuRole]
        || [role isEqualToString:(__bridge NSString *)kAXMenuItemRole]
        || [role isEqualToString:(__bridge NSString *)kAXMenuBarRole]) {
        return TUCSurfaceKindContent;
    }

    return TUCSurfaceKindUnknown;
}


#pragma mark - Accessibility helpers

/// Reads a string attribute, or nil if it is absent, of another type, or unreadable. The three are
/// deliberately not distinguished: no caller here can act differently on them.
static NSString *CopyStringAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || value == NULL) {
        return nil;
    }
    NSString *result = (CFGetTypeID(value) == CFStringGetTypeID()) ? (__bridge NSString *)value : nil;
    // Retained by the string being returned, so releasing the CF value is safe.
    result = [result copy];
    CFRelease(value);
    return result;
}


static CGRect ElementFrame(AXUIElementRef element) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXFrame"), &value) != kAXErrorSuccess
        || value == NULL) {
        return CGRectNull;
    }

    CGRect frame = CGRectNull;
    if (CFGetTypeID(value) == AXValueGetTypeID()) {
        AXValueGetValue((AXValueRef)value, kAXValueCGRectType, &frame);
    }
    CFRelease(value);
    return frame;
}


static NSString *BundleIDForPID(pid_t pid) {
    return [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
}


/**
 The topmost ordinary window under `point`, as identity only.

 A second, smaller version of the walk the input manager does on the main thread. Kept separate on
 purpose: this one runs on the probe queue, needs only who and which rather than a verdict about
 raising, and must not touch anything belonging to the state machine. `CGWindowListCopyWindowInfo`
 returns a snapshot and is safe to call from any thread.
 */
static BOOL WindowIdentityUnderPoint(CGPoint point, pid_t *outPID, CGWindowID *outNumber, CGRect *outBounds) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (list == NULL) {
        return NO;
    }

    BOOL found = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(list, i);

        CFDictionaryRef boundsDict = CFDictionaryGetValue(dict, kCGWindowBounds);
        CGRect bounds = CGRectZero;
        if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) continue;
        if (!CGRectContainsPoint(bounds, point)) continue;

        CFNumberRef pidRef = CFDictionaryGetValue(dict, kCGWindowOwnerPID);
        CFNumberRef numRef = CFDictionaryGetValue(dict, kCGWindowNumber);
        pid_t pid = 0;
        int number = 0;
        if (pidRef != NULL) CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
        if (numRef != NULL) CFNumberGetValue(numRef, kCFNumberIntType, &number);

        if (outPID)    *outPID = pid;
        if (outNumber) *outNumber = (CGWindowID)number;
        if (outBounds) *outBounds = bounds;
        found = YES;
        break;
    }

    CFRelease(list);
    return found;
}


#pragma mark - Cache

static void PruneCache(NSTimeInterval now) {
    NSMutableIndexSet *stale = [NSMutableIndexSet indexSet];
    [gCache enumerateObjectsUsingBlock:^(TUCSurfaceCacheEntry *entry, NSUInteger idx, BOOL *stop) {
        if (now - entry.recordedAt > kSurfaceCacheLifetime) {
            [stale addIndex:idx];
        }
    }];
    [gCache removeObjectsAtIndexes:stale];
}


/**
 A remembered answer for this point, if one is still trustworthy.

 The cheap source invalidates the expensive one here, and for free: the entry recorded which window
 was under the point and where that window was, so a window that has since moved, been replaced, or
 scrolled out from under the point drops its entry. That is the failure this prevents — a cached
 "scroll area at this rectangle" describing a slider, after the view underneath scrolled.
 */
static TUCSurfaceCacheEntry *CachedEntryForPoint(CGPoint point, pid_t pid, CGWindowID windowNumber, CGRect windowBounds) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    PruneCache(now);

    for (TUCSurfaceCacheEntry *entry in gCache) {
        if (!CGRectContainsPoint(entry.elementFrame, point)) continue;

        if (entry.ownerPID != pid || entry.windowNumber != windowNumber
            || !CGRectEqualToRect(entry.windowBounds, windowBounds)) {
            atomic_fetch_add(&gCacheDroppedWindowChanged, 1);
            continue;
        }

        return entry;
    }
    return nil;
}


static void RememberEntry(TUCSurfaceCacheEntry *entry) {
    if (CGRectIsNull(entry.elementFrame) || CGRectIsEmpty(entry.elementFrame)) {
        // Without a region there is nothing to be valid over, so there is nothing worth keeping.
        return;
    }
    [gCache insertObject:entry atIndex:0];
    while (gCache.count > kSurfaceCacheCapacity) {
        [gCache removeLastObject];
    }
}


#pragma mark - Probe

@implementation TUCSurfaceProbe

+ (void)initialize {
    if (self != [TUCSurfaceProbe class]) return;

    // Serial, so requests cannot pile up and cannot answer out of order. Concurrency would not buy
    // parallel work here: every accessibility call blocks the thread it is made on, so several at
    // once would only mean several threads asleep inside the same unresponsive application, and a
    // widening thread pool inside a driver process is the last place that belongs.
    //
    // `USER_INITIATED` because this is racing the few tens of milliseconds a finger takes to travel
    // far enough to mean something.
    gProbeQueue = dispatch_queue_create("de.touchup.surfaceprobe",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));

    gCache = [NSMutableArray array];
    gSuppressedUntil = [NSMutableDictionary dictionary];
    gCoaxedPIDs = [NSMutableSet set];
    gMuteBundleIDs = [NSMutableSet set];

    // Each of these is a moment the whole visual arrangement can be different, so nothing remembered
    // about what was where survives it. Observed here rather than by the input manager because it is
    // this cache's own concern, and because the manager has no business knowing the cache exists.
    NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
    for (NSString *name in @[NSWorkspaceDidActivateApplicationNotification,
                             NSWorkspaceActiveSpaceDidChangeNotification]) {
        [workspace addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            [TUCSurfaceProbe invalidateCache];
        }];
    }

    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        [TUCSurfaceProbe invalidateCache];
    }];

    // An application that has quit cannot be asked again, and its window IDs will be reused. Both
    // the coax record and the suppression are about a live process, so both are per-pid state that
    // has to go with it.
    [workspace addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                          object:nil
                           queue:nil
                      usingBlock:^(NSNotification *note) {
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        pid_t pid = app.processIdentifier;
        dispatch_async(gProbeQueue, ^{
            [gCoaxedPIDs removeObject:@(pid)];
            [gSuppressedUntil removeObjectForKey:@(pid)];
            [gCache filterUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(TUCSurfaceCacheEntry *e, NSDictionary *b) {
                    return e.ownerPID != pid;
                }]];
        });
    }];
}


+ (void)noteCurrentGeneration:(uint64_t)generation {
    atomic_store(&gCurrentGeneration, generation);
}


+ (void)invalidateCache {
    dispatch_async(gProbeQueue, ^{
        [gCache removeAllObjects];
    });
}


+ (void)probeSurfaceForRequest:(TUCSurfaceProbeRequest *)request
                    completion:(void (^)(TUCSurfaceReading *))completion {

    atomic_fetch_add(&gProbesFired, 1);

    // Raised, never lowered. Callers do fire these in order today, but the whole abandonment rule is
    // "anything older than the newest is unwanted", and a store would let one out-of-order request
    // wind the clock back and resurrect probes that had already been correctly given up on.
    uint64_t seen = atomic_load(&gCurrentGeneration);
    while (request.generation > seen
           && !atomic_compare_exchange_weak(&gCurrentGeneration, &seen, request.generation)) { }

    NSTimeInterval firedAt = [NSDate timeIntervalSinceReferenceDate];

    dispatch_async(gProbeQueue, ^{
        TUCSurfaceReading *reading = [self readingForRequest:request firedAt:firedAt];

        // Always, exactly once, on the main queue — including every giving-up path above. A caller
        // that is told "no answer is coming" needs no timeout of its own, and that is the whole
        // reason this contract is worth keeping.
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(reading);
        });
    });
}


/// Runs on `gProbeQueue`. Touches nothing belonging to the input manager: not its touch set, not a
/// `TUCTouch`, not a `TUCScreen`, not the cursor utilities. The point it works from was converted on
/// the main thread and handed over in the request.
+ (TUCSurfaceReading *)readingForRequest:(TUCSurfaceProbeRequest *)request firedAt:(NSTimeInterval)firedAt {

    TUCSurfaceReading *reading = [TUCSurfaceReading new];
    reading.generation = request.generation;
    reading.touchID = request.touchID;
    reading.surface = TUCSurfaceKindUnknown;
    reading.source = TUCSurfaceSourceNone;
    reading.error = kAXErrorSuccess;

    NSTimeInterval (^elapsed)(void) = ^NSTimeInterval {
        return [NSDate timeIntervalSinceReferenceDate] - firedAt;
    };

    /// Records the latency, and takes `timed` for whether this probe actually went and asked anybody.
    ///
    /// The histogram exists to answer one question — does an answer ever take longer than a gesture
    /// can wait — and only probes that did the work bear on it. Timing the give-up paths too would
    /// fill it with the sub-millisecond cost of deciding not to bother, which is most of them during
    /// ordinary tapping, and would make even a hopelessly slow machine look instant.
    TUCSurfaceReading *(^finish)(BOOL) = ^TUCSurfaceReading *(BOOL timed) {
        reading.latency = elapsed();
        if (timed) {
            NSUInteger bucket = 0;
            NSTimeInterval ms = reading.latency * 1000.0;
            while (bucket < kSurfaceLatencyBucketCount - 1 && ms > (1 << bucket)) bucket++;
            atomic_fetch_add(&gLatencyBuckets[bucket], 1);
        }
        return reading;
    };

    // A finger that has already lifted, or been replaced by the next one. Answered without a single
    // message to another process, which is what stops a backlog costing anything.
    if (request.generation != atomic_load(&gCurrentGeneration)) {
        atomic_fetch_add(&gProbesAbandonedStale, 1);
        return finish(NO);
    }

    if (!AXIsProcessTrusted()) {
        reading.error = kAXErrorAPIDisabled;
        return finish(NO);
    }

    CGPoint point = request.screenPoint;

    // Who owns the window under the point, from the cheap source. Needed three times over: to
    // validate a cached answer, to know which application to coax, and to recognise a Finder icon.
    pid_t windowPID = 0;
    CGWindowID windowNumber = 0;
    CGRect windowBounds = CGRectNull;
    BOOL hasWindow = WindowIdentityUnderPoint(point, &windowPID, &windowNumber, &windowBounds);

    if (hasWindow) {
        TUCSurfaceCacheEntry *cached = CachedEntryForPoint(point, windowPID, windowNumber, windowBounds);
        if (cached) {
            atomic_fetch_add(&gCacheHits, 1);
            reading.surface = cached.surface;
            reading.source = TUCSurfaceSourceAXElement;
            reading.role = cached.role;
            reading.ownerBundleID = cached.ownerBundleID;
            // Deliberately untimed: a cache hit measures how long it takes not to ask, which would
            // flatter the histogram exactly in proportion to how well the cache is working.
            return finish(NO);
        }
        atomic_fetch_add(&gCacheMisses, 1);

        NSNumber *until = gSuppressedUntil[@(windowPID)];
        if (until && [NSDate timeIntervalSinceReferenceDate] < until.doubleValue) {
            atomic_fetch_add(&gProbesSuppressed, 1);
            reading.error = kAXErrorCannotComplete;
            return finish(NO);
        }
    }

    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(systemWide, (float)kSurfaceElementMessagingTimeout);

    AXUIElementRef element = NULL;
    // Global, top-left-origin points. The same space `kCGWindowBounds` and `CGEvent` use, and the
    // same space the input manager already converted the touch into — so nothing is converted here.
    // `NSScreen.frame` is bottom-left and is the trap; using it would classify correctly near the
    // vertical middle of a display and mirrored towards its top and bottom edges.
    AXError err = AXUIElementCopyElementAtPosition(systemWide, (float)point.x, (float)point.y, &element);
    CFRelease(systemWide);

    reading.error = err;

    os_unfair_lock_lock(&gDiagnosticsLock);
    gLastError = err;
    os_unfair_lock_unlock(&gDiagnosticsLock);

    if (err != kAXErrorSuccess || element == NULL) {
        if (hasWindow) {
            // Ask it to build a tree, for next time. Fired here rather than before giving up because
            // setting the attribute is itself a message that can block, and charging that to a probe
            // that has already failed would spend budget it no longer has.
            //
            // Suppression waits for the *second* failure, deliberately. Suppressing on the first
            // would silence the application for the next second — which is exactly the window in
            // which the tree we just asked for appears, so the request would never once be given the
            // chance to have worked. An application that fails again after being asked has genuinely
            // nothing to say.
            BOOL hadBeenAsked = [gCoaxedPIDs containsObject:@(windowPID)];
            [self coaxPID:windowPID];

            if (hadBeenAsked) {
                gSuppressedUntil[@(windowPID)] =
                    @([NSDate timeIntervalSinceReferenceDate] + kSurfaceSuppressionInterval);

                NSString *bundleID = BundleIDForPID(windowPID);
                if (bundleID) {
                    os_unfair_lock_lock(&gDiagnosticsLock);
                    [gMuteBundleIDs addObject:bundleID];
                    os_unfair_lock_unlock(&gDiagnosticsLock);
                }
            }
        }
        return finish(YES);
    }

    pid_t elementPID = 0;
    AXUIElementGetPid(element, &elementPID);
    NSString *ownerBundleID = BundleIDForPID(elementPID);
    reading.ownerBundleID = ownerBundleID;

    os_unfair_lock_lock(&gDiagnosticsLock);
    gLastOwnerBundleID = ownerBundleID;
    os_unfair_lock_unlock(&gDiagnosticsLock);

    // Walk up until something says what a drag here means. The leaf is usually a run of text or an
    // unnamed group, which says nothing at all.
    AXUIElementRef current = element;
    CFRetain(current);
    TUCSurfaceKind surface = TUCSurfaceKindUnknown;
    CGRect matchedFrame = CGRectNull;
    NSString *matchedRole = nil;

    /// The element actually under the finger, remembered from the first time round so concluding
    /// "ordinary content" costs no further messages.
    CGRect leafFrame = CGRectNull;
    NSString *leafRole = nil;

    /// Whether the walk finished because it had genuinely seen everything there was to see, rather
    /// than because it gave up. Only a finished walk may conclude anything.
    BOOL reachedTopOfTree = NO;

    for (NSUInteger depth = 0; depth < kSurfaceProbeMaxAncestors; depth++) {
        if (elapsed() > kSurfaceProbeBudget) {
            atomic_fetch_add(&gProbesOutOfBudget, 1);
            break;
        }

        AXUIElementSetMessagingTimeout(current, (float)kSurfaceElementMessagingTimeout);

        NSString *role = CopyStringAttribute(current, kAXRoleAttribute);
        NSString *subrole = CopyStringAttribute(current, kAXSubroleAttribute);

        // Every accessibility element has a role; being unable to read one means the read failed, not
        // that the element has none. An element that will not say what it is has told us nothing, and
        // continuing up from it would be walking a tree we cannot see.
        if (role == nil) {
            break;
        }

        if (depth == 0) {
            leafRole = role;
            leafFrame = ElementFrame(current);
        }

        surface = SurfaceForRole(role, subrole);
        if (surface != TUCSurfaceKindUnknown) {
            // The matched element's own rectangle, which is exactly the region this answer holds
            // over — a whole scroll area, or just the slider.
            matchedFrame = ElementFrame(current);
            matchedRole = role;
            break;
        }

        CFTypeRef parent = NULL;
        AXError parentErr = AXUIElementCopyAttributeValue(current, kAXParentAttribute, &parent);

        // The same distinction the focus probe in the app layer draws between a negative answer and
        // no answer. "There is no parent" means the top of the tree and is a result; anything else —
        // a timeout, an application that stopped talking — leaves the question open.
        if (parentErr == kAXErrorNoValue || parentErr == kAXErrorAttributeUnsupported) {
            reachedTopOfTree = YES;
            if (parent) CFRelease(parent);
            break;
        }
        if (parentErr != kAXErrorSuccess || parent == NULL) {
            break;
        }
        if (CFGetTypeID(parent) != AXUIElementGetTypeID()) {
            CFRelease(parent);
            break;
        }

        CFRelease(current);
        current = (AXUIElementRef)parent;   // ownership transferred from the copy above
    }

    // Nothing matched, but the whole tree above the finger was read successfully and none of it was
    // anything in particular. That is an answer — an ordinary window interior — and it is not the
    // same as not knowing.
    //
    // Reached only on a completed walk. A walk that ran out of budget, hit an unreadable element, or
    // simply stopped at the ancestor limit has not established that there is nothing here; it has
    // established nothing at all, and must say so. Calling those `Content` would have handed the
    // caller a confident positive answer produced by giving up — and cached it, so the same wrong
    // answer would be served instantly for the next two seconds.
    //
    // Recorded against the *leaf's* rectangle, not the top of the tree it was reached through. The
    // conclusion was reached by walking up to a window, and a window is mostly not ordinary content:
    // caching it over the window's frame would answer "ordinary content" for every point in that
    // window for the next two seconds, sliders and scroll bars included.
    if (surface == TUCSurfaceKindUnknown && reachedTopOfTree) {
        surface = TUCSurfaceKindContent;
        matchedFrame = leafFrame;
        matchedRole = leafRole;
    }

    if (surface != TUCSurfaceKindUnknown) {
        reading.surface = surface;
        reading.source = TUCSurfaceSourceAXElement;
        reading.role = matchedRole;

        os_unfair_lock_lock(&gDiagnosticsLock);
        gLastRole = matchedRole;
        os_unfair_lock_unlock(&gDiagnosticsLock);
    }

    if (hasWindow && surface != TUCSurfaceKindUnknown) {
        TUCSurfaceCacheEntry *entry = [TUCSurfaceCacheEntry new];
        entry.elementFrame = matchedFrame;
        entry.ownerPID = windowPID;
        entry.windowNumber = windowNumber;
        entry.windowBounds = windowBounds;
        entry.surface = surface;
        entry.role = matchedRole;
        entry.ownerBundleID = ownerBundleID;
        entry.recordedAt = [NSDate timeIntervalSinceReferenceDate];
        RememberEntry(entry);
    }

    if (surface != TUCSurfaceKindUnknown) {
        atomic_fetch_add(&gProbesAnswered, 1);
    }

    CFRelease(current);
    CFRelease(element);
    return finish(YES);
}


/**
 Asks an application to expose an accessibility tree at all.

 Chrome and most things built on Electron expose nothing until asked. Deliberately only this flag:
 `AXEnhancedUserInterface`, the older one, makes some applications rebuild their entire hierarchy and
 is known to break window resizing in others.

 Once per process, tracked here rather than in the app layer's focus watcher because that set is
 confined to the main thread and this one to the probe queue. The duplication is the price of the
 confinement; the right long-term home is one of these that the other calls.
 */
+ (void)coaxPID:(pid_t)pid {
    if ([gCoaxedPIDs containsObject:@(pid)]) return;
    [gCoaxedPIDs addObject:@(pid)];

    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, (float)kSurfaceElementMessagingTimeout);
    AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
    CFRelease(app);
}


#pragma mark - Diagnostics

+ (NSString *)diagnosticsDescription {
    NSMutableString *out = [NSMutableString stringWithString:@"───── Surface probe ─────\n"];

    if (!AXIsProcessTrusted()) {
        [out appendString:@"Accessibility: NOT GRANTED — nothing under a finger can be read, so one\n"
                           "               finger scrolls everywhere and windows cannot be dragged\n"
                           "               by their title bars. The permission is remembered per app\n"
                           "               signature, so a rebuild can lose it.\n"];
    } else {
        [out appendString:@"Accessibility: granted\n"];
    }

    uint64_t fired = atomic_load(&gProbesFired);
    [out appendFormat:@"Probes: %llu fired, %llu answered, %llu stale on arrival at the queue,\n"
                       "        %llu ran out of budget, %llu skipped (application not answering)\n",
     fired,
     atomic_load(&gProbesAnswered),
     atomic_load(&gProbesAbandonedStale),
     atomic_load(&gProbesOutOfBudget),
     atomic_load(&gProbesSuppressed)];

    [out appendFormat:@"Cache: %llu hits, %llu misses, %llu dropped (window under the point changed)\n",
     atomic_load(&gCacheHits),
     atomic_load(&gCacheMisses),
     atomic_load(&gCacheDroppedWindowChanged)];

    // A gesture has roughly 30-80 ms before the finger has travelled far enough to be decided, so
    // this is the line that says whether the feature can work at all on this machine.
    [out appendString:@"Latency (a gesture has roughly 30-80 ms to wait):\n        "];
    for (NSUInteger i = 0; i < kSurfaceLatencyBucketCount; i++) {
        if (i == kSurfaceLatencyBucketCount - 1) {
            [out appendFormat:@">128ms:%llu", atomic_load(&gLatencyBuckets[i])];
        } else {
            [out appendFormat:@"<=%dms:%llu  ", (1 << i), atomic_load(&gLatencyBuckets[i])];
        }
    }
    [out appendString:@"\n"];

    // Copied out under the lock and formatted after it, so nothing is held while building a string.
    os_unfair_lock_lock(&gDiagnosticsLock);
    NSString *lastRole = gLastRole;
    NSString *lastOwner = gLastOwnerBundleID;
    AXError lastError = gLastError;
    NSArray<NSString *> *mute = [gMuteBundleIDs allObjects];
    os_unfair_lock_unlock(&gDiagnosticsLock);

    if (lastRole || lastOwner) {
        [out appendFormat:@"Last answer: role %@ in %@\n",
         lastRole ?: @"(none)", lastOwner ?: @"(unknown)"];
    }
    if (lastError != kAXErrorSuccess) {
        [out appendFormat:@"Last error: %d\n", (int)lastError];
    }

    // Named because "it works everywhere except in this one application" is the shape almost every
    // report of this failing will take, and without the name there is nothing to act on.
    if (mute.count > 0) {
        [out appendFormat:@"Answered nothing even after being asked to: %@\n",
         [mute componentsJoinedByString:@", "]];
    }

    return out;
}

@end
