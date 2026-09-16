//
//  TUCTouchDelegate.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <TouchUpCore/TUCTouch.h>
#import <TouchUpCore/TUCScreen.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TUCTouchDelegate <NSObject>

#pragma mark - Touch Data
/**
 
 This method is called every time after the `touchSet` was updated
 */
- (void)touchesDidChange;



#pragma mark - Lifecycle

/// `drivesPointer` reports whether the interface is allowed to move the pointer straight away.
/// It is NO for a device that does not declare itself a TouchScreen: its touches are readable
/// and testable, but it stays inert until the user opts in, because a device claiming to be a
/// TouchPad may well be a real trackpad.
- (void)touchscreenDidConnectWithLocationID:(uint32_t)locationID drivesPointer:(BOOL)drivesPointer;
- (void)touchscreenDidDisconnectWithLocationID:(uint32_t)locationID;



#pragma mark - Mouse Control

/**
 Specifies which screen corresponds to the touch screen with the given location ID.
 */
- (nullable TUCScreen *)touchscreenForLocationID:(uint32_t)locationID;

- (CGFloat)digitizerRotationForLocationID:(uint32_t)locationID;

/**
 Whether the digitizer's own axes are mirrored relative to the panel it covers. Applied before
 rotation, since it describes how the glass is wired rather than how the display is oriented.
 Rotation alone cannot express this: all four rotations preserve handedness.
 */
- (BOOL)digitizerIsFlippedHorizontallyForLocationID:(uint32_t)locationID;
- (BOOL)digitizerIsFlippedVerticallyForLocationID:(uint32_t)locationID;


@optional

/**
 Used to customize which mouse events are posted by the input manager.

 Optional, and unimplemented by Touch Up itself. Left alone, the manager applies its own mapping:
 one finger scrolls what it is on and drags what can be dragged, holding still opens the context
 menu, two fingers drag, pinching zooms, and three sweep between desktops. That is the whole
 behaviour of the app, and it lives here rather than in the delegate because there is only one of
 it — a mapping nobody can change does not need a hook to change it through.

 Implement this only to mean something different. Doing so replaces the built-in mapping entirely.
 */
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture;

/**
 The same question as `-actionForGesture:`, with the circumstances the gesture happened in.

 Implement this instead of `-actionForGesture:` to let a gesture mean different things in different
 places — a flick scrolling a list but moving a window by its title bar, a hold selecting text rather
 than opening a menu. The manager's own mapping already does this; implement this to do it
 differently. Implementing it replaces both the built-in mapping and `-actionForGesture:`; the
 manager calls exactly one of the three and never two.

 Two things to know before branching on `context.surface`.

 It is only ever about one finger. A two-finger gesture, or a three-finger sweep, is a gesture of the
 hand and means the same thing wherever it happens: two fingers on a slider still mean scroll. The
 context is supplied for those gestures anyway, so nothing has to be special-cased here, but reading
 it is almost certainly a mistake.

 And it may not be known yet. `context.surfaceState` is `Pending` when a gesture had to be decided
 before an answer arrived, which is a normal outcome rather than an error — the finger has already
 moved and the decision cannot wait. Fall back to whatever the gesture means without the surface;
 do not stall.
 */
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture
                          inContext:(TUCGestureContext *)context;

/**
 A finger landed on a different digitizer than the one before it.

 For interface that should be on the panel the user is actually using. Sent only when the panel
 changes, not per touch and certainly not per report — `-touchesDidChange` is the firehose, and doing
 screen arithmetic there would put it in the path every HID report has to travel.
 */
- (void)lastTouchedDigitizerDidChange:(uint32_t)locationID;


/**
 Native gestures were asked for and could not be had, so everything is being synthesised.

 Sent when the virtual trackpad cannot be published — most often a missing entitlement —
 or when it is published and nothing adopts it, which is what a change to Apple's private
 multitouch protocol would look like. Either way the setting has already turned itself off
 by the time this arrives; the delegate's job is to say so, not to repair it.
 */
- (void)nativeGesturesDidBecomeUnavailable:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END
