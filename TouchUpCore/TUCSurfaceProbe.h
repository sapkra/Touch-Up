//
//  TUCSurfaceProbe.h
//  Touch Up Core
//

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>   // AXError
#import <TouchUpCore/TUCTouch.h>

NS_ASSUME_NONNULL_BEGIN


/**
 One request to find out what is under a point. Immutable, because it crosses onto another thread.
 */
@interface TUCSurfaceProbeRequest : NSObject

/// Where to look, in global top-left-origin points — the space `CGEvent` and `kCGWindowBounds` use.
@property (readonly) CGPoint screenPoint;

/// The value of the input manager's probe generation when this was made. Handed back untouched so a
/// stale answer can be recognised and refused.
@property (readonly) uint64_t generation;

/// Which touch this is about. Held strongly, so it stays meaningful after the touch itself is gone.
@property (readonly) NSUUID *touchID;

- (instancetype)initWithScreenPoint:(CGPoint)screenPoint
                         generation:(uint64_t)generation
                            touchID:(NSUUID *)touchID NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end


/**
 What a probe found. Immutable, and holds no `AXUIElementRef` and no `TUCTouch` — the same discipline
 the focus probe in the app layer follows, and for the same reason: nothing here refers into another
 process or into the state machine, so it is safe to hand across a thread and safe to keep.
 */
@interface TUCSurfaceReading : NSObject

@property (readonly) TUCSurfaceKind surface;
@property (readonly) TUCSurfaceSource source;
@property (readonly) uint64_t generation;
@property (readonly) NSUUID *touchID;

/// How long the probe took, in seconds. The number that says whether this feature can work at all on
/// a given machine: an answer that lands after the gesture was decided is an answer nobody could use.
@property (readonly) NSTimeInterval latency;

/// The raw `AXError` from the hit test, for the diagnostics. `kAXErrorSuccess` when it worked.
@property (readonly) AXError error;

/// The role the answer was derived from, for the diagnostics. Never a value, never any of the user's
/// text — a role name only.
@property (readonly, nullable) NSString *role;

/// Bundle identifier of the application that owned the element, or nil.
@property (readonly, nullable) NSString *ownerBundleID;

@end


/**
 Asks the accessibility API what is under a point, without ever letting it hold up the caller.

 The whole reason this class exists rather than a few lines inline: every accessibility read is a
 synchronous message into an arbitrary third-party process, and this framework's reports arrive on the
 main run loop. An application that is hung can take the full messaging timeout to answer — and if
 that wait happens on the main thread, HID reports stop being processed and the touchscreen stops
 responding. That is a far worse failure than not knowing what was touched.

 So: requests go onto a private serial queue and answers come back on the main queue. There is
 nothing here that blocks the caller, and there is no way to ask it to.

 The completion block is called **exactly once for every request**, always on the main queue, whatever
 happened — answered, timed out, refused, no permission, or already stale before it started. That is
 deliberate and worth relying on: it collapses "the answer has not come yet" and "no answer is ever
 coming" into one state with a definite end, so no caller needs a timeout of its own.
 */
@interface TUCSurfaceProbe : NSObject

/**
 Look up what is under `request.screenPoint`.

 Returns immediately. Safe to call from the main thread, and only from the main thread — the
 completion is dispatched there and the statistics it carries are accounted there.

 Requests are served one at a time. A request that is already stale by the time its turn comes is
 answered without making a single call into another process, which is what keeps one unresponsive
 application from making every later answer late as well.
 */
+ (void)probeSurfaceForRequest:(TUCSurfaceProbeRequest *)request
                    completion:(void (^)(TUCSurfaceReading *reading))completion;

/// The newest generation any caller has mentioned. A queued probe compares against this and gives up
/// early rather than interrogating another process about a finger that has already lifted.
+ (void)noteCurrentGeneration:(uint64_t)generation;

/// Drop everything remembered about what is where. Call when the arrangement of windows can have
/// changed wholesale — a different application came forward, the user switched space, a display was
/// reconfigured.
+ (void)invalidateCache;

/// A block for the diagnostics report: whether reads are permitted at all, how long answers take
/// against the time a gesture has to wait for them, and which applications answered nothing.
/// Roles and bundle identifiers only — never any of the user's content.
+ (NSString *)diagnosticsDescription;

@end

NS_ASSUME_NONNULL_END
