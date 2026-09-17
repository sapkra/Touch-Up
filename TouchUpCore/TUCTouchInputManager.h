//
//  TUCTouchInputManager.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>
#import <TouchUpCore/TUCTouchInputManager-C.h>
#import <TouchUpCore/TUCTouchDelegate.h>
#import <TouchUpCore/TUCTouch.h>

NS_ASSUME_NONNULL_BEGIN



@interface TUCTouchInputManager : NSObject

@property (weak, nonatomic) id<TUCTouchDelegate> delegate;

@property (strong, atomic) NSMutableSet<TUCTouch *> *touchSet;

/**
 Allows to deactiate that the framework processes touches to post them as mouse events.
 The default value is YES.
 */
@property BOOL postMouseEvents;


/**
 The maximal distance in mm that two taps may be apart from each other to count as double click
 */
@property CGFloat doubleClickTolerance;

/**
 How long the user has to hold before a drag gesture turns into holdAndDrag.
 */
@property NSTimeInterval holdDuration;

/**
 How far (in mm) a finger may travel from where it first touched down and still count as a
 tap rather than a drag or a scroll.

 Inside this radius a touch produces a click on lift-off and posts no movement events at
 all. The radius has to be comfortably larger than the digitizer's noise and than the way
 the reported contact centroid shifts while a finger flattens onto the glass and lifts off
 again — otherwise those few tenths of a millimetre are read as the start of a drag and the
 click is never generated.
 */
@property CGFloat tapTolerance;

/**
 If a touch is no longer reported by the screen, wait for this number of incoming reports bevore deleting it from the touch set.
 */
@property NSInteger errorResistance;


/**
 If a touchscreen sometimes sends invalid touch data at location (0,0), activate this option to ignore them
 */
@property BOOL ignoreOriginTouches;


- (void)start;

- (void)stop;


/**
 Opt-in exclusive access. When YES, connected touchscreens are seized so macOS and other
 apps no longer receive their events — Touch Up becomes the sole handler. Pen interfaces of
 combo digitizers stay shared, so the pen keeps working through macOS. Default is NO.
 Applies immediately to currently-connected devices and to future connections.
 */
- (void)setTouchscreensSeized:(BOOL)seized;


/**
 Allows or forbids one connected digitizer to move the pointer. Touch data keeps flowing either
 way, so a device can be watched in the test overlay before it is trusted with input.
 A digitizer that does not declare itself a TouchScreen starts out forbidden.
 */
- (void)setDigitizerDrivesPointer:(BOOL)drivesPointer forLocationID:(uint32_t)locationID;
- (BOOL)digitizerDrivesPointerForLocationID:(uint32_t)locationID;


/**
 What the digitizer's HID descriptor claims it is, or `TUCDigitizerKindUnknown` if nothing is
 registered for that location ID.

 Discovered, never configured: there is no setter, because a device's descriptor is not the user's
 to disagree with. The one decision they do get is `-setDigitizerDrivesPointer:forLocationID:`.
 */
- (TUCDigitizerKind)digitizerKindForLocationID:(uint32_t)locationID;


/**
 Hides the mouse pointer, so touching the glass feels direct rather than like steering a mouse
 from a distance. There is no pointer on a tablet.

 Touching hides it. Moving a mouse or trackpad brings it back, and the next touch hides it again,
 so a pointing device is always visible while it is being used and never otherwise. Telling our own
 movement of the pointer from another device's is what makes that hard; see
 `-checkWhetherSomethingElseMovedThePointer` for how it is decided, and for the two mechanisms that
 were tried before it and could not be verified.

 Always restore this before the app exits; the underlying calls are process-scoped and there is
 nothing to clean up after a crash.
 */
@property (nonatomic) BOOL hidesCursor;



/**
 Whether to work out what each finger landed on, so a gesture can mean different things in different
 places. Default is YES.

 A capability rather than a mapping: it decides whether the question is asked at all, and the
 mapping decides what to do with the answer. The built-in mapping needs it — knowing what is under
 the finger is the difference between one finger that always scrolls and one that scrolls a page
 but moves a window by its title bar — so it is on unless a framework consumer that supplies its
 own surface-blind mapping turns it off. The cheap half of the classification is a window-server
 round trip, and paying for it on every touch would be wrong for somebody not using the result.

 Answers are never waited for. A gesture that has to be decided before one arrives is decided
 without it, so this changes what is *known*, never when anything happens.
 */
@property (nonatomic) BOOL classifiesSurfaces;


/**
 Reduces the glass to pointing and clicking: nothing can be scrolled, dragged, zoomed or held.
 Default is NO.

 For a machine left unattended in front of the public, where a visitor who scrolls a window away
 or drags a file into a folder leaves it broken for the next one. It is a deployment decision
 rather than a preference, which is why it is the one thing about the mapping that can still be
 changed.
 */
@property (nonatomic) BOOL kioskMode;


/**
 What to do about a panel that renames a finger mid-stroke.

 Some digitizers stop reporting a contact and start reporting the same finger under a
 different contact ID a few milliseconds later. Identity here is the contact ID, so the
 finger arrives as a second touch: the count of fingers down flickers, gestures restart,
 and drags break in the middle.

 `Observe` is the default and changes nothing — it works out what it *would* have done and
 counts it, so the diagnostics report can say whether a panel actually has this fault and
 how far apart the two contacts were. `On` acts on it. `Off` skips the question entirely.
 */
typedef NS_ENUM(NSUInteger, TUCContactIdentityRepair) {
    TUCContactIdentityRepairOff = 0,
    TUCContactIdentityRepairObserve,
    TUCContactIdentityRepairOn,
};

@property (nonatomic) TUCContactIdentityRepair contactIdentityRepair;


/**
 Hands gestures of two fingers or more to macOS, instead of synthesising them.

 A virtual trackpad is published and the contacts are fed to it, so scrolling, momentum,
 pinch, rotate and the multi-finger swipes are produced by the system rather than imitated
 here — with the inertia and the per-application behaviour of real hardware.

 One finger is untouched by this. It still positions the pointer absolutely, taps, drags
 and holds, because a trackpad moves the pointer relatively and that is the one thing a
 touchscreen must not do.

 Turning it on can fail — the entitlement may be missing, or a future macOS may stop
 accepting the device — in which case it turns itself back off, tells the delegate, and
 everything carries on being synthesised as before. Check `nativeGesturesAreLive` for what
 is actually happening rather than what was asked for.
 */



@property (nonatomic) BOOL usesNativeGestures;

/// Whether the virtual trackpad exists *and* macOS has adopted it. False whenever gestures
/// are being synthesised, whatever `usesNativeGestures` was set to.
@property (readonly) BOOL nativeGesturesAreLive;


/**
 The digitizer a finger last landed on, or 0 if none ever has.

 For putting touch-driven interface where the user's hands are, on a machine with more than one
 panel. Updated once per touch rather than per report, so it describes which glass is being used
 rather than tracking a finger across it.
 */
@property (readonly) uint32_t locationIDOfLastTouch;


- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID;


- (void)triggerSystemAccessibilityAccessAlert;


/**
 A human-readable snapshot intended to be pasted into a bug report: the screens and their
 geometry, how each digitizer resolved to one of them, the active gesture parameters, and the
 full HID discovery transcript.

 Contains only hardware description and settings — no user content — so it is safe to put on
 the clipboard.
 */
- (NSString *)diagnosticsReport;


/**
 A few lines describing what the gesture machinery believes right now, for a live debugging display.

 The state first — what the finger is on, how that was established, what sort of device it came from
 — and then the last handful of decisions, newest last, exactly as the diagnostics report shows them.

 Human-readable and deliberately unstructured: this is for reading while touching the glass, which is
 the only way to see why a gesture went the way it did. Nothing here should be parsed, and nothing
 here is expensive — it formats state that is already being kept, so it is safe to ask on a timer.
 */
- (NSArray<NSString *> *)gestureDebugLines;

@end

NS_ASSUME_NONNULL_END
