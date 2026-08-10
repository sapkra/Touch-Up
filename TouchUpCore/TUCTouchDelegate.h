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

/**
 Used to customize which mouse events are posted by the input manager.
 */
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture;

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
 A finger landed on a different digitizer than the one before it.

 For interface that should be on the panel the user is actually using. Sent only when the panel
 changes, not per touch and certainly not per report — `-touchesDidChange` is the firehose, and doing
 screen arithmetic there would put it in the path every HID report has to travel.
 */
- (void)lastTouchedDigitizerDidChange:(uint32_t)locationID;

@end

NS_ASSUME_NONNULL_END
