//
//  TUCCursorUtilities.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import "TUCCursorUtilities.h"
#import <dlfcn.h>
#import <Carbon/Carbon.h> // virtual key codes

@interface TUCCursorUtilities ()

@property NSInteger cursorClickCount;
@property NSDate *timeOfLastClick;
@property CGPoint locationOfLastClick;

@property (readwrite) BOOL isLeftMouseDown;
@property (readwrite) NSTimeInterval timeOfLastSyntheticPointerEvent;
@property (readwrite) CGPoint lastSyntheticPointerLocation;

/// A scroll gesture is open: `kCGScrollPhaseBegan` has been posted and its `Ended` has not.
@property BOOL isScrolling;
/// Smoothed finger speed in points per second, used to seed a flick when the finger lifts.
@property CGPoint scrollVelocity;
@property NSTimeInterval timeOfLastScroll;

/// Speed the flick is currently coasting at, in points per second.
@property CGPoint momentumVelocity;
@property (strong) NSTimer *momentumScrollTimer;

/// Where the drag was last taken. `-currentCursorLocation` cannot be used to release a drag: the
/// moves being released were themselves posted asynchronously, so it can still report a position
/// from before them and drop the drag somewhere the user never went.
@property CGPoint lastDragLocation;

@property BOOL isMagnifying;
@property CGFloat lastPinchDistance;

@end

/// Momentum is stepped at display rate so a flick looks continuous rather than stepped.
static const NSTimeInterval kMomentumFrameInterval = 1.0 / 60.0;

/// Fraction of the speed that survives one momentum step. Tuned for a time constant near 0.3 s,
/// which lands close to how far the system's own flicks carry.
static const CGFloat kMomentumDecayPerFrame = 0.95;

/// Points per second below which a flick is finished. Carrying on past this only smears the last
/// pixel around and delays the gesture ending.
static const CGFloat kMomentumMinimumSpeed = 30.0;

/// Single, double, triple. Nothing in a macOS interface acts on more, and letting the count run
/// past it means a run of taps never produces a plain click again.
static const NSInteger kMaximumClickCount = 3;


@implementation TUCCursorUtilities

+ (TUCCursorUtilities *)sharedInstance {
    static TUCCursorUtilities *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!sharedInstance) {
            sharedInstance = [[TUCCursorUtilities alloc] init];
            sharedInstance.isLeftMouseDown = NO;
            sharedInstance.cursorClickCount = 0;
            sharedInstance.timeOfLastClick = [NSDate dateWithTimeIntervalSince1970:0];
            sharedInstance.locationOfLastClick = CGPointZero;
        }
    });
    return sharedInstance;
}





#pragma mark - Cursor Visibility

/**
 `CGDisplayHideCursor` only takes effect while the calling app is frontmost, which is no use to a
 menu bar app that is never frontmost. The private connection property below is what lets a
 background process hide the pointer system-wide.

 Resolved through `dlsym` and degraded gracefully when absent, the same way `TUCScreen` reaches
 `CoreDisplay_DisplayCreateInfoDictionary` — if it ever disappears, hiding simply becomes
 app-scoped rather than the app failing to launch.
 */
typedef int TUCConnectionID;
typedef TUCConnectionID (*TUCConnectionIDFunc)(void);

/// Four parameters, and the connection is passed twice — once as the caller and once as the target.
/// Getting this wrong does not fail to link or to resolve: the arguments simply land in the wrong
/// registers, and the first thing the function does is retain what it believes is a CFTypeRef.
typedef int32_t (*TUCSetConnectionPropertyFunc)(TUCConnectionID cid,
                                                TUCConnectionID targetCID,
                                                CFStringRef key,
                                                CFTypeRef value);


static void TUCLookUpCursorBackgroundHook(TUCConnectionIDFunc *outConnection,
                                          TUCSetConnectionPropertyFunc *outSetProperty) {
    static TUCConnectionIDFunc connection;
    static TUCSetConnectionPropertyFunc setProperty;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        connection = (TUCConnectionIDFunc)dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
        if (connection == NULL) {
            connection = (TUCConnectionIDFunc)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
        }
        setProperty = (TUCSetConnectionPropertyFunc)dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
    });

    *outConnection = connection;
    *outSetProperty = setProperty;
}


static Boolean TUCCursorBackgroundHookIsAvailable(void) {
    TUCConnectionIDFunc connection = NULL;
    TUCSetConnectionPropertyFunc setProperty = NULL;
    TUCLookUpCursorBackgroundHook(&connection, &setProperty);

    return connection != NULL && setProperty != NULL;
}


static Boolean TUCSetCursorHiddenInBackground(Boolean hidden) {
    TUCConnectionIDFunc connection = NULL;
    TUCSetConnectionPropertyFunc setProperty = NULL;
    TUCLookUpCursorBackgroundHook(&connection, &setProperty);

    if (connection == NULL || setProperty == NULL) {
        return false;
    }

    TUCConnectionID cid = connection();
    if (cid == 0) {
        return false;
    }

    CFBooleanRef value = hidden ? kCFBooleanTrue : kCFBooleanFalse;
    return setProperty(cid, cid, CFSTR("SetsCursorInBackground"), value) == 0;
}


- (BOOL)canHideCursorSystemWide {
    // Availability is answered by whether the symbols resolved, never by making the call. This
    // used to probe by writing the property, which meant simply asking the question — as the
    // diagnostics report does — performed a private API call for no reason.
    return TUCCursorBackgroundHookIsAvailable() ? YES : NO;
}


@synthesize isCursorHidden = _isCursorHidden;

- (void)setIsCursorHidden:(BOOL)isCursorHidden {
    if (_isCursorHidden == isCursorHidden) {
        return;
    }
    _isCursorHidden = isCursorHidden;

    if (isCursorHidden) {
        TUCSetCursorHiddenInBackground(true);
        CGDisplayHideCursor(kCGDirectMainDisplay);
    } else {
        CGDisplayShowCursor(kCGDirectMainDisplay);
        TUCSetCursorHiddenInBackground(false);
    }
}


/**
 Every event Touch Up injects goes out through here, stamped as ours.

 The stamp marks the event as ours, which is what an event tap needs in order not to react to
 input this app produced itself. Routing every post through one place is also the only way to be
 sure a new call site cannot quietly skip it.
 */
- (void)postSyntheticEvent:(CGEventRef)event {
    if (event == NULL) return;

    CGEventSetIntegerValueField(event, kCGEventSourceUserData, kTUCSyntheticEventUserData);

    // Only the events that actually move the pointer count as pointer activity. Scroll and
    // momentum go out through here too, and a flick coasting for a second or more would otherwise
    // look like continuous pointer activity and keep a real mouse from being noticed.
    switch (CGEventGetType(event)) {
        case kCGEventMouseMoved:
        case kCGEventLeftMouseDown:
        case kCGEventLeftMouseUp:
        case kCGEventLeftMouseDragged:
        case kCGEventRightMouseDown:
        case kCGEventRightMouseUp:
            self.timeOfLastSyntheticPointerEvent = [NSDate timeIntervalSinceReferenceDate];
            self.lastSyntheticPointerLocation = CGEventGetLocation(event);
            break;
        default:
            break;
    }

    CGEventPost(kCGHIDEventTap, event);
}


- (NSInteger)lastClickCount {
    return self.cursorClickCount;
}


- (CGPoint)currentCursorLocation {
    CGEventRef dummy = CGEventCreate(NULL);
    CGPoint location = CGEventGetLocation(dummy);
    CFRelease(dummy);
    return location;
}



- (void)moveCursorTo:(CGPoint)aLocation {
    [self cancelMomentumScroll];
    [self stopDraggingCursor];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 0);
    [self postSyntheticEvent:event];
    CFRelease(event);
}



/**
 A pointer left sitting against a screen edge is treated by macOS as someone deliberately pushing
 into it: the auto-hidden Dock slides out, the menu bar drops down in full screen, and a corner
 fires whatever hot corner is assigned. Touching near the bottom of the glass therefore summoned
 the Dock every time, because the pointer was moved there and simply stayed.

 Nudging it inside once the touch is over costs nothing — the click has already been delivered at
 the real position — and it is invisible while the pointer is hidden.

 `location` is where the caller *put* the pointer, not where the pointer is now. Asking the window
 server would be wrong: `CGEventPost` is asynchronous, so a read taken straight after posting a
 move still returns the previous position. Clamping that gave the worst of both — a touch near an
 edge looked central and was left alone, and the next central touch looked like the edge one and
 got dragged back to it, so the Dock appeared wherever you touched.
 */
- (void)parkCursorAt:(CGPoint)location insideFrame:(CGRect)frame {
    // Enough to clear the edge-trigger bands, small enough to stay on whatever was touched.
    const CGFloat inset = 12.0;

    if (CGRectIsEmpty(frame) || CGRectIsNull(frame)) {
        return;
    }

    CGPoint parked = CGPointMake(MAX(CGRectGetMinX(frame) + inset, MIN(CGRectGetMaxX(frame) - inset, location.x)),
                                 MAX(CGRectGetMinY(frame) + inset, MIN(CGRectGetMaxY(frame) - inset, location.y)));

    if (CGPointEqualToPoint(parked, location)) {
        return;
    }

    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, parked, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 0);
    [self postSyntheticEvent:event];
    CFRelease(event);
}



/**
 Posts a complete press and release. Integrated double click support: checks time between
 clicks and spatial distance.

 Both halves are emitted here, at the moment the finger lifts, so a plain tap has no
 press-and-hold phase for an app to observe. That is not an oversight, and moving the press
 to touch-down would break one-finger scrolling: while the finger is still on the glass the
 gesture is genuinely undecided — tap, scroll, pinch and secondary click all start
 identically — and a press that has already been delivered cannot be taken back, so an app
 would begin selecting text the moment the user meant to scroll. The press can only be
 emitted early once the gesture is no longer ambiguous, which is what the hold does; see
 `TUCCursorGestureLongPress` and `-dragCursorTo:phase:`.
 */
- (void)performClickAt:(CGPoint)aLocation {
    [self updateCursorClickCountWithLocation:aLocation];

    // Two purpose-built events rather than one object re-typed and posted twice: that shared
    // a single creation timestamp between the press and the release, so the pair carried a
    // press duration of exactly zero.
    CGEventRef mouseDown = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(mouseDown, kCGMouseEventClickState, self.cursorClickCount);
    [self postSyntheticEvent:mouseDown];
    CFRelease(mouseDown);

    CGEventRef mouseUp = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(mouseUp, kCGMouseEventClickState, self.cursorClickCount);
    [self postSyntheticEvent:mouseUp];
    CFRelease(mouseUp);
}


/**
 Advances the click sequence that gets stamped onto the next mouse event as its click state,
 so that quick repeat presses in the same spot read as a double or triple click.

 A sequence continues only while both conditions hold: the presses follow each other within
 the system's double-click interval, and the new one lands inside `doubleClickTolerance` of
 the previous one. Anything else starts a fresh sequence at 1.

 Held at 3, the highest count macOS interfaces actually act on. Both other options are worse:
 wrapping back to 1 on the fourth press, as this originally did, makes the fifth press look like
 the second press of a new double click and manufactures double clicks nobody asked for. Letting
 it run free, which is what a mouse does, means someone tapping steadily on one spot — exactly
 what testing whether tapping works looks like — climbs to click state 6, 7, 8 and never gets a
 plain single click again. Clamping keeps every event a click something will act on.
 */
- (void)updateCursorClickCountWithLocation:(CGPoint)aLocation {
    ++self.cursorClickCount;

    NSTimeInterval durationSinceLastClick = [[NSDate date] timeIntervalSinceDate:self.timeOfLastClick];

    if (durationSinceLastClick > [NSEvent doubleClickInterval]) {
        self.cursorClickCount = 1;
    }

    // Distance from the previous click, as a radius. This used to compare the two signed
    // axis deltas against the tolerance and require *both* to exceed it, which only ever
    // held for a tap moving down and to the right — so in every other direction two quick
    // taps anywhere on the glass were promoted to a double click. That is easy to trigger on
    // a large touchscreen, where consecutive taps are naturally far apart.
    else if (hypot(aLocation.x - self.locationOfLastClick.x,
                   aLocation.y - self.locationOfLastClick.y) > self.doubleClickTolerance) {
        // touch is too far away
        self.cursorClickCount = 1;
    }

    else if (self.cursorClickCount > kMaximumClickCount) {
        self.cursorClickCount = kMaximumClickCount;
    }

    // Every press that advances the sequence also becomes the reference for the next one.
    // This used to be done by `performClickAt:` alone, so the press that starts a drag
    // consumed a count without moving the reference forward: the window for the following
    // tap was still measured from the click *before* the drag, letting that tap inherit a
    // count it had not earned — tap, drag, tap at one spot arrived as a triple click.
    self.timeOfLastClick = [NSDate date];
    self.locationOfLastClick = aLocation;
}


- (void)performSecondaryClickAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, aLocation, kCGMouseButtonRight);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    [self postSyntheticEvent:event];
    CGEventSetType(event, kCGEventRightMouseUp);
    [self postSyntheticEvent:event];
    CFRelease(event);
}



- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase  {
    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        [self stopDraggingCursor];
        return;
    }
    
    
    self.lastDragLocation = aLocation;

    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        [self postSyntheticEvent:event];
        CFRelease(event);
        
    } else {
        [self moveCursorTo:aLocation];
        [self updateCursorClickCountWithLocation:aLocation];
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        [self postSyntheticEvent:event];
        CFRelease(event);
        
        self.isLeftMouseDown = YES;
    }
}


- (void)stopDraggingCursor {
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, self.lastDragLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        [self postSyntheticEvent:event];
        CFRelease(event);
        
        self.isLeftMouseDown = NO;
    }
}



/**
 Emits one continuous scroll event.

 The phase fields are what make this a scroll *gesture* rather than a mouse wheel tick. Without
 them macOS treats every event as a discrete wheel notch, which costs rubber-band overscroll,
 makes momentum something we have to fake in full, and makes apps that distinguish the two —
 Safari, Maps, Preview — fall back to their wheel behaviour. That is the single biggest reason
 dragging a finger here has never felt like dragging one on a tablet.

 A gesture and a flick are mutually exclusive: momentum events carry `kCGScrollPhaseNone` and
 gesture events carry no momentum phase, which is the convention `CGEventTypes.h` documents.
 */
- (CGEventRef)createContinuousScrollEventWithTranslation:(CGPoint)translation CF_RETURNS_RETAINED {
    // The sign is deliberately the raw screen-space delta, so content follows the finger the way
    // it does on a tablet: drag down and the page comes down with you. This ignores the macOS
    // "Natural scrolling" preference on purpose — on glass you are holding the content, not
    // pushing a scroll wheel, and inverting that never feels right.
    CGEventRef event = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2,
                                                      translation.y, translation.x, 0);
    if (event) {
        CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);
    }
    return event;
}


/// One event of an in-progress gesture. Momentum phase is left at zero: `CGEventTypes.h` treats a
/// gesture event and a momentum event as mutually exclusive.
- (void)postGestureScrollTranslation:(CGPoint)translation phase:(CGScrollPhase)scrollPhase {
    CGEventRef event = [self createContinuousScrollEventWithTranslation:translation];
    if (!event) return;

    CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, scrollPhase);

    [self postSyntheticEvent:event];
    CFRelease(event);
}


/// One event of a flick coasting after the finger has gone. Scroll phase is left at zero, which is
/// how the system distinguishes momentum from a gesture the user is still driving.
- (void)postMomentumScrollTranslation:(CGPoint)translation phase:(CGMomentumScrollPhase)momentumPhase {
    CGEventRef event = [self createContinuousScrollEventWithTranslation:translation];
    if (!event) return;

    CGEventSetIntegerValueField(event, kCGScrollWheelEventMomentumPhase, momentumPhase);

    [self postSyntheticEvent:event];
    CFRelease(event);
}


- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase {
    [self stopDraggingCursor];

    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        [self endScrollGesture];
        return;
    }

    if (!self.isScrolling) {
        // A fresh drag supersedes whatever the previous flick was still coasting through.
        [self cancelMomentumScroll];

        self.isScrolling = YES;
        self.scrollVelocity = CGPointZero;
        [self postGestureScrollTranslation:translation phase:kCGScrollPhaseBegan];
    } else {
        [self postGestureScrollTranslation:translation phase:kCGScrollPhaseChanged];
    }

    // Track speed over time rather than keeping the last delta: reports do not arrive at a fixed
    // rate, and the very last one before the finger leaves the glass is the noisiest there is —
    // seeding a flick from it alone is what makes momentum shoot off or die on the spot.
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval elapsed = now - self.timeOfLastScroll;

    if (elapsed > 0 && elapsed < 0.1) {
        const CGFloat smoothing = 0.35;
        self.scrollVelocity = CGPointMake(self.scrollVelocity.x * (1 - smoothing) + (translation.x / elapsed) * smoothing,
                                         self.scrollVelocity.y * (1 - smoothing) + (translation.y / elapsed) * smoothing);
    }
    self.timeOfLastScroll = now;
}


/**
 Closes an open scroll gesture without handing off a flick, reporting it as cancelled.

 `kCGScrollPhaseCancelled` says exactly what happened: the gesture turned out to be something
 else. A view that receives it settles out of any overscroll instead of waiting for an end that
 is never coming.

 Idempotent, and safe to call after `-endScrollGesture` has already run — which is what makes it
 usable as a catch-all on every path a touch can finish by.
 */
- (void)cancelScrollGesture {
    if (!self.isScrolling) {
        return;
    }

    self.isScrolling = NO;
    self.scrollVelocity = CGPointZero;

    [self postGestureScrollTranslation:CGPointZero phase:kCGScrollPhaseCancelled];
}


- (void)endScrollGesture {
    if (!self.isScrolling) {
        return;
    }
    self.isScrolling = NO;

    [self postGestureScrollTranslation:CGPointZero phase:kCGScrollPhaseEnded];

    CGPoint flickVelocity = self.scrollVelocity;
    self.scrollVelocity = CGPointZero;

    if (hypot(flickVelocity.x, flickVelocity.y) < kMomentumMinimumSpeed) {
        return;
    }

    // macOS does not generate inertia for injected events, so the decay is still ours — but
    // labelled as momentum, a view integrates it as a flick and rubber-bands out of it, instead
    // of receiving a burst of wheel notches.
    self.momentumVelocity = flickVelocity;
    [self postMomentumWithPhase:kCGMomentumScrollPhaseBegin];

    self.momentumScrollTimer = [NSTimer scheduledTimerWithTimeInterval:kMomentumFrameInterval
                                                               target:self
                                                             selector:@selector(updateMomentumScroll)
                                                             userInfo:nil
                                                              repeats:YES];
}


- (void)updateMomentumScroll {
    self.momentumVelocity = CGPointMake(self.momentumVelocity.x * kMomentumDecayPerFrame,
                                        self.momentumVelocity.y * kMomentumDecayPerFrame);

    if (hypot(self.momentumVelocity.x, self.momentumVelocity.y) < kMomentumMinimumSpeed) {
        [self cancelMomentumScroll];
        return;
    }

    [self postMomentumWithPhase:kCGMomentumScrollPhaseContinue];
}


- (void)postMomentumWithPhase:(CGMomentumScrollPhase)momentumPhase {
    CGPoint step = CGPointMake(self.momentumVelocity.x * kMomentumFrameInterval,
                               self.momentumVelocity.y * kMomentumFrameInterval);

    [self postMomentumScrollTranslation:step phase:momentumPhase];
}


- (void)cancelMomentumScroll {
    if (self.momentumScrollTimer == nil) {
        return;
    }

    [self.momentumScrollTimer invalidate];
    self.momentumScrollTimer = nil;
    self.momentumVelocity = CGPointZero;

    // Close the phase. A view left waiting for the end of a flick that has already stopped will
    // not settle back out of an overscroll.
    [self postMomentumScrollTranslation:CGPointZero phase:kCGMomentumScrollPhaseEnd];
}


- (void)magnify:(CGFloat)magnification phase:(NSTouchPhase)phase {
    [self stopDraggingCursor];
    
    if (phase == NSTouchPhaseMoved && magnification == 0) {
        // no reason to post that
        return;
    }
    
    // start with a valid mouse event, as it has a valid timestamp
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, [self currentCursorLocation], kCGMouseButtonLeft);
    
    CGEventSetType(event, 29); // type gesture
    CGEventSetFlags(event, 0);
    
    CGEventSetDoubleValueField(event, 113, magnification);
    CGEventSetDoubleValueField(event, 114, magnification);
    CGEventSetDoubleValueField(event, 116, magnification);
    CGEventSetDoubleValueField(event, 118, magnification);
    
    // magic
//    CGEventSetIntegerValueField(event, 55, 29); //if more touches on trackapd 30? about concurrent gestures???
    CGEventSetIntegerValueField(event, 50, 248);
    CGEventSetIntegerValueField(event, 101, 4);
    CGEventSetIntegerValueField(event, 110, 8);
    
    
    CGGesturePhase gesturePhase = kCGGesturePhaseEnded;
    if (phase == NSTouchPhaseBegan) {
        gesturePhase = kCGGesturePhaseBegan;
    } else if (phase == NSTouchPhaseMoved || phase == NSTouchPhaseStationary) {
        gesturePhase = kCGGesturePhaseChanged;
    }
    
    CGEventSetIntegerValueField(event, 132, phase);
    
    [self postSyntheticEvent:event];
    CFRelease(event);
}


- (void)pressKey:(CGKeyCode)keyCode modifiers:(CGEventFlags)modifiers {
    // An arrow key pressed on a real keyboard carries these two alongside whatever the user is
    // holding, and the system matches its shortcuts against the whole flag set. Without them a
    // synthetic Control-arrow does not match "move left a space", and an unmatched key combination
    // is what makes macOS play the error sound.
    switch (keyCode) {
        case kVK_LeftArrow:
        case kVK_RightArrow:
        case kVK_UpArrow:
        case kVK_DownArrow:
            modifiers |= kCGEventFlagMaskNumericPad | kCGEventFlagMaskSecondaryFn;
            break;
        default:
            break;
    }

    CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventSetFlags(keyDown, modifiers);
    [self postSyntheticEvent:keyDown];
    CFRelease(keyDown);

    CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, keyCode, false);
    CGEventSetFlags(keyUp, modifiers);
    [self postSyntheticEvent:keyUp];
    CFRelease(keyUp);
}


- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2 {
    [self stopDraggingCursor];
    
    NSTouchPhase phase = NSTouchPhaseMoved;
    
    CGFloat dx = r1.x - r2.x;
    CGFloat dy = r1.y - r2.y;
    
    CGFloat distance = sqrt( pow(dx, 2) + pow(dy, 2) );
    CGFloat delta = distance - self.lastPinchDistance;
    
    self.lastPinchDistance = distance;
    
    if (!self.isMagnifying) {
        CGPoint middle = CGPointMake(0.5f * (p1.x + p2.x), 0.5f * (p1.y + p2.y));
        [self moveCursorTo:middle];
        phase = NSTouchPhaseBegan;
        delta = 0;
        self.isMagnifying = YES;
    }
    
    [self magnify:delta * 4 phase:phase];
}


- (void)stopMagnifying {
    if (self.isMagnifying) {
        self.isMagnifying = NO;
        [self magnify:0 phase:NSTouchPhaseEnded];
    }
}

@end
