//
//  TUCCursorUtilities.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Stamped into `kCGEventSourceUserData` on every event Touch Up injects, so our own synthetic
/// input can be told apart from a real mouse or trackpad. Any distinctive value would do.
static const int64_t kTUCSyntheticEventUserData = 0x54554348; // 'TUCH'


@interface TUCCursorUtilities : NSObject

+ (instancetype)sharedInstance;


/**
 Radius, in screen points, within which a follow-up click continues the current click
 sequence instead of starting a new one. Callers own the conversion from a physical
 distance, since points per millimetre differ per screen.

 A non-positive value means no two clicks are ever close enough to form a sequence, i.e. it
 disables double clicking.
 */
@property CGFloat doubleClickTolerance;

/**
 Whether the left button is currently held down, i.e. a drag is in progress. Callers use this
 to tell an already-actuated press from an untouched button, so that releasing a held press
 does not also emit a separate click.
 */
@property (readonly) BOOL isLeftMouseDown;

/**
 Hides or restores the pointer.

 There is no pointer on a tablet, and a pointer that teleports to wherever you touched is the
 clearest reminder that you are driving a mouse by proxy. Hiding it is the single biggest change
 to how direct the glass feels.

 Idempotent, because the underlying CoreGraphics calls are balanced: calling hide twice and show
 once would leave the pointer invisible with no obvious way back.
 */
@property (nonatomic) BOOL isCursorHidden;

/// Whether hiding actually applies system-wide rather than only while Touch Up is frontmost.
/// Reported in the diagnostics so a pointer that stubbornly reappears is explicable.
@property (readonly) BOOL canHideCursorSystemWide;

/// When we last injected an event that moves the pointer, as a `timeIntervalSinceReferenceDate`.
/// Lets a caller recognise the tail of its own activity without relying on the source stamp
/// surviving a round trip through the window server, which cannot be checked from inside.
@property (readonly) NSTimeInterval timeOfLastSyntheticPointerEvent;

/// Click state stamped on the most recent press: 1 single, 2 double, 3 triple. Reported in the
/// diagnostics, because a click arriving as a double is indistinguishable from a click going
/// missing if all you can see is that tapping did not do what you meant.
@property (readonly) NSInteger lastClickCount;

- (CGPoint)currentCursorLocation;

- (void)moveCursorTo:(CGPoint)aLocation;

/**
 Moves the pointer just far enough inside `frame` to stop it resting against an edge, and does
 nothing if `location` is already clear of them.

 Pass where the pointer was last *put*, not a reading of where it is: event posting is
 asynchronous, so a fresh reading can still describe the position before the last move.

 Unlike `-moveCursorTo:` this leaves a running drag or flick alone: it is meant to be called as a
 touch ends, when cancelling the momentum that touch just handed off would be exactly wrong.
 */
- (void)parkCursorAt:(CGPoint)location insideFrame:(CGRect)frame;

- (void)performClickAt:(CGPoint)aLocation;

- (void)performSecondaryClickAt:(CGPoint)aLocation;

/**
 Holds the mouse button down and takes it to `aLocation`, pressing on the first call and releasing
 when the phase ends.

 The press inherits the running click sequence, so holding after a double click selects text by word
 the way it does with a mouse.
 */
- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase;

/**
 As above, but `startingNewClickSequence` forces the press to be a single click.

 For anywhere a repeated click means something other than "the same thing again": a title bar reads
 a click state of 2 as the zoom gesture, so a drag begun just after a tap in the same place resized
 the window rather than moving it.
 */
- (void)dragCursorTo:(CGPoint)aLocation
               phase:(NSTouchPhase)phase
startingNewClickSequence:(BOOL)startsNewSequence;

- (void)stopDraggingCursor;

- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;

/// Closes an open scroll gesture as cancelled, without a flick. Idempotent, so it can be used as a
/// catch-all wherever a touch finishes by a route that did not end the scroll itself.
- (void)cancelScrollGesture;

/**
 Taps a key with modifiers held.

 Used for the whole-system gestures — switching spaces, Mission Control, App Exposé — because
 macOS recognises those from a trackpad's raw multitouch stream inside the window server, not from
 anything an application can post. The shortcuts it already assigns to them are a public, stable
 way to ask for the same thing.
 */
- (void)pressKey:(CGKeyCode)keyCode modifiers:(CGEventFlags)modifiers;

- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2;
- (void)stopMagnifying;


@end

NS_ASSUME_NONNULL_END
