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

@end

NS_ASSUME_NONNULL_END
