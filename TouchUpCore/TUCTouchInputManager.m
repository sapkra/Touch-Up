//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCCursorUtilities.h"
#import "TUCSurfaceProbe.h"

#import <Carbon/Carbon.h> // key codes for the system navigation shortcuts

@interface TUCTouchInputManager ()

@property NSMutableDictionary<NSNumber *, NSNumber *> *frameIDsByLocationID;

/// How fast each digitizer is actually reporting, sampled over the last window of reports.
///
/// Measured over a fixed count rather than averaged since the device appeared: reports only arrive
/// while a finger is down, so a lifetime average is mostly a measure of how long the screen sat
/// untouched. What is worth knowing is the rate while in use — a panel reporting at 30 Hz and one
/// at 120 Hz feel entirely different and are told apart by nothing else in the diagnostics.
@property NSMutableDictionary<NSNumber *, NSNumber *> *reportRatesByLocationID;
@property NSMutableDictionary<NSNumber *, NSNumber *> *rateWindowStartTimeByLocationID;
@property NSMutableDictionary<NSNumber *, NSNumber *> *rateWindowStartFrameByLocationID;

@property (weak, nullable) TUCTouch *cursorTouch;
@property (weak, nullable) TUCTouch *gestureAdditionalTouch;

@property CGPoint cursorTouchOrigin; // where the cursor touch first landed, in relative screen coordinates
@property BOOL cursorTouchQualifiedForTap; // NO once the cursor touch has travelled further than `tapTolerance` from its origin
@property BOOL cursorTouchDidHold; //
@property CGPoint cursorTouchStationaryAnchor; // reference point the hold clock is measured against
@property (strong) NSDate *cursorTouchStationarySinceDate;
@property BOOL cursorTouchDidActuatePress; // YES once this touch has put the mouse button down
@property BOOL cursorTouchDidActuateLongPress; // YES once this touch has opened a context menu
@property BOOL cursorTouchSawMultipleFingers; // YES if another finger was ever down alongside it
@property NSTimeInterval cursorTouchBeganTime; // when the cursor touch landed, for concurrency tests

/// What the cursor touch landed on, how well that is known, and where it was asked about.
///
/// Every one of these is written on the main thread only — from the adoption block, which is the
/// single place any `cursorTouch*` field is reset, and from `-acceptSurfaceReading:`, which the
/// probe hops back to the main queue to call. Nothing here is ever touched from the probe's own
/// queue, which is what keeps all of it free of locks and atomics.
@property TUCSurfaceKind cursorTouchSurface;
@property TUCSurfaceSource cursorTouchSurfaceSource;
@property TUCSurfaceState cursorTouchSurfaceState;
@property CGPoint cursorTouchSurfaceProbePoint; // relative coordinates, where the probe was fired
@property BOOL cursorTouchSurfaceIsFrozen; // an action has committed; no late answer may change it

/// Rises once per cursor touch, and never resets.
///
/// A probe carries the value it was fired under and its answer is refused unless it still matches.
/// Monotone rather than a "is a touch down" flag because that flag is subject to ABA: a probe fired
/// for one finger, answering after that finger lifted and the next one landed, would find the flag
/// set both times and be applied to the wrong finger. A tap on the desktop followed by a flick on a
/// web page is the ordinary way that happens, not an exotic one.
@property uint64_t surfaceProbeGeneration;

/// Counts behind the surface section of the diagnostics report. Main thread only, like the latch,
/// which is why none of them needs to be atomic: they are only ever touched from
/// `-acceptSurfaceReading:`, and that runs here.
@property NSUInteger surfaceReadingsDelivered;
@property NSUInteger surfaceLateAnswerCount;         // arrived for a finger that had already gone
@property NSUInteger surfaceAnswersInTimeCount;      // arrived before anything had to be decided
@property NSUInteger surfaceLateDisagreementCount;   // arrived after, and contradicted the decision

/// Midpoint of three or more fingers when they were first all down, and whether their sweep has
/// already been acted on.
@property BOOL hasSwipeBaseline;
@property CGPoint swipeBaselineMidpoint;
@property BOOL didRecogniseSwipe;
@property CGFloat swipeFurthestTravel; // mm, for the diagnostics when a sweep never commits
@property CGFloat swipeBaselineSpread; // how far the fingers sat from their midpoint, in mm

/// How many fingers were down when the count last changed, and when. A gesture is only classified
/// once the count has held steady, so fingers still arriving cannot be read as a smaller gesture.
@property NSUInteger settledTouchCount;
@property NSTimeInterval timeOfTouchCountChange;

/// Inter-finger spread and midpoint when the second finger arrived, in mm and relative
/// coordinates. A two-finger gesture is pinch or pan depending on which of the two has moved
/// further since, which is far steadier than comparing per-report directions.
@property BOOL hasTwoFingerBaseline;
@property CGFloat twoFingerBaselineSpread;
@property CGPoint twoFingerBaselineMidpoint;

@property CGFloat pinchDistance;

@property TUCCursorGesture identifiedMultitouchGesture;

/// Keys of observations already written to the diagnostics transcript, so a condition that
/// recurs on every report is recorded once instead of flooding it.
@property NSMutableSet<NSString *> *notedDeviceObservations;

/// Watches for pointer movement that did not come from us, so a real mouse or trackpad brings the
/// pointer back while `hidesCursor` is on.
/// Runs while the pointer is hidden, comparing where it is against where we last observed it to be
/// after moving it ourselves.
@property (strong) NSTimer *pointerWatchTimer;
@property CGPoint expectedPointerLocation;
@property BOOL hasPointerBaseline;

/// The last handful of touches and what each was decided to be. Small and always on: when someone
/// reports that tapping does nothing, this is the difference between reading the code and knowing.
@property NSMutableArray<NSString *> *recentGestureLog;

@property (readwrite) uint32_t locationIDOfLastTouch;

@end


/**
 How far (mm) the finger may wander while the hold clock keeps running. Generous enough to
 absorb digitizer noise and a resting finger's centroid drift, tight enough that a
 deliberate slow drag keeps resetting the clock instead of turning into a hold.
 */
static const CGFloat kHoldStillnessTolerance = 1.0;

/**
 Per-report movement (mm) below which a touch is reported as `NSTouchPhaseStationary`
 rather than `NSTouchPhaseMoved`. Deliberately tiny: this only classifies the phase, and a
 low value keeps slow, fine-grained scrolling responsive. Tap and hold decisions must not
 use it — they are measured against an anchor point, not the previous report.
 */
static const CGFloat kPhaseMovementThreshold = 0.1;

/**
 How close (mm) a second finger has to tap to the resting one to mean a secondary click. Measured
 as a true radius — the old proximity helper normalised each axis separately and then compared
 against the horizontal one, which on a portrait panel stretched the vertical reach by the whole
 aspect ratio.
 */
static const CGFloat kSecondFingerProximity = 60.0;

/**
 How far (mm) a two-finger gesture has to develop before it is called a pinch or a pan. Deciding
 on the first report or two reads mostly noise; waiting until one interpretation is clearly ahead
 costs a few milliseconds and gets it right.
 */
static const CGFloat kTwoFingerCommitDistance = 2.0;

/**
 How far (mm) three or more fingers have to sweep before it counts as a swipe. Generous, because
 the command it fires is disruptive — switching space by accident while resting a hand on the glass
 is far worse than having to sweep a little further.
 */
static const CGFloat kSwipeCommitDistance = 25.0;

/**
 How long after our own last injected pointer event another pointer event is still assumed to be
 ours. Covers the click, the release and the parking nudge, which all land just after the last
 finger has left and so arrive with no touch on the glass to disown them.
 */
static const NSTimeInterval kForeignPointerGracePeriod = 0.2;

/**
 How long the number of fingers has to hold steady before a multi-finger gesture is classified.

 Three fingers never land at the same instant. Without a pause, the two that arrive first are
 classified on their own — and two fingers need only 2 mm of travel to commit — so by the time the
 third lands a two-finger drag has already taken the button down, and the sweep has to start again
 from wherever the fingers had got to. Waiting for the count to settle costs a moment before a pinch
 or a two-finger drag begins and makes the difference between three fingers working and not.
 */
static const NSTimeInterval kFingerCountSettleTime = 0.08;

/**
 How long since its last report a contact is abandoned and no longer treated as a finger on the
 glass.

 `errorResistance` already reaps stale contacts, but it counts *reports*, and the frame counter only
 advances while the device is sending them. A device that goes quiet between touches therefore ages
 nothing out at all, so contacts survive indefinitely — and a wall clock is the only thing that can
 say a finger is gone when nothing is being reported. This is the third distinct bug in this branch
 caused by treating that counter as a measure of time.
 */
static const NSTimeInterval kAbandonedTouchTimeout = 0.5;

/// How often the pointer is checked against where we last put it, while it is hidden. Four times a
/// second costs nothing and is quick enough that reaching for a mouse feels like it just works.
static const NSTimeInterval kPointerWatchInterval = 0.25;

/// How far the pointer has to be from where we last put it to count as somebody else having moved
/// it. A couple of points of slack, since the window server clamps to screen bounds and rounds.
static const CGFloat kPointerMovedTolerance = 3.0;


static NSString *TUCNameForGesture(TUCCursorGesture gesture) {
    switch (gesture) {
        case TUCCursorGestureTouchDown:       return @"TouchDown";
        case TUCCursorGestureTap:             return @"Tap";
        case TUCCursorGestureLongPress:       return @"LongPress";
        case TUCCursorGestureDrag:            return @"Drag";
        case TUCCursorGestureHoldAndDrag:     return @"HoldAndDrag";
        case TUCCursorGestureTapSecondFinger: return @"SecondFingerTap";
        case TUCCursorGestureTwoFingerDrag:   return @"TwoFingerDrag";
        case TUCCursorGesturePinch:           return @"Pinch";
        case TUCCursorGestureSwipeLeft:       return @"SwipeLeft";
        case TUCCursorGestureSwipeRight:      return @"SwipeRight";
        case TUCCursorGestureSwipeUp:         return @"SwipeUp";
        case TUCCursorGestureSwipeDown:       return @"SwipeDown";
        case _TUCCursorGestureNone:           return @"None";
    }
    return @"?";
}

static NSString *TUCNameForSurface(TUCSurfaceKind surface) {
    switch (surface) {
        case TUCSurfaceKindUnknown:      return @"?";
        case TUCSurfaceKindDesktop:      return @"desktop";
        case TUCSurfaceKindWindowChrome: return @"chrome";
        case TUCSurfaceKindScrollArea:   return @"scrollArea";
        case TUCSurfaceKindControl:      return @"control";
        case TUCSurfaceKindTextArea:     return @"textArea";
        case TUCSurfaceKindContent:      return @"content";
    }
    return @"?";
}

static NSString *TUCNameForSurfaceSource(TUCSurfaceSource source) {
    switch (source) {
        case TUCSurfaceSourceNone:       return @"not asked";
        case TUCSurfaceSourceWindowList: return @"windowlist";
        case TUCSurfaceSourceAXElement:  return @"ax";
    }
    return @"?";
}

static NSString *TUCNameForSurfaceState(TUCSurfaceState state) {
    switch (state) {
        case TUCSurfaceStateNone:        return @"off";
        case TUCSurfaceStatePending:     return @"pending";
        case TUCSurfaceStateKnown:       return @"known";
        case TUCSurfaceStateUnavailable: return @"unavailable";
    }
    return @"?";
}

static NSString *TUCNameForAction(TUCCursorAction action) {
    switch (action) {
        case TUCCursorActionNone:               return @"nothing";
        case TUCCursorActionMove:               return @"move";
        case TUCCursorActionMoveClickIfNeeded:  return @"move+raise";
        case TUCCursorActionPointAndClick:      return @"point&click";
        case TUCCursorActionDrag:               return @"drag";
        case TUCCursorActionClick:              return @"CLICK";
        case TUCCursorActionSecondaryClick:     return @"right-click";
        case TUCCursorActionScroll:             return @"scroll";
        case TUCCursorActionMagnify:            return @"magnify";
        case TUCCursorActionSpacePrevious:      return @"space-";
        case TUCCursorActionSpaceNext:          return @"space+";
        case TUCCursorActionMissionControl:     return @"mission-control";
        case TUCCursorActionApplicationWindows: return @"app-windows";
    }
    return @"?";
}


@implementation TUCTouchInputManager

#pragma mark   Start & Stop

- (void)start {
    
    __weak id weakSelf = self;
    
    // needs to run on main anyway
//    [NSThread detachNewThreadWithBlock:^{
//        [NSThread setThreadPriority:1];
    OpenHIDManager((__bridge void *)(weakSelf));
//    }];
    
}

- (void)stop {
    CloseHIDManager();
}

- (void)setTouchscreensSeized:(BOOL)seized {
    SetTouchDevicesSeized(seized);
}

#pragma mark - Cursor Visibility

/**
 Hiding the pointer is easy. Knowing when to bring it back is the whole problem, and it has now been
 attempted three ways:

 1. A source stamp on our own injected events, filtered in a global event monitor. The stamp does
    survive being read back through `NSEvent` — that much is measurable — but whether it survives the
    round trip out through the window server and back into a monitor cannot be established from
    inside this process. When it did not, every move we made looked foreign and the pointer flickered
    on and off through every touch.
 2. The other device's own HID reports. A trackpad is refused before registration, by vendor and by
    transport, precisely because driving one is the thing that must never happen — so its input never
    arrives here at all, and the device that prompted the feature is the one device that mechanism
    could never see.
 3. Watching where the pointer actually is. Which is this, because it is the only signal in reach
    that depends on nothing being delivered to anybody: we know where we last put the pointer, and if
    it is somewhere else then something else moved it. True of a trackpad, a mouse, another app
    warping it, anything.
 */

@synthesize hidesCursor = _hidesCursor;

- (void)setHidesCursor:(BOOL)hidesCursor {
    _hidesCursor = hidesCursor;

    [[TUCCursorUtilities sharedInstance] setIsCursorHidden:hidesCursor];
    [self logGesture:hidesCursor ? @"pointer hidden (setting on)" : @"pointer shown (setting off)"];

    if (hidesCursor) {
        [self startWatchingPointerPosition];
    } else {
        [self stopWatchingPointerPosition];
    }
}


/**
 Runs for as long as the pointer is hidden — the invariant being that a hidden pointer always has
 something watching for the input that should bring it back.

 It used to be started only when a touch hid the pointer, which left the case that actually gets hit
 first completely uncovered: switching the setting on hides the pointer straight away, so until the
 glass had been touched at least once nothing was watching, and a trackpad had no way to reveal it.
 */
- (void)startWatchingPointerPosition {
    if (self.pointerWatchTimer != nil) {
        return;
    }

    self.hasPointerBaseline = NO;

    __weak typeof(self) weakSelf = self;
    self.pointerWatchTimer = [NSTimer scheduledTimerWithTimeInterval:kPointerWatchInterval
                                                            repeats:YES
                                                              block:^(NSTimer *timer) {
        [weakSelf checkWhetherSomethingElseMovedThePointer];
    }];
}


- (void)stopWatchingPointerPosition {
    [self.pointerWatchTimer invalidate];
    self.pointerWatchTimer = nil;
    self.hasPointerBaseline = NO;
}


- (void)checkWhetherSomethingElseMovedThePointer {
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];

    if (!self.hidesCursor || !utils.isCursorHidden) {
        [self stopWatchingPointerPosition];
        return;
    }

    CGPoint current = [utils currentCursorLocation];

    // While we are the ones moving it, whatever the pointer is doing is ours by definition. That
    // covers a touch in progress, and for a moment afterwards the click, the release and the parking
    // nudge, which all land just after the last finger has gone.
    NSTimeInterval sinceOurLastMove = [NSDate timeIntervalSinceReferenceDate]
        - utils.timeOfLastSyntheticPointerEvent;
    BOOL weAreMovingIt = [self hasActiveTouchOnPointerDrivingDigitizer]
                      || sinceOurLastMove < kForeignPointerGracePeriod;

    // Baselining from where the pointer is observed to be, rather than from the coordinate we asked
    // for, is what makes this trustworthy: the window server clamps and rounds what it is given, so a
    // requested position can differ from the real one and read as somebody else's move.
    if (weAreMovingIt || !self.hasPointerBaseline) {
        self.hasPointerBaseline = YES;
        self.expectedPointerLocation = current;
        return;
    }

    if (hypot(current.x - self.expectedPointerLocation.x,
              current.y - self.expectedPointerLocation.y) <= kPointerMovedTolerance) {
        return;
    }

    [utils setIsCursorHidden:NO];
    [self logGesture:@"pointer shown (something else moved it)"];
    [self stopWatchingPointerPosition];
}


- (BOOL)hasActiveTouchOnPointerDrivingDigitizer {
    for (TUCTouch *touch in [self activeTouches]) {
        if (TouchDeviceDrivesPointer(touch.locationID)) {
            return YES;
        }
    }
    return NO;
}


- (void)setDigitizerDrivesPointer:(BOOL)drivesPointer forLocationID:(uint32_t)locationID {
    SetTouchDeviceDrivesPointer(locationID, drivesPointer);
}

- (BOOL)digitizerDrivesPointerForLocationID:(uint32_t)locationID {
    return TouchDeviceDrivesPointer(locationID);
}


- (TUCDigitizerKind)digitizerKindForLocationID:(uint32_t)locationID {
    switch (TouchDeviceHIDPrimaryUsage(locationID)) {
        case kHIDUsage_Dig_TouchScreen: return TUCDigitizerKindTouchScreen;
        case kHIDUsage_Dig_TouchPad:    return TUCDigitizerKindTouchPad;
        case kHIDUsage_Dig_Digitizer:   return TUCDigitizerKindDigitizer;
        default:                        return TUCDigitizerKindUnknown;
    }
}


static NSString *TUCNameForDigitizerKind(TUCDigitizerKind kind) {
    switch (kind) {
        case TUCDigitizerKindTouchScreen: return @"TouchScreen";
        case TUCDigitizerKindTouchPad:    return @"TouchPad";
        case TUCDigitizerKindDigitizer:   return @"Digitizer";
        case TUCDigitizerKindUnknown:     return @"nothing it would name";
    }
    return @"?";
}


- (void)didConnectTouchscreenWithLocationID:(uint32_t)locationID drivesPointer:(BOOL)drivesPointer {
    self.frameIDsByLocationID[@(locationID)] = @0;
    [self.delegate touchscreenDidConnectWithLocationID:locationID drivesPointer:drivesPointer];
}

- (void)didDisconnectTouchscreenWithLocationID:(uint32_t)locationID {
    // A touch in progress on this digitizer will never get its lift-off report, and stale
    // touches are only reaped as further reports come in — which they now never will. Release
    // whatever it was holding here, or the button stays down for good.
    if (self.cursorTouch != nil && self.cursorTouch.locationID == locationID) {
        [self stopCurrentGesture];
    }

    [self.frameIDsByLocationID removeObjectForKey:@(locationID)];
    [self.reportRatesByLocationID removeObjectForKey:@(locationID)];
    [self.rateWindowStartFrameByLocationID removeObjectForKey:@(locationID)];
    [self.rateWindowStartTimeByLocationID removeObjectForKey:@(locationID)];
    [self.delegate touchscreenDidDisconnectWithLocationID:locationID];
}



#pragma mark - Reacting to HID Events

- (NSInteger)currentFrameIDForLocationID:(uint32_t)locationID {
    return self.frameIDsByLocationID[@(locationID)].integerValue;
}

- (void)didProcessReportForLocationID:(uint32_t)locationID {
    // go through all touches: if the frame is not the latest one, the touch might be old and should be removed.
    NSInteger currentFrameID = [self currentFrameIDForLocationID:locationID];

    for (TUCTouch *touch in self.touchSet) {
        if (touch.locationID != locationID) continue;

        BOOL missedTooManyReports = touch.lastUpdated + self.errorResistance < currentFrameID;

        if (missedTooManyReports || [self hasTouchBeenAbandoned:touch]) {
            [touch setPhase:NSTouchPhaseCancelled];
            [self removeTouch:touch now:NO];
        }
    }

    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }

    self.frameIDsByLocationID[@(locationID)] = @(currentFrameID + 1);

    [self updateReportRateForLocationID:locationID atFrame:currentFrameID];

    [self processTouchesForCursorInput];

}


/**
 Recomputes a digitizer's reporting rate once every `kRateWindowReports` reports.

 Two dictionary reads and a subtraction on the report path, and only on one report in sixty. The
 whole point of the figure is to characterise the device, so paying anything noticeable per report to
 obtain it would be measuring the cost of the measurement.

 A window that spans a gap between two separate touches reports a uselessly low rate — the finger was
 off the glass for most of it. Rather than track liveness, discard any window longer than a couple of
 seconds and start again: a window that long cannot have been continuous at any plausible rate.
 */
- (void)updateReportRateForLocationID:(uint32_t)locationID atFrame:(NSInteger)currentFrameID {
    static const NSInteger kRateWindowReports = 60;
    static const NSTimeInterval kMaxPlausibleWindow = 2.0;

    NSNumber *key = @(locationID);
    NSNumber *startFrame = self.rateWindowStartFrameByLocationID[key];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (startFrame == nil) {
        self.rateWindowStartFrameByLocationID[key] = @(currentFrameID);
        self.rateWindowStartTimeByLocationID[key] = @(now);
        return;
    }

    NSInteger elapsedReports = currentFrameID - startFrame.integerValue;
    if (elapsedReports < kRateWindowReports) {
        return;
    }

    NSTimeInterval elapsed = now - self.rateWindowStartTimeByLocationID[key].doubleValue;
    if (elapsed > 0 && elapsed <= kMaxPlausibleWindow) {
        self.reportRatesByLocationID[key] = @(elapsedReports / elapsed);
    }

    self.rateWindowStartFrameByLocationID[key] = @(currentFrameID);
    self.rateWindowStartTimeByLocationID[key] = @(now);
}


/**
 Records something learned about a digitizer while interpreting its touches, at most once per
 device per `key`. These conditions are per-report by nature, so they would otherwise fill the
 transcript — but they are exactly what turns "my taps do nothing" into an answer, so they
 belong in the report a user pastes into an issue.
 */
/// Appends to the rolling record of what gestures were produced, oldest dropped.
- (void)logGesture:(NSString *)entry {
    [self.recentGestureLog addObject:entry];

    static const NSUInteger kMaxEntries = 24;
    if (self.recentGestureLog.count > kMaxEntries) {
        [self.recentGestureLog removeObjectsInRange:NSMakeRange(0, self.recentGestureLog.count - kMaxEntries)];
    }
}


- (void)noteOnceForLocationID:(uint32_t)locationID key:(NSString *)key message:(NSString *)message {
    NSString *identity = [NSString stringWithFormat:@"%u/%@", locationID, key];
    if ([self.notedDeviceObservations containsObject:identity]) {
        return;
    }
    [self.notedDeviceObservations addObject:identity];

    NSString *line = [NSString stringWithFormat:@"note: digitizer %#010x %@", locationID, message];
    LogToHIDDiagnostics(line.UTF8String);
}


- (void)stopCurrentGesture {
    [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    [[TUCCursorUtilities sharedInstance] stopMagnifying];

    self.identifiedMultitouchGesture = _TUCCursorGestureNone;
    self.hasTwoFingerBaseline = NO;

    if (self.hasSwipeBaseline && !self.didRecogniseSwipe) {
        [self logGesture:[NSString stringWithFormat:
                          @"  no sweep: furthest %.0f mm of the %.0f mm needed",
                          self.swipeFurthestTravel, kSwipeCommitDistance]];
    }

    self.hasSwipeBaseline = NO;
    self.didRecogniseSwipe = NO;
    self.swipeFurthestTravel = 0;
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    
    // A report at the exact origin is the erroneous data `ignoreOriginTouches` exists for — but
    // only while the finger is still on the glass. A lift-off report is about the finger being
    // gone, not about where it is, and plenty of digitizers zero their coordinates to say so.
    //
    // Dropping it strands the touch: it never reaches NSTouchPhaseEnded, goes stale after
    // `errorResistance` reports and is cancelled instead, so the tap the user just made produces
    // no click at all — only the cursor move from touch-down. Turning the option on to fix
    // spurious touches therefore broke clicking for exactly the devices that need it.
    BOOL isOriginReport = CGPointEqualToPoint(digitizerPoint, CGPointZero);
    BOOL isSuspectOriginReport = self.ignoreOriginTouches && isOriginReport;

    if (isSuspectOriginReport && isOnSurface) {
        [self noteOnceForLocationID:locationID
                               key:@"origin-noise-dropped"
                           message:@"reports occasional touches at the exact origin while a finger "
                                    "is down. Ignore Origin Touches is on, so they are being dropped."];
        return;
    }

    // The same reports with the option off are not harmless, and this is the single most useful
    // thing this transcript can say. A spurious origin report is processed like a real move, so the
    // touch appears to leap to the very corner of the screen: that is further than the tap zone, so
    // the tap is disqualified and produces no click, and the pointer lands in the top-left corner
    // where it trips the menu bar and hot corners. From the outside it looks like clicking is
    // broken and the Dock appears at random, with nothing connecting either to a setting.
    if (isOriginReport && isOnSurface && !self.ignoreOriginTouches) {
        [self noteOnceForLocationID:locationID
                               key:@"origin-noise-processed"
                           message:@"is reporting touches at the exact origin while a finger is "
                                    "down, and Ignore Origin Touches is OFF. Each one moves the "
                                    "touch to the corner of the screen, which disqualifies the tap "
                                    "so it never clicks, and throws the pointer into the top-left "
                                    "corner. TURN ON Ignore Origin Touches."];
    }

    // Only the digitizer that drives the pointer may hide it. A finger arriving on any *other*
    // digitizer is a pointing device being used, so it does the opposite and brings the pointer
    // back — which is the whole answer for a built-in trackpad, since matching was broadened to
    // include devices that call themselves trackpads and its reports come through here too.
    //
    // Deciding this from the HID reports we already receive needs nothing to be inferred: no
    // guessing whether an event came from us, no monitor that has to be delivered to. Cheap to do
    // per report, since the setter is a no-op unless the state actually changes.
    if (self.hidesCursor && isOnSurface) {
        BOOL isTheTouchscreen = TouchDeviceDrivesPointer(locationID);
        [[TUCCursorUtilities sharedInstance] setIsCursorHidden:isTheTouchscreen];

        if (isTheTouchscreen) {
            [self startWatchingPointerPosition];
        }
    }

    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];

    // Keep the last known position when the lift-off report has none to give. The click this tap
    // is about to produce is posted at `touch.location`, so taking the reported zeroes would put
    // it in the top-left corner of the screen.
    if (!isSuspectOriginReport) {
        // Recorded from the same starting point the conversion uses, so the two cannot disagree
        // about which space a measurement was taken in.
        [touch setUncorrectedGlassLocation:[self mirrorDigitizerPoint:digitizerPoint locationID:locationID]];
        [touch setLocation:[self convertDigitizerPointToRelativeScreenPoint:digitizerPoint locationID:locationID]];
    } else {
        [self noteOnceForLocationID:locationID
                               key:@"zeroed-lift"
                           message:@"reports zeroed coordinates on lift-off; keeping the last known position. "
                                    "This is the report `ignoreOriginTouches` used to discard, which left taps unable to click."];
    }

    // Which glass is being used, for interface that should follow the user's hands. Set from the
    // same condition as the cursor touch below rather than from every report: a finger travelling
    // across a panel is one touch, and a contact that is already gone tells us nothing about where
    // anybody is.
    if (isNewTouch && isOnSurface && self.locationIDOfLastTouch != locationID) {
        self.locationIDOfLastTouch = locationID;

        if ([self.delegate respondsToSelector:@selector(lastTouchedDigitizerDidChange:)]) {
            [self.delegate lastTouchedDigitizerDidChange:locationID];
        }
    }

    // A contact that is already gone the first time we see it has no position worth anything and
    // must never become the touch that drives the cursor.
    if (isNewTouch && isOnSurface && (self.cursorTouch == nil || !self.cursorTouch.isActive)) {
        self.cursorTouch = touch;
        self.cursorTouchOrigin = touch.location;
        self.cursorTouchQualifiedForTap = YES;
        self.cursorTouchDidHold = NO;
        self.cursorTouchDidActuatePress = NO;
        self.cursorTouchDidActuateLongPress = NO;
        self.cursorTouchSawMultipleFingers = NO;
        self.cursorTouchBeganTime = [NSDate timeIntervalSinceReferenceDate];
        self.cursorTouchStationaryAnchor = touch.location;
        self.cursorTouchStationarySinceDate = [NSDate date];

        // A new finger is a new question. Bumping the generation here is also what disowns any
        // answer still in flight for the finger before this one.
        // Told to the probe as well, so anything still queued for the previous finger discovers it is
        // unwanted when its turn comes and gives up without troubling another application.
        //
        // Guarded, not merely cheap-when-off: the first message to `TUCSurfaceProbe` is what brings
        // the class to life, along with its queue and the notifications it watches to know when what
        // it remembers has gone stale. Somebody who never turns this on should never pay for any of
        // that, and unconditionally naming the class here would have them pay on their first touch.
        self.surfaceProbeGeneration++;
        if (self.classifiesSurfaces) {
            [TUCSurfaceProbe noteCurrentGeneration:self.surfaceProbeGeneration];
        }

        self.cursorTouchSurface = TUCSurfaceKindUnknown;
        self.cursorTouchSurfaceSource = TUCSurfaceSourceNone;
        self.cursorTouchSurfaceState = TUCSurfaceStateNone;
        self.cursorTouchSurfaceProbePoint = touch.location;
        self.cursorTouchSurfaceIsFrozen = NO;
    }

    [touch setIsOnSurface:isOnSurface];
    [touch setConfidenceFlag:confidenceFlag];
    [touch setLastUpdated:[self currentFrameIDForLocationID:locationID]];
    [touch setLastUpdatedTime:[NSDate timeIntervalSinceReferenceDate]];
    
    if (!isOnSurface) {
        [touch setPhase: NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
        [self.delegate touchesDidChange];
        return;
        
    }
    
    if(touch.previousPhase != NSTouchPhaseEnded && !isNewTouch) {
        // update to an existing touch... check if stationary or not
        TUCScreen *screen = [self touchscreenForLocationID:locationID];
        CGFloat stepDistance = [screen millimetreDistanceBetweenRelativePoint:touch.location
                                                                          and:touch.previousLocation];

        if (touch.uuid == self.cursorTouch.uuid) {
            [self updateTapAndHoldStateForCursorTouch:touch onScreen:screen];
        }

        [touch setPhase:(stepDistance < kPhaseMovementThreshold) ? NSTouchPhaseStationary : NSTouchPhaseMoved];
    }
    
    
    [self.delegate touchesDidChange];
    
    return;
}


- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withSize:(CGSize)size azimuth:(CGFloat)azimuth {
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];
    [touch setLastUpdated:[self currentFrameIDForLocationID:locationID]];
    
    [touch setSize:size];
    [touch setAzimuth:azimuth];
}



#pragma mark - Mouse Cursor Management


/**
 Re-evaluates the two movement-dependent decisions about the cursor touch — is it still a
 tap, and is it still being held in place — after every report.

 Both are measured against an anchor point rather than against the previous report. Doing
 it per report made them hair-trigger: a few tenths of a millimetre of digitizer noise, or
 the way the reported contact centroid shifts while a finger flattens onto the glass, was
 enough to permanently disqualify the tap. On panels noisy enough to cross that line every
 tap degraded into a drag, so touching an item only moved the cursor there and never
 clicked it — and hold-and-drag could never arm either.
 */
/**
 How far the finger may wander and still be a tap, for the surface it is actually on.

 The tap slop exists to stop noise turning every tap into a drag, and on ordinary content a couple of
 millimetres of it costs nothing. On a title bar or a slider it costs something visible: the window
 or the thumb does not move until the finger has already travelled, which reads as the control being
 stuck and then jumping to catch up.

 The floor is `kHoldStillnessTolerance`'s value, for the same reason that constant has it — it is the
 smallest radius that still absorbs a finger settling onto the glass. And it is a floor rather than a
 replacement, so a user who raised the tolerance because their panel is noisy keeps the benefit of
 having done so.
 */
static const CGFloat kDirectManipulationTolerance = 1.0;

- (CGFloat)effectiveTapTolerance {
    switch (self.cursorTouchSurface) {
        case TUCSurfaceKindWindowChrome:
        case TUCSurfaceKindControl:
            // Whatever established it. This used to insist on an answer from the element itself,
            // which a title bar can never provide — so the one surface most in need of a tight slop
            // was the one that never got it.
            return MIN(self.tapTolerance, kDirectManipulationTolerance);

        default:
            return self.tapTolerance;
    }
}


- (void)updateTapAndHoldStateForCursorTouch:(TUCTouch *)touch onScreen:(TUCScreen *)screen {

    // A touch stays a tap until the finger leaves a slop radius around where it landed.
    // Once it has left, it can never become a tap again.
    if (self.cursorTouchQualifiedForTap
        && [screen millimetreDistanceBetweenRelativePoint:touch.location and:self.cursorTouchOrigin] > [self effectiveTapTolerance]) {

        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;
    }

    // The hold clock runs for as long as the finger stays near its anchor. Wandering off
    // re-anchors and restarts it, so a slow, deliberate drag never accumulates enough
    // stillness to be mistaken for a hold.
    if ([screen millimetreDistanceBetweenRelativePoint:touch.location and:self.cursorTouchStationaryAnchor] > kHoldStillnessTolerance) {
        self.cursorTouchStationaryAnchor = touch.location;

        if (self.cursorTouchQualifiedForTap) {
            self.cursorTouchStationarySinceDate = [NSDate date];
        }
    }
}


/**
 Promotes the cursor touch to a hold once it has stayed put for `holdDuration`.
 Evaluated on every report regardless of phase: on a noisy digitizer the phase flickers
 between moved and stationary, and a hold must not depend on catching a stationary one.

 Recognising the hold deliberately emits nothing by itself. Holding still is how a tablet asks
 for a context menu, and it is also how it asks to pick something up — which of the two it turns
 out to be is only known once the finger either moves or leaves, so both decisions belong at
 lift-off. Pressing the mouse button here instead, which is what this used to do, commits to the
 drag before the user has said anything.
 */
- (void)updateHoldState {
    if (self.cursorTouchDidHold
        || !self.cursorTouchQualifiedForTap
        || self.cursorTouchStationarySinceDate == nil) {
        return;
    }

    if ([[NSDate date] timeIntervalSinceDate:self.cursorTouchStationarySinceDate] <= self.holdDuration) {
        return;
    }

    self.cursorTouchDidHold = YES;

    // Fire it here, with the finger still down, rather than waiting for the lift. A tablet opens
    // the menu under your finger while you hold, and that feedback is the point: without it you
    // hold, see nothing, and only discover on release whether you got a click or a menu.
    TUCCursorAction holdAction = [self actionForGesture:TUCCursorGestureLongPress];
    if (holdAction == TUCCursorActionNone) {
        return;
    }

    [self performMouseEventForGesture:TUCCursorGestureLongPress];

    // Only a menu spends the touch. Once one is open, anything further from the same finger is
    // ignored — the way to choose from a menu is to tap an item, exactly as with a real
    // right-click.
    //
    // A hold that took the mouse *button* down has not finished: the movement after it is the drag
    // it just armed, which is how text gets selected and how something gets picked up. Latching
    // both cases as spent — which is what this used to do — meant the advice in this method's own
    // documentation, to map the hold to a drag and hold the button while the finger rests, pressed
    // the button and then froze the finger, because `processTouchesForCursorInput` reads this latch
    // to suppress all further movement.
    self.cursorTouchDidActuateLongPress = (holdAction == TUCCursorActionSecondaryClick);
}


/**
 Works out what the cursor touch landed on, as far as can be done without leaving this thread.

 Runs once per touch, at touchdown. Never per report.

 The window list is a synchronous round trip to the window server: measured at roughly 0.6 ms with
 fifty windows open, plus about 5 ms the first time, before the connection is warm. Once per finger
 that is nothing, and it is the same cost `-applicationToRaiseForPoint:` already pays on this path.
 Once per *report* it would be several milliseconds of added latency on every movement of every
 finger, which reads as the whole driver being sluggish and would be very hard to attribute back
 to here.
 */
- (void)classifySurfaceForCursorTouch {
    if (!self.classifiesSurfaces) {
        return;
    }

    TUCTouch *touch = self.cursorTouch;
    if (touch == nil) {
        return;
    }

    // With no screen resolved, `convertScreenPointRelativeToAbsolute:` has nothing to convert
    // against and the point it returns describes nowhere. Classifying it would report confident
    // nonsense about a random place on a random display.
    if ([self touchscreenForLocationID:touch.locationID] == nil) {
        return;
    }

    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:touch.location
                                                            locationID:touch.locationID];

    self.cursorTouchSurface = [self windowSurfaceForPoint:screenLocation
                                              locationID:touch.locationID];
    self.cursorTouchSurfaceSource = TUCSurfaceSourceWindowList;
    self.cursorTouchSurfaceProbePoint = touch.location;

    // The window list cannot see inside a window, so anything it could not name is still an open
    // question that something slower may yet answer. Anything it *did* name, it named for certain.
    self.cursorTouchSurfaceState = (self.cursorTouchSurface == TUCSurfaceKindUnknown)
        ? TUCSurfaceStatePending
        : TUCSurfaceStateKnown;

    // Nothing under the point is the one thing the window list is the final authority on, and it
    // established it without talking to anybody. Asking again could only be slower and less certain.
    if (self.cursorTouchSurface == TUCSurfaceKindDesktop) {
        return;
    }

    // Everything else goes to the slow half — including a title bar the geometry thinks it found,
    // because a guess from a rectangle is not enough to start dragging a window with, and only the
    // element itself can promote it.
    // State is left as the window list set it. A title bar it recognised really is known — just not
    // well enough to press the mouse button on, which is what `surfaceSource` is for. Calling it
    // Pending here would be saying the surface is unknown while naming it in the same breath.
    uint64_t generation = self.surfaceProbeGeneration;
    NSUUID *touchID = touch.uuid;
    __weak TUCTouchInputManager *weakSelf = self;

    TUCSurfaceProbeRequest *request =
        [[TUCSurfaceProbeRequest alloc] initWithScreenPoint:screenLocation
                                                generation:generation
                                                   touchID:touchID];

    [TUCSurfaceProbe probeSurfaceForRequest:request completion:^(TUCSurfaceReading *reading) {
        [weakSelf acceptSurfaceReading:reading];
    }];
}


/**
 How far (mm) the finger may have travelled since a probe was fired for its answer to still be about
 anywhere useful.

 Much larger than `tapTolerance`, and not a re-probing threshold: the job is only to refuse an answer
 about a place the finger has plainly left. "The answer came back about somewhere I had already moved
 away from" is the exact shape a misclassification report takes, which is why it is logged rather than
 dropped silently.
 */
static const CGFloat kSurfaceProbeStaleDistance = 10.0;


/**
 Takes delivery of a probe's answer. Main thread only — the probe hops back here to call it.

 This latches and does not decide. Every gesture decision in this class runs once per report against a
 consistent set of state, and a second path that could commit a gesture from outside the report stream
 is precisely the shape of the bug that once let a finished touch re-enter the lift-off branch and
 emit its tap a second time. So: store the answer, and let the next report use it.
 */
- (void)acceptSurfaceReading:(TUCSurfaceReading *)reading {
    self.surfaceReadingsDelivered++;

    // The finger this was about has lifted, or the next one has already landed. Applying it now would
    // classify the current finger by where the previous one happened to be.
    if (reading.generation != self.surfaceProbeGeneration) {
        self.surfaceLateAnswerCount++;
        return;
    }

    // A probe that could not read anything must not overwrite what the window list established. It
    // does settle the question of whether waiting would help, though: it would not.
    if (reading.surface == TUCSurfaceKindUnknown) {
        // Only downgrades a question that was still open. If the window list named this surface, that
        // answer stands — the probe failing to add detail is not evidence against it.
        if (self.cursorTouchSurface == TUCSurfaceKindUnknown) {
            self.cursorTouchSurfaceState = TUCSurfaceStateUnavailable;
        }
        [self logGesture:[NSString stringWithFormat:@"  probe: nothing readable after %.0f ms (AXError %d)",
                          reading.latency * 1000.0, (int)reading.error]];
        return;
    }

    // First real answer wins. A second could only be about a different place.
    if (self.cursorTouchSurfaceSource == TUCSurfaceSourceAXElement) {
        return;
    }

    // `Content` is the weakest thing a probe can conclude: it means the tree above the finger held
    // nothing in particular. That is worth having when nothing else is known, and worth nothing
    // against an answer the window list already gave — so it fills in, and never overwrites.
    //
    // On a title bar it is not even a disagreement. Most applications put no element there at all, so
    // the walk starts at the window itself, matches nothing, reaches the top and reports `Content`;
    // finding no content is precisely what being on the frame of a window looks like. Letting that
    // replace `WindowChrome` is what stopped windows being draggable: the geometric answer was
    // correct, and the probe threw it away for a vaguer one meaning "use the setting".
    //
    // Specific answers still win. A search field in a toolbar is a search field.
    if (reading.surface == TUCSurfaceKindContent
        && self.cursorTouchSurface != TUCSurfaceKindUnknown) {
        [self logGesture:[NSString stringWithFormat:
                          @"  probe: content after %.0f ms, keeping %@",
                          reading.latency * 1000.0, TUCNameForSurface(self.cursorTouchSurface)]];
        return;
    }

    TUCTouch *touch = self.cursorTouch;
    TUCScreen *screen = touch ? [self touchscreenForLocationID:touch.locationID] : nil;
    if (screen != nil) {
        CGFloat travelled = [screen millimetreDistanceBetweenRelativePoint:touch.location
                                                                      and:self.cursorTouchSurfaceProbePoint];
        if (travelled > kSurfaceProbeStaleDistance) {
            [self logGesture:[NSString stringWithFormat:
                              @"  probe: too late after %.0f ms — finger had moved %.1f mm",
                              reading.latency * 1000.0, travelled]];
            return;
        }
    }

    // An action has already committed. Changing the surface now would mean, at worst, a scroll
    // gesture left open while the mouse button goes down in the middle of a flick.
    if (self.cursorTouchSurfaceIsFrozen) {
        if (reading.surface != self.cursorTouchSurface) {
            self.surfaceLateDisagreementCount++;
            [self logGesture:[NSString stringWithFormat:
                              @"  probe: %@ after %.0f ms, but already committed to %@",
                              TUCNameForSurface(reading.surface), reading.latency * 1000.0,
                              TUCNameForSurface(self.cursorTouchSurface)]];
        }
        return;
    }

    self.cursorTouchSurface = reading.surface;
    self.cursorTouchSurfaceSource = reading.source;
    self.cursorTouchSurfaceState = TUCSurfaceStateKnown;

    // Counted here, at the one point where an answer is both usable and actually used, rather than on
    // arrival. Counting arrivals would fold in every answer that was then refused as stale, as second,
    // or as too late — and the whole worth of this figure is that it says how often the mechanism
    // reached a gesture in time to change it, which is the question of whether it earns its keep at
    // all. It cannot be read off the latency: what matters is not how long the answer took but whether
    // it beat the finger, and how fast the finger moves is the user's business.
    if (self.cursorTouchQualifiedForTap) {
        self.surfaceAnswersInTimeCount++;
    }

    [self logGesture:[NSString stringWithFormat:@"  probe: %@ after %.0f ms",
                      TUCNameForSurface(reading.surface), reading.latency * 1000.0]];
}


- (void)processTouchesForCursorInput {
    
    if(!self.cursorTouch || !self.postMouseEvents) {
        return;
    }

    // A matched device that has not been allowed to drive the pointer still gets this far: its
    // touches populate the touch set so it is visible in the test overlay. It just may not turn
    // them into input.
    if (!TouchDeviceDrivesPointer(self.cursorTouch.locationID)) {
        return;
    }
    
    TUCTouch *cursorTouch = self.cursorTouch;
    
    
    NSArray<TUCTouch *> *touches = [[self activeTouches] allObjects];
    NSTouchPhase phase = cursorTouch.phase;

    // Latch rather than sample at lift-off: `didProcessReportForLocationID` ends the gesture —
    // and so releases the button — before the final pass gets here, so by then the button is
    // always up and a press that really happened would look like it never did.
    if ([[TUCCursorUtilities sharedInstance] isLeftMouseDown]) {
        self.cursorTouchDidActuatePress = YES;
    }

    [self updateHoldState];

    // A second finger anywhere in this touch means the lift is not a plain click, whether or not a
    // gesture was ever identified from it.
    if (touches.count >= 2) {
        self.cursorTouchSawMultipleFingers = YES;
    }

    NSTimeInterval nowTime = [NSDate timeIntervalSinceReferenceDate];
    if (touches.count != self.settledTouchCount) {
        self.settledTouchCount = touches.count;
        self.timeOfTouchCountChange = nowTime;
    }
    BOOL fingerCountHasSettled = (nowTime - self.timeOfTouchCountChange) >= kFingerCountSettleTime;

    // Three or more fingers are a gesture of the whole hand, so they are read here — ahead of
    // everything that branches on the cursor touch's phase. Below the stationary branch, as this
    // used to be, a swipe was only ever evaluated on reports where the *first* finger down happened
    // to be registering movement; if that one was the anchor of the sweep, the gesture was invisible.
    if (touches.count >= 3) {
        if (fingerCountHasSettled) {
            [self recogniseSwipeWithTouches:touches];
        }
        return;
    }

    // Fingers leaving after a multi-finger gesture. Nothing they do on the way out is input.
    if (self.cursorTouchSawMultipleFingers && self.hasSwipeBaseline) {
        return;
    }


    if (phase == NSTouchPhaseBegan) {
        // Before the gesture, so `TouchDown` itself already sees the cheap answer. Once per cursor
        // touch: this branch returns, and the adoption block that precedes it runs on the report
        // before, so there is exactly one pass through here per finger.
        [self classifySurfaceForCursorTouch];

        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }


    else if (phase == NSTouchPhaseStationary) {
        if (touches.count <= 2) {
            [self checkForSecondaryClick];
        }

        return;
    }


    else if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        // A running multitouch gesture owns the lift-off: `stopCurrentGesture` posts its
        // terminating event (the final magnify, say) and no click may follow it.
        BOOL wasMultitouchGesture = self.identifiedMultitouchGesture != _TUCCursorGestureNone;

        // If this touch already actuated a press — a hold mapped to a drag — then the lift is
        // that press's release, and adding a click on top would actuate the same touch twice.
        BOOL didActuatePress = self.cursorTouchDidActuatePress;

        // A cancelled touch is one the digitizer stopped reporting rather than released. If it
        // never left the tap slop then the user did tap and only the release went missing, and
        // discarding that is the worst available reading of a device we already tolerate losing
        // reports from — that tolerance is what `errorResistance` is for. A cancelled touch that
        // had moved is genuinely lost mid-gesture, so it ends quietly instead.
        BOOL wasLostMidGesture = (phase == NSTouchPhaseCancelled) && !self.cursorTouchQualifiedForTap;

        if (phase == NSTouchPhaseCancelled && !wasLostMidGesture) {
            [self noteOnceForLocationID:cursorTouch.locationID
                                   key:@"tap-via-cancel"
                               message:@"does not report a lift-off for every touch; a stationary "
                                        "touch that simply stopped being reported is being treated as a tap."];
        }

        //   never left the slop  -> a tap, unless the hold already opened a menu
        //   left the slop         -> the end of a scroll
        if (!wasMultitouchGesture && !wasLostMidGesture) {
            if (self.cursorTouchDidActuateLongPress) {
                // The menu is already open; the lift is not a click.
            } else if (self.cursorTouchQualifiedForTap) {
                // Putting three fingers down and lifting them again is not a click, however little
                // the first one moved.
                if (!didActuatePress && !self.cursorTouchSawMultipleFingers) {
                    [self performMouseEventForGesture:TUCCursorGestureTap];
                }
            } else {
                // Same distinction as the moved path: a lift that ends a drag the hold armed is
                // that gesture's last event, not the end of a scroll.
                [self performMouseEventForGesture:
                     (self.cursorTouchDidHold && didActuatePress) ? TUCCursorGestureHoldAndDrag
                                                                  : TUCCursorGestureDrag];
            }
        }

        TUCScreen *summaryScreen = [self touchscreenForLocationID:cursorTouch.locationID];
        [self logGesture:[NSString stringWithFormat:
                          @"touch ended: %.0f ms, moved %.1f mm (zone %.1f), tap=%@ held=%@ menu=%@ pressed=%@%@ surface=%@(%@)",
                          ([NSDate timeIntervalSinceReferenceDate] - self.cursorTouchBeganTime) * 1000.0,
                          summaryScreen ? [summaryScreen millimetreDistanceBetweenRelativePoint:cursorTouch.location
                                                                                            and:self.cursorTouchOrigin] : -1,
                          // The tolerance that actually applied, which on a control or a title bar is
                          // tighter than the setting.
                          [self effectiveTapTolerance],
                          self.cursorTouchQualifiedForTap ? @"Y" : @"n",
                          self.cursorTouchDidHold ? @"Y" : @"n",
                          self.cursorTouchDidActuateLongPress ? @"Y" : @"n",
                          didActuatePress ? @"Y" : @"n",
                          wasMultitouchGesture ? @" multitouch" : @"",
                          TUCNameForSurface(self.cursorTouchSurface),
                          TUCNameForSurfaceState(self.cursorTouchSurfaceState)]];

        [self stopCurrentGesture];

        // The normal lift already ended the scroll and handed off its flick, so this is a no-op
        // there. It exists for the routes that skip that entirely — a multitouch gesture having
        // taken over, or a touch lost mid-drag — which otherwise left the gesture open for good.
        [[TUCCursorUtilities sharedInstance] cancelScrollGesture];

        // This touch is finished with. `removeTouch:now:NO` keeps the object alive for half a
        // second so gesture evaluation can still see it, and the weak reference here stayed valid
        // for just as long — so every report arriving in that window re-entered this branch.
        //
        // It re-emitted the tap, and worse, it kept `updateHoldState` running against a
        // `cursorTouchStationarySinceDate` from the moment the finger first landed. Once that
        // reached the hold duration the long press fired, so a short tap produced its click and
        // then a context menu a fraction of a second later, with no finger anywhere near the glass.
        self.cursorTouch = nil;

        // The question this finger asked no longer has anybody to answer to. Bumping here rather than
        // waiting for the next finger means a probe still in flight discovers it is unwanted the
        // moment its turn comes, and gives up without troubling another application at all.
        self.surfaceProbeGeneration++;
        if (self.classifiesSurfaces) {
            [TUCSurfaceProbe noteCurrentGeneration:self.surfaceProbeGeneration];
        }

        // Only while the pointer is hidden. Moving a pointer the user can see, just after they
        // touched somewhere, would be its own kind of wrong.
        if (self.hidesCursor) {
            CGPoint touchedPoint = [self convertScreenPointRelativeToAbsolute:cursorTouch.location
                                                                  locationID:cursorTouch.locationID];
            [[TUCCursorUtilities sharedInstance]
                    parkCursorAt:touchedPoint
                     insideFrame:[self absoluteBoundsForLocationID:cursorTouch.locationID]];
        }

        return;
    }
    
    if (touches.count <= 2 && [self checkForSecondaryClick]) {
        return;
    }
    
    // Once a swipe has been acted on, the rest of the hand-down is just fingers leaving. Without
    // this, dropping from three fingers back through two would start a drag on the way out.
    if ([touches count] == 2 && [touches containsObject: cursorTouch]) {
        TUCTouch *otherTouch = touches[1];
        if (otherTouch.uuid == cursorTouch.uuid) {
            otherTouch = touches[0];
        }
        self.gestureAdditionalTouch = otherTouch;

        // Not until the count has settled: a third finger on its way would otherwise find this
        // already committed to a pinch or a drag, with the button down.
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone && fingerCountHasSettled) {
            [self classifyTwoFingerGestureWithSecondTouch:otherTouch];
        }

        if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
            [self performMouseEventForGesture:self.identifiedMultitouchGesture];
        }

        // Two fingers are down. Even while it is still undecided, this is not one-finger input, so
        // nothing below may run — otherwise the opening reports of every two-finger gesture would
        // scroll before the gesture was recognised.
        return;
    }

    // A gesture that is already running keeps running until every finger is up. Lifting the second
    // finger part-way through a two-finger drag used to fall through to the one-finger path and
    // turn the rest of the drag into a scroll.
    if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
        [self performMouseEventForGesture:self.identifiedMultitouchGesture];
        return;
    }

    // The touch has already done what it was going to do.
    if (self.cursorTouchDidActuateLongPress) {
        return;
    }

    // A hold that took the button down has already committed this touch to a drag, so the slop
    // below has nothing left to protect: there is no tap left to preserve, and swallowing the
    // first couple of millimetres would start a text selection in the wrong place.
    BOOL isCommittedToDrag = self.cursorTouchDidHold && self.cursorTouchDidActuatePress;

    // Still inside the tap slop: the finger has not travelled far enough to mean anything
    // but a tap yet. Committing to a scroll or a drag here would emit a few pixels of stray
    // movement on every tap — exactly the noise the slop radius exists to absorb.
    if (self.cursorTouchQualifiedForTap && !isCommittedToDrag) {
        return;
    }

    // Holding and then moving is a different gesture from moving straight away, and this is the
    // only place either is emitted. Without the distinction a hold that armed a drag would arrive
    // as a plain `Drag` and be mapped to a scroll, so the button would be down and scroll events
    // would be posted through it.
    [self performMouseEventForGesture:isCommittedToDrag ? TUCCursorGestureHoldAndDrag
                                                       : TUCCursorGestureDrag];
}


/**
 Recognises a three-or-more-finger sweep and fires it once.

 macOS builds these from a trackpad's raw multitouch stream inside the window server, so there is
 nothing an application can post that reproduces them directly. What it does expose is the set of
 keyboard shortcuts already bound to the same commands, which is what the actions here use — the
 result is the command without the interactive, follow-your-fingers animation.

 Fires once and then stays quiet until every finger is up, or a single sweep would repeat for as
 long as the fingers kept moving.
 */
- (void)recogniseSwipeWithTouches:(NSArray<TUCTouch *> *)touches {
    if (self.didRecogniseSwipe) {
        return;
    }

    TUCScreen *screen = [self touchscreenForLocationID:self.cursorTouch.locationID];
    if (screen == nil) {
        return;
    }

    CGPoint midpoint = CGPointZero;
    for (TUCTouch *touch in touches) {
        midpoint.x += touch.location.x / touches.count;
        midpoint.y += touch.location.y / touches.count;
    }

    // How far the fingers sit from their own midpoint. A sweep leaves this alone and moves the
    // midpoint; fingers closing or opening move this and leave the midpoint roughly where it was.
    // Comparing the two is what distinguishes "all three went the same way" from "three fingers
    // moved, but not together" — the midpoint alone cannot tell those apart, and a three-finger
    // pinch would shift it enough to change desktop.
    CGFloat spread = 0;
    for (TUCTouch *touch in touches) {
        spread += [screen millimetreDistanceBetweenRelativePoint:touch.location and:midpoint] / touches.count;
    }

    if (!self.hasSwipeBaseline) {
        self.hasSwipeBaseline = YES;
        self.swipeBaselineMidpoint = midpoint;
        self.swipeBaselineSpread = spread;
        self.swipeFurthestTravel = 0;

        [self logGesture:[NSString stringWithFormat:@"%lu fingers down, watching for a sweep",
                          (unsigned long)touches.count]];

        // Three fingers supersede whatever one or two were doing. Deliberately not
        // `stopCurrentGesture`, which would clear the baseline just set here and loop.
        TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
        [utils cancelScrollGesture];
        [utils stopDraggingCursor];
        [utils stopMagnifying];
        self.identifiedMultitouchGesture = _TUCCursorGestureNone;

        return;
    }

    CGSize physicalSize = [screen effectivePhysicalSize];
    CGFloat travelX = (midpoint.x - self.swipeBaselineMidpoint.x) * physicalSize.width;
    CGFloat travelY = (midpoint.y - self.swipeBaselineMidpoint.y) * physicalSize.height;

    CGFloat travel = MAX(fabs(travelX), fabs(travelY));
    self.swipeFurthestTravel = MAX(self.swipeFurthestTravel, travel);

    if (travel < kSwipeCommitDistance) {
        return;
    }

    // Far enough, but only a sweep if the fingers travelled together rather than apart.
    if (fabs(spread - self.swipeBaselineSpread) > travel) {
        return;
    }

    TUCCursorGesture swipe;
    if (fabs(travelX) > fabs(travelY)) {
        swipe = (travelX < 0) ? TUCCursorGestureSwipeLeft : TUCCursorGestureSwipeRight;
    } else {
        swipe = (travelY < 0) ? TUCCursorGestureSwipeUp : TUCCursorGestureSwipeDown;
    }

    self.didRecogniseSwipe = YES;
    [self performMouseEventForGesture:swipe];
}


/**
 Decides whether two fingers are pinching or panning, by which of the two has developed further
 since the second finger landed: the gap between them changing means a pinch, the pair travelling
 together means a pan.

 This used to compare the two fingers' per-report direction signs and call any mismatch a pinch.
 A single report where one finger happened not to move on one axis was enough to read a pan as a
 pinch, which is survivable when the alternative is nothing but not when panning is the gesture
 for dragging anything at all.
 */
- (void)classifyTwoFingerGestureWithSecondTouch:(TUCTouch *)otherTouch {
    TUCTouch *cursorTouch = self.cursorTouch;
    TUCScreen *screen = [self touchscreenForLocationID:cursorTouch.locationID];
    if (screen == nil) {
        return;
    }

    CGPoint midpoint = CGPointMake((cursorTouch.location.x + otherTouch.location.x) / 2.0,
                                   (cursorTouch.location.y + otherTouch.location.y) / 2.0);
    CGFloat spread = [screen millimetreDistanceBetweenRelativePoint:cursorTouch.location
                                                                and:otherTouch.location];

    if (!self.hasTwoFingerBaseline) {
        self.hasTwoFingerBaseline = YES;
        self.twoFingerBaselineSpread = spread;
        self.twoFingerBaselineMidpoint = midpoint;
        return;
    }

    CGFloat spreadChange = fabs(spread - self.twoFingerBaselineSpread);
    CGFloat commonTravel = [screen millimetreDistanceBetweenRelativePoint:midpoint
                                                                     and:self.twoFingerBaselineMidpoint];

    // Hold off until one reading is clearly ahead, so the first noisy reports cannot decide it.
    if (MAX(spreadChange, commonTravel) < kTwoFingerCommitDistance) {
        return;
    }

    TUCCursorGesture candidate = (spreadChange > commonTravel)
        ? TUCCursorGesturePinch
        : TUCCursorGestureTwoFingerDrag;

    // Claiming a gesture nothing is mapped to would only suppress everything else.
    if ([self actionForGesture:candidate] != TUCCursorActionNone) {
        self.identifiedMultitouchGesture = candidate;

        // Whatever one finger had started is now superseded, and it is this gesture's job to say
        // so — nothing further down will, because every remaining path checks
        // `identifiedMultitouchGesture` first and skips.
        [[TUCCursorUtilities sharedInstance] cancelScrollGesture];
    }
}


/**
 Detects the secondary-click gesture: a second finger tapped down and up again close to the one
 that is resting on the glass.

 The second finger has to have been on the glass *at the same time* as the resting one. Ended
 touches stay in `touchSet` for half a second after they lift — long enough for the previous,
 finished tap to still be sitting there — and this used to accept any of them. Since the only
 thing excluding them was a differing contact ID, and controllers routinely hand out a fresh ID
 for each touch, tapping twice near the same spot inside half a second turned the second tap into
 a right-click. On a resting finger the check runs on the very first stationary report, so it beat
 the tap to it every time.
 */
- (BOOL)checkForSecondaryClick {
    TUCTouch *cursorTouch = self.cursorTouch;
    if (cursorTouch == nil || self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
        return NO;
    }

    // Resting long enough already opened a menu; a second finger must not open another.
    if (self.cursorTouchDidActuateLongPress) {
        return NO;
    }

    TUCScreen *screen = [self touchscreenForLocationID:cursorTouch.locationID];
    if (screen == nil) {
        return NO;
    }

    // The second finger has to have been on the glass at the same time as this one, which is true
    // exactly when its last report came in after this touch landed.
    //
    // An earlier attempt at this compared HID frame counters, which is wrong for a reason worth
    // recording: that counter advances once per report, so a gap of six frames is six reports and
    // not six milliseconds. Between two taps the device reports nothing at all, so the previous
    // tap stayed permanently "within six frames" of the next one and every second tap in quick
    // succession opened a menu instead of clicking. A counter of activity is not a clock.

    TUCTouch *secondFinger = nil;
    NSUInteger candidateCount = 0;

    for (TUCTouch *touch in self.touchSet) {
        if (touch.locationID != cursorTouch.locationID) continue;
        if (touch.uuid == cursorTouch.uuid) continue;

        if ([screen millimetreDistanceBetweenRelativePoint:touch.location
                                                       and:cursorTouch.location] > kSecondFingerProximity) {
            continue;
        }

        BOOL hasLifted = (touch.phase == NSTouchPhaseEnded || touch.phase == NSTouchPhaseCancelled);
        if (!hasLifted || touch.lastUpdatedTime < self.cursorTouchBeganTime) {
            continue;
        }

        candidateCount++;
        secondFinger = touch;
    }

    // Exactly one, or it is not the gesture — several fingers lifting together is something else.
    if (candidateCount != 1) {
        return NO;
    }

    [self removeTouch:secondFinger now:YES];
    [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
    return YES;
}


- (void)performMouseEventForGesture:(TUCCursorGesture)gesture {
    TUCTouch *touch = self.cursorTouch;
    
    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:touch.location locationID:touch.locationID];
    CGPoint location2ndFinger = [self convertScreenPointRelativeToAbsolute:self.gestureAdditionalTouch.location locationID:touch.locationID];
    
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    TUCCursorAction action = [self actionForGesture:gesture atScreenLocation:screenLocation];

    // Anything past the touch landing has consequences a late answer must not be allowed to revise.
    // `TouchDown` is exempt because it only moves the pointer, which the next report would do anyway.
    if (gesture != TUCCursorGestureTouchDown) {
        self.cursorTouchSurfaceIsFrozen = YES;
    }

    CGFloat doubleClickSpan = self.doubleClickTolerance * [[self touchscreenForLocationID:touch.locationID] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];
    
    switch (action) {
        case TUCCursorActionNone:
            break;
            
        case TUCCursorActionMove:
            [utils moveCursorTo:screenLocation];
            break;
            
        case TUCCursorActionMoveClickIfNeeded: {
            [utils moveCursorTo:screenLocation];

            // Activate rather than click. The tap's own click follows on lift-off and lands on a
            // window that is active by then, so it actuates whatever it hits — one click, doing
            // both jobs, with nothing injected to double it up.
            pid_t owner = [self applicationToRaiseForPoint:screenLocation locationID:touch.locationID];
            if (owner != 0) {
                [[NSRunningApplication runningApplicationWithProcessIdentifier:owner]
                    activateWithOptions:0];
            }
        }

            break;
            
        case TUCCursorActionPointAndClick:
            [utils moveCursorTo:screenLocation];
            if (touch.phase == NSTouchPhaseEnded) {
                [utils performClickAt:screenLocation];
            }
            break;
            
        case TUCCursorActionDrag: {
            // Put the button down where the finger landed, before taking it anywhere.
            //
            // `dragCursorTo:phase:` presses wherever it is first called, which is the first report
            // that registered movement — by then already a couple of millimetres from where the user
            // actually grabbed, because that travel is what proved this was a drag and not a tap.
            // Pressing there is wrong everywhere and fatal in two places: a window's resize border is
            // about five points wide, so the press lands inside the window and drags its contents
            // instead of resizing it; and a slider's thumb jumps to the finger the instant it is
            // touched.
            //
            // One finger only. A two-finger drag's origin is where the *first* finger landed, which
            // can be somewhere else entirely by the time the second arrives.
            BOOL isOneFingerDrag = (gesture == TUCCursorGestureDrag
                                    || gesture == TUCCursorGestureHoldAndDrag);

            // Whether a new sequence is needed is decided by where the press lands, so it belongs
            // with the press. See `-dragCursorTo:phase:startingNewClickSequence:`.
            BOOL startsNewSequence = (self.cursorTouchSurface == TUCSurfaceKindWindowChrome);

            // Asked of the button itself rather than of `cursorTouchDidActuatePress`, which is
            // latched from this same state one report later and so would still read NO here.
            if (!utils.isLeftMouseDown && isOneFingerDrag && touch.phase != NSTouchPhaseEnded) {
                CGPoint origin = [self convertScreenPointRelativeToAbsolute:self.cursorTouchOrigin
                                                                locationID:touch.locationID];
                [utils dragCursorTo:origin
                              phase:NSTouchPhaseBegan
           startingNewClickSequence:startsNewSequence];
            }

            [utils dragCursorTo:screenLocation
                          phase:touch.phase
       startingNewClickSequence:startsNewSequence];
            break; }
            
        case TUCCursorActionClick:
            [utils performClickAt:screenLocation];
            break;
            
        case TUCCursorActionSecondaryClick:
            [utils performSecondaryClickAt: screenLocation];
            break;
            
        case TUCCursorActionScroll: {
            CGPoint prevLocation = [self convertScreenPointRelativeToAbsolute:touch.previousLocation locationID:touch.locationID];
            CGPoint translation = CGPointMake(screenLocation.x - prevLocation.x,
                                              screenLocation.y - prevLocation.y);
            [utils scroll:translation phase:touch.phase];
            
            break; }
            
        // Direction follows the fingers, as everywhere else here: sweeping left carries the
        // current space off to the left, which brings the next one in from the right.
        case TUCCursorActionSpaceNext:
            [utils pressKey:kVK_RightArrow modifiers:kCGEventFlagMaskControl];
            break;

        case TUCCursorActionSpacePrevious:
            [utils pressKey:kVK_LeftArrow modifiers:kCGEventFlagMaskControl];
            break;

        case TUCCursorActionMissionControl:
            [utils pressKey:kVK_UpArrow modifiers:kCGEventFlagMaskControl];
            break;

        case TUCCursorActionApplicationWindows:
            [utils pressKey:kVK_DownArrow modifiers:kCGEventFlagMaskControl];
            break;

        case TUCCursorActionMagnify:
            [utils magnifyLocationA:screenLocation
                          locationB:location2ndFinger
                         relativeP1:self.cursorTouch.location relP2:self.gestureAdditionalTouch.location];
            
            if (touch.phase == NSTouchPhaseEnded || self.gestureAdditionalTouch.phase == NSTouchPhaseEnded) {
                [utils stopMagnifying];
            }
            break;
    }

    // Recorded after the action has run, so a click reports the state actually stamped on its
    // event rather than the one left over from the press before. `TouchDown` fires on every touch
    // and would swamp the record; everything else here is a decision worth seeing.
    if (gesture != TUCCursorGestureTouchDown) {
        BOOL isClick = (action == TUCCursorActionClick || action == TUCCursorActionPointAndClick);
        [self logGesture:[NSString stringWithFormat:@"  %@ -> %@%@%@",
                          TUCNameForGesture(gesture), TUCNameForAction(action),
                          isClick ? [NSString stringWithFormat:@" as click state %ld", (long)utils.lastClickCount] : @"",
                          // The reason on the same line as the decision. Without it, "it drags
                          // sometimes and scrolls other times on the same control" has no
                          // explanation anywhere in the record.
                          self.cursorTouchSurfaceState == TUCSurfaceStateNone
                              ? @""
                              : [NSString stringWithFormat:@" [%@/%@]",
                                 TUCNameForSurface(self.cursorTouchSurface),
                                 TUCNameForSurfaceSource(self.cursorTouchSurfaceSource)]]];
    }
}


/**
 The circumstances of whatever gesture is being decided right now.

 Built from the cursor touch, so it is only meaningful while one is down. Cheap enough to make on
 every decision — it copies six scalars — which is why there is no attempt to cache it.
 */
- (TUCGestureContext *)gestureContextAtScreenLocation:(CGPoint)screenLocation {
    TUCTouch *touch = self.cursorTouch;
    uint32_t locationID = touch ? touch.locationID : self.locationIDOfLastTouch;

    return [[TUCGestureContext alloc] initWithSurface:self.cursorTouchSurface
                                              source:self.cursorTouchSurfaceSource
                                               state:self.cursorTouchSurfaceState
                                       digitizerKind:[self digitizerKindForLocationID:locationID]
                                          locationID:locationID
                                      screenLocation:screenLocation
                                             didHold:self.cursorTouchDidHold];
}


/// Convenience for the callers that have not already converted the touch's position — currently only
/// the long-press veto in `-updateHoldState`, which runs once per touch rather than once per report.
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
    TUCTouch *touch = self.cursorTouch;
    CGPoint screenLocation = touch
        ? [self convertScreenPointRelativeToAbsolute:touch.location locationID:touch.locationID]
        : CGPointZero;

    return [self actionForGesture:gesture atScreenLocation:screenLocation];
}


/**
 What a gesture should do, asked of the delegate.

 Takes the position rather than working it out, because `-performMouseEventForGesture:` has already
 converted it and that method runs on every report of a drag or a scroll. Converting it twice there
 would mean a second delegate round trip per report, in the one path where per-report cost is the
 thing this file is most careful about.
 */
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture atScreenLocation:(CGPoint)screenLocation {

    // The richer question first, and only one of the two is ever asked. A delegate that answers it
    // has taken over the mapping entirely; falling through to `-actionForGesture:` as well would
    // mean two answers to the same question with no rule about which wins.
    if ([self.delegate respondsToSelector:@selector(actionForGesture:inContext:)]) {
        return [self.delegate actionForGesture:gesture
                                    inContext:[self gestureContextAtScreenLocation:screenLocation]];
    }

    // The original contract, unchanged. `TouchUpCore` ships as a framework, so this is somebody
    // else's code as far as this file is concerned.
    if (self.delegate != nil) {
        return [self.delegate actionForGesture:gesture];
    }

    switch(gesture) {
        case TUCCursorGestureTouchDown:         return TUCCursorActionMoveClickIfNeeded;
        case TUCCursorGestureTap:               return TUCCursorActionClick;
        // Nothing by default: the lift-off already produces the click, and pressing here too
        // would actuate the touch twice. Map it to a drag to hold the button for as long as
        // the finger rests instead.
        case TUCCursorGestureLongPress:         return TUCCursorActionNone;
        case TUCCursorGestureDrag:              return TUCCursorActionScroll;
        case TUCCursorGestureHoldAndDrag:       return TUCCursorActionDrag;
        case TUCCursorGestureTapSecondFinger:   return TUCCursorActionSecondaryClick;
        case TUCCursorGestureTwoFingerDrag:     return TUCCursorActionDrag;
            
        case TUCCursorGesturePinch:             return TUCCursorActionMagnify;

        case TUCCursorGestureSwipeLeft:         return TUCCursorActionSpaceNext;
        case TUCCursorGestureSwipeRight:        return TUCCursorActionSpacePrevious;
        case TUCCursorGestureSwipeUp:           return TUCCursorActionMissionControl;
        case TUCCursorGestureSwipeDown:         return TUCCursorActionApplicationWindows;

        case _TUCCursorGestureNone:             return TUCCursorActionNone;
    }
}


#pragma mark - Touch Set

/**
 The `touchSet` can contain touches whose phase is ended or cancelled. activeTouches. filteres those out
 */
- (NSSet<TUCTouch *> *)activeTouches {
    NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseEnded];
    NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseCancelled];
    
    NSPredicate *predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[p1, p2]];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}



- (CGFloat)distanceBetweenPoint:(CGPoint)p1 and:(CGPoint)p2 {
    CGFloat dx = p1.x - p2.x;
    CGFloat dy = p1.y - p2.y;
    
    return sqrt( pow(dx, 2) + pow(dy, 2) );
}




/**
 Removes a touch from the touch set. As a previous touch might be important for gesture evaluation, it is removed after half a second
 */
- (void)removeTouch:(TUCTouch *)touch now:(BOOL)instantDeletion{
    //    if (touch.uuid == self.touchUsedForCursor.uuid) {
    //        [self processTouchesForCursorInput];
    //        self.touchUsedForCursor = nil;
    //    }
    
    if (instantDeletion) {
        [[self touchSet] removeObject:touch];
        [[self delegate] touchesDidChange];
        return;
    }
    
    __weak id weakSelf = self;
    NSUUID *uuid = touch.uuid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        for(TUCTouch *touch in [weakSelf touchSet]) {
            if (touch.uuid == uuid && [[weakSelf touchSet] containsObject:touch]) {
                [[weakSelf touchSet] removeObject:touch];
                [[weakSelf delegate] touchesDidChange];
                return;
            }
        }
    });
}


- (BOOL)hasTouchBeenAbandoned:(TUCTouch *)touch {
    return ([NSDate timeIntervalSinceReferenceDate] - touch.lastUpdatedTime) > kAbandonedTouchTimeout;
}


/**
 Checks the touch set if a touch exists
 */
- (TUCTouch *)findTouchWithID:(NSInteger)contactID locationID:(uint32_t)locationID includingPastTouches:(BOOL)includePastTouches {
    NSSet *set = includePastTouches ? self.touchSet : [self activeTouches];
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"contactID == %d AND locationID == %u", contactID, locationID];
    TUCTouch *touch = [[set filteredSetUsingPredicate:predicate] anyObject];
    return touch;
}

/**
 Returns the existing touch object or a new one if this ID does not exist in the set yet.
 */
- (TUCTouch *)obtainTouchWithID:(NSInteger)contactID locationID:(uint32_t)locationID isNew:(BOOL*)isNew {
    TUCTouch *touch = [self findTouchWithID:contactID locationID:locationID includingPastTouches:NO];

    // A contact whose last report is old is not the finger now arriving under the same ID. Reusing
    // it silently inherits the whole of the previous touch's gesture state, and the hold clock is
    // the damaging part: it still reads from when that earlier finger landed, so it is already past
    // the hold duration and a short tap opens a context menu the instant it is touched.
    if (touch != nil && [self hasTouchBeenAbandoned:touch]) {
        [touch setPhase:NSTouchPhaseCancelled];
        [self removeTouch:touch now:YES];
        touch = nil;
    }

    *isNew = NO;
    if(!touch) {
        touch = [[TUCTouch alloc] initWithContactID:contactID locationID:locationID];
        [self.touchSet addObject:touch];
        *isNew = YES;
    }
    return touch;
}





#pragma mark - Screen Characteristics

/**
 the relative hardware points are always in the direction the digitizer is built in.
 If the display is rotated, we need to rotate these points
 */
/**
 The reported point with the user's mirror flags applied and nothing else.

 Split out because this boundary — the digitizer's own frame, before anything is known about how the
 display is oriented or shaped — is the only one a calibration can be measured against, and
 `TUCTouch.uncorrectedGlassLocation` has to be recorded at exactly the same point the conversion
 starts from. Two copies of the mirroring rule that drifted apart would put every measurement in a
 slightly different space than the one it was meant to correct.
 */
- (CGPoint)mirrorDigitizerPoint:(CGPoint)devicePoint locationID:(uint32_t)locationID {
    // Corrects how the panel is wired, which is independent of how the display is currently
    // oriented — so it belongs here rather than anywhere downstream of the rotation.
    if (self.delegate != nil) {
        if ([self.delegate digitizerIsFlippedHorizontallyForLocationID:locationID]) {
            devicePoint.x = 1 - devicePoint.x;
        }
        if ([self.delegate digitizerIsFlippedVerticallyForLocationID:locationID]) {
            devicePoint.y = 1 - devicePoint.y;
        }
    }
    return devicePoint;
}


- (CGPoint)convertDigitizerPointToRelativeScreenPoint:(CGPoint)devicePoint locationID:(uint32_t)locationID {
    TUCScreen *screen = [self touchscreenForLocationID:locationID];

    devicePoint = [self mirrorDigitizerPoint:devicePoint locationID:locationID];

    CGFloat rotation = screen.rotation;

    CGFloat extra = [[self delegate] digitizerRotationForLocationID:locationID];

    rotation += extra;
    rotation = fmod(rotation, 360);
    if (rotation < 0) {
        rotation += 360;
    }

    // Rotate the glass-relative point into the screen's content orientation.
    CGPoint rotated;
    if (rotation == 180) {
        rotated = CGPointMake(1 - devicePoint.x, 1 - devicePoint.y);
    } else if (rotation == 90) {
        rotated = CGPointMake(1 - devicePoint.y, devicePoint.x);
    } else if (rotation == 270) {
        rotated = CGPointMake(devicePoint.y, 1 - devicePoint.x);
    } else {
        rotated = devicePoint;
    }

    // Then account for any letterboxing when the content doesn't fill the panel (mirroring
    // a differently-shaped display). A no-op when the aspect ratios already match.
    return [screen convertGlassPointToContentPoint:rotated];
}



/**
 The region a digitizer's touches actually land in, in the coordinate space mouse events use.

 Derived by converting the two opposite corners rather than from `TUCScreen.frame`, whose
 `origin.y` is stored negated — which is why `-convertPointRelativeToAbsolute:` subtracts it
 instead of adding. Going through the same conversion that positions the clicks means this cannot
 disagree with where they land, whatever that sign convention is doing.
 */
- (CGRect)absoluteBoundsForLocationID:(uint32_t)locationID {
    TUCScreen *screen = [self touchscreenForLocationID:locationID];
    if (screen == nil) {
        return CGRectNull;
    }

    CGPoint origin = [screen convertPointRelativeToAbsolute:CGPointZero];
    CGPoint opposite = [screen convertPointRelativeToAbsolute:CGPointMake(1, 1)];

    return CGRectMake(MIN(origin.x, opposite.x),
                      MIN(origin.y, opposite.y),
                      fabs(opposite.x - origin.x),
                      fabs(opposite.y - origin.y));
}


- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID {
    return [[self touchscreenForLocationID:locationID] convertPointRelativeToAbsolute:relativePoint];
}



- (TUCScreen *)touchscreenForLocationID:(uint32_t)locationID {
    if (self.delegate != nil) {
        return [self.delegate touchscreenForLocationID:locationID];
    }
    
    return [[TUCScreen allScreens] firstObject];
}



- (BOOL)isPointInMenuBar:(CGPoint)point locationID:(uint32_t)locationID {
    CGFloat menuBarHeight = [[[NSApplication sharedApplication] mainMenu] menuBarHeight];
    
    CGRect screenFrame = [self touchscreenForLocationID:locationID].frame;
    CGRect menuBarFrame = CGRectMake(screenFrame.origin.x,
                                     screenFrame.origin.y * -1,
                                     screenFrame.size.width,
                                     menuBarHeight);
    
    if (CGRectContainsPoint(menuBarFrame, point)) {
        return YES;
    }
    return NO;
}


- (BOOL)isSystemChromeOwner:(pid_t)pid name:(NSString *)ownerName {
    static NSSet<NSString *> *chromeBundleIDs;
    static NSSet<NSString *> *chromeOwnerNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chromeBundleIDs = [NSSet setWithArray:@[
            @"com.apple.dock",
            @"com.apple.controlcenter",
            @"com.apple.notificationcenterui",
        ]];
        // The Window Server has no NSRunningApplication, so match it by owner name.
        chromeOwnerNames = [NSSet setWithArray:@[ @"Window Server", @"WindowServer" ]];
    });

    if (ownerName && [chromeOwnerNames containsObject:ownerName]) {
        return YES;
    }

    NSString *bundleID = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
    return bundleID != nil && [chromeBundleIDs containsObject:bundleID];
}


/**
 The frontmost ordinary window under `point`, as the window list sees it: who owns it, what it is
 called, where it is, and whether it sits behind the active application's topmost window. Returns NO
 when the point is over nothing but the desktop.

 Returns what it found rather than a verdict, because the two callers need this same walk and
 opposite conclusions from it. Raising cares only about a window *behind* the active one; classifying
 what was touched cares very much about the one in front.

 System chrome — the Dock, Control Center — is skipped rather than returned, which is what the raise
 decision needs. `outFrontmostHitIsChrome` reports that it was passed over anyway, since a finger on
 the Dock has touched something even though there is nothing there to raise.

 One of our own windows ends the walk and sets `outHitOwnWindow`, returning NO. The finger is on the
 keyboard or the inspector; there is nothing there to raise and nothing there to classify.
 */
- (BOOL)findWindowUnderPoint:(CGPoint)point
                       owner:(pid_t *)outOwner
                      bounds:(CGRect *)outBounds
                   ownerName:(NSString * __autoreleasing *)outOwnerName
     isBehindFrontmostWindow:(BOOL *)outIsBehind
        frontmostHitIsChrome:(BOOL *)outFrontmostHitIsChrome
                hitOwnWindow:(BOOL *)outHitOwnWindow {

    pid_t frontmostPID = [[[NSWorkspace sharedWorkspace] frontmostApplication] processIdentifier];

    CFArrayRef array = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);

    // The window list is ordered front-to-back by window *level* (not grouped by app), so
    // high-level overlays — including our own screenSaver-level panels — come before the
    // active app's normal windows. `behindFrontmostWindow` flips once we pass the active
    // app's topmost window: windows seen before it are stacked above it, windows after are
    // behind it.
    BOOL behindFrontmostWindow = NO;
    BOOL didHitChrome = NO;
    BOOL found = NO;

    if (outFrontmostHitIsChrome) *outFrontmostHitIsChrome = NO;
    if (outHitOwnWindow) *outHitOwnWindow = NO;

    for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
        CFDictionaryRef dic = CFArrayGetValueAtIndex(array, i);

        CFNumberRef numPid = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
        pid_t currPID;
        CFNumberGetValue(numPid, kCFNumberIntType, &currPID);
        BOOL isFrontmostApp = currPID == frontmostPID;

        CFDictionaryRef bounds = CFDictionaryGetValue(dic, kCGWindowBounds);
        CGRect nextFrame;
        CGRectMakeWithDictionaryRepresentation(bounds, &nextFrame);
        BOOL isInside = CGRectContainsPoint(nextFrame, point);

        if (isFrontmostApp && !behindFrontmostWindow) {
            behindFrontmostWindow = YES;
        }

        if (!isInside) continue;

        // Our own windows are not scenery the user is touching, they are the instrument they are
        // touching *with* — the on-screen keyboard, the touch test overlay, the gesture inspector,
        // the settings window. The finger has reached one of them and stops there.
        //
        // **Ending the walk is the whole point; skipping past it was actively harmful.** Whatever is
        // behind our window is not what was touched, and offering it up meant that with the settings
        // window open — which makes Touch Up frontmost — every press handed the application *behind*
        // the settings window to `-applicationToRaiseForPoint:`, which duly activated it. The window
        // being touched lost focus on every press, and got it back on lift only because the tap's own
        // click landed on an inactive window and activated us again. Dragging a slider therefore
        // flickered focus between two applications on every single touch.
        if (currPID == getpid()) {
            if (outHitOwnWindow) *outHitOwnWindow = YES;
            break;
        }

        NSString *ownerName = (__bridge NSString *)CFDictionaryGetValue(dic, kCGWindowOwnerName);
        if ([self isSystemChromeOwner:currPID name:ownerName]) {
            // Only the topmost thing under the finger describes what was touched. Chrome behind a
            // window is chrome the user cannot reach.
            if (!didHitChrome && outFrontmostHitIsChrome) *outFrontmostHitIsChrome = YES;
            didHitChrome = YES;
            continue;
        }

        // First real window under the point = the one the finger actually hits.
        if (outOwner)     *outOwner = currPID;
        if (outBounds)    *outBounds = nextFrame;
        if (outOwnerName) *outOwnerName = ownerName;
        if (outIsBehind)  *outIsBehind = behindFrontmostWindow && !isFrontmostApp;
        found = YES;
        break;
    }

    CFRelease(array);
    return found;
}


/**
 How far (points) below a window's top edge still counts as its title bar, when geometry is all there
 is to go on. A standard title bar is 28 points tall; a window with a unified toolbar is taller, and
 guessing tall there would claim content.
 */
static const CGFloat kTitleBarProbeHeight = 28.0;


/**
 How far inside a window's left, right and bottom edges still counts as its resize border.

 Wider than the few points macOS itself allows, because a finger is not a mouse and cannot be placed
 to the pixel. The cost of being generous is that the outermost couple of millimetres of a scrolling
 area drag instead of scrolling, which is the same trade a mouse already makes.
 */
static const CGFloat kResizeBorderWidth = 8.0;


/**
 What the window list alone can honestly say about `point`.

 Certain about two things and deliberately silent about everything else. It knows where windows are,
 so it knows when there is no window at all — which is the desktop, and is worth having for free,
 since dragging on the desktop should select rather than scroll. It knows who owns them, so it knows
 the Dock and the menu bar. Anything *inside* a window it cannot see at all, and returns
 `TUCSurfaceKindUnknown` rather than guessing `Content`: a slider and a paragraph look identical from
 here, and the mapping has to be able to tell "there is nothing special here" from "I could not see".

 The title bar is the one guess it does make, from geometry, and it is marked as coming from the
 window list precisely so the mapping can refuse to start a drag on it. A full-screen game is a
 window with no accessibility support and no title bar, and its top 28 points are not a handle.
 */
- (TUCSurfaceKind)windowSurfaceForPoint:(CGPoint)point locationID:(uint32_t)locationID {

    if ([self isPointInMenuBar:point locationID:locationID]) {
        return TUCSurfaceKindWindowChrome;
    }

    CGRect bounds = CGRectZero;
    BOOL hitIsChrome = NO;
    BOOL hitOwnWindow = NO;

    BOOL found = [self findWindowUnderPoint:point
                                     owner:NULL
                                    bounds:&bounds
                                 ownerName:NULL
                   isBehindFrontmostWindow:NULL
                      frontmostHitIsChrome:&hitIsChrome
                              hitOwnWindow:&hitOwnWindow];

    // Our own interface. Emphatically not `Desktop`, which is what "found nothing" would otherwise
    // mean here — that would make the on-screen keyboard draggable and every key press a drag.
    if (hitOwnWindow) {
        return TUCSurfaceKindUnknown;
    }

    // Checked before `found`, because chrome sitting in front of a window is what the finger
    // actually reached.
    if (hitIsChrome) {
        return TUCSurfaceKindWindowChrome;
    }

    // Nothing at all under the point. `kCGWindowListExcludeDesktopElements` keeps the desktop's own
    // Finder window out of the list, which is what makes this reliable rather than a guess.
    if (!found) {
        return TUCSurfaceKindDesktop;
    }

    // A window filling its whole display has no title bar to grab — it is full-screen, and on a
    // game that is also the one case where nothing else here can be read. Claiming a handle across
    // the top of it would turn an ordinary swipe into a window drag.
    CGRect screenBounds = [self absoluteBoundsForLocationID:locationID];
    BOOL isFullScreen = !CGRectIsEmpty(screenBounds)
        && CGRectContainsRect(bounds, CGRectInset(screenBounds, 1, 1));

    if (isFullScreen) {
        return TUCSurfaceKindUnknown;
    }

    if (point.y < CGRectGetMinY(bounds) + kTitleBarProbeHeight) {
        return TUCSurfaceKindWindowChrome;
    }

    // The resize border. Nothing in the accessibility tree marks one — the hit test there returns
    // whatever content the window has drawn up to its edge — so geometry is the only thing that can
    // find it, and without this a finger at a corner scrolled the content it happened to land on.
    if (point.x < CGRectGetMinX(bounds) + kResizeBorderWidth
        || point.x > CGRectGetMaxX(bounds) - kResizeBorderWidth
        || point.y > CGRectGetMaxY(bounds) - kResizeBorderWidth) {
        return TUCSurfaceKindWindowChrome;
    }

    return TUCSurfaceKindUnknown;
}


/**
 The process owning the window under `point`, when that window sits behind the active app's and a
 tap there ought to bring it forward. Zero when nothing needs raising.

 Raising is done by activating that application, not by injecting a click. A click is what this used
 to do, and it cannot work: macOS consumes the first click on an inactive window to activate it and
 does not pass it to the control underneath, unless that control opts in with `acceptsFirstMouse:`,
 which most do not. So the injected click raised the window and the tap's own click actuated the
 control — one tap doing both, which was the whole point — but on any control that *does* accept a
 first mouse, both clicks landed and a single tap pressed a button twice.

 Activating instead leaves exactly one click, the user's, arriving at a window that is already
 active by the time it does. No guessing about which controls opt in.

 It also retires a workaround: the injected click had to be skipped over title bars, because a title
 bar accepts a first click, so raise-plus-tap arrived there as a double click and zoomed the window.
 With nothing injected there is no second click to collide with, so a tap on a background title bar
 raises it like anywhere else.
 */
- (pid_t)applicationToRaiseForPoint:(CGPoint)point locationID:(uint32_t)locationID {

    if ([self isPointInMenuBar:point locationID:locationID]) {
        return 0;
    }

    pid_t owner = 0;
    BOOL isBehind = NO;

    if (![self findWindowUnderPoint:point
                              owner:&owner
                             bounds:NULL
                          ownerName:NULL
            isBehindFrontmostWindow:&isBehind
               frontmostHitIsChrome:NULL
                       hitOwnWindow:NULL]) {
        return 0;
    }

    return isBehind ? owner : 0;
}




#pragma mark -

- (instancetype)init {
    if(self = [super init]) {
        self.touchSet = [NSMutableSet new];
        self.postMouseEvents = YES;
        
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;

        self.frameIDsByLocationID = [NSMutableDictionary new];
        self.reportRatesByLocationID = [NSMutableDictionary new];
        self.rateWindowStartTimeByLocationID = [NSMutableDictionary new];
        self.rateWindowStartFrameByLocationID = [NSMutableDictionary new];
        self.notedDeviceObservations = [NSMutableSet new];
        self.recentGestureLog = [NSMutableArray new];
        self.identifiedMultitouchGesture = _TUCCursorGestureNone;

        self.doubleClickTolerance = 5;
        self.tapTolerance = 2.5;
        self.holdDuration = 0.08;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;
    }
    return self;
}


- (NSString *)debugDescription {
    NSMutableString *str = [[NSString stringWithFormat:@"Touch Set contains %ld touches:{\n", [self.touchSet count]] mutableCopy];
    
    for (TUCTouch *touch in [[self.touchSet allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)] ) {
        [str appendString: [NSString stringWithFormat:@"  %@", [touch debugDescription]] ];
        if (touch.contactID == self.cursorTouch.contactID) {
            [str appendString: @" <<<CURSOR>>>\n" ];
        } else {
            [str appendString: @"\n" ];
        }
    }
    
    [str appendString:@"}"];
    return str;
}

- (void)triggerSystemAccessibilityAccessAlert {
    CGPoint loc = [[TUCCursorUtilities sharedInstance] currentCursorLocation];
    [[TUCCursorUtilities sharedInstance] moveCursorTo:loc];
}


- (NSArray<NSString *> *)gestureDebugLines {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    if (!self.classifiesSurfaces) {
        [lines addObject:@"Surfaces: off — every gesture uses its setting"];
    } else {
        // What the finger is on, and how much that is worth. The source is the part worth watching:
        // it is the difference between an answer the element gave and one inferred from a rectangle,
        // and it decides whether a drag may start.
        [lines addObject:[NSString stringWithFormat:@"Surface:  %@  (%@, %@)",
                          TUCNameForSurface(self.cursorTouchSurface),
                          TUCNameForSurfaceSource(self.cursorTouchSurfaceSource),
                          TUCNameForSurfaceState(self.cursorTouchSurfaceState)]];
    }

    uint32_t locationID = self.cursorTouch ? self.cursorTouch.locationID : self.locationIDOfLastTouch;
    [lines addObject:[NSString stringWithFormat:@"Device:   %@%@",
                      TUCNameForDigitizerKind([self digitizerKindForLocationID:locationID]),
                      TouchDeviceDrivesPointer(locationID) ? @"" : @"  (not driving the pointer)"]];

    [lines addObject:[NSString stringWithFormat:@"Slop:     %.1f mm of %.1f mm",
                      [self effectiveTapTolerance], self.tapTolerance]];

    // Those millimetres are only worth the number they are converted through. A panel that would not
    // say how big it is gets a guessed density, and then a slop behaving like three times its stated
    // value is indistinguishable — in this readout and in every bug report — from a slop set wrong.
    TUCScreen *scaleScreen = [self touchscreenForLocationID:locationID];
    if (scaleScreen != nil) {
        TUCPhysicalSizeSource source = [scaleScreen physicalSizeSource];
        [lines addObject:[NSString stringWithFormat:@"Scale:    %.2f pt/mm (%@)%@",
                          [scaleScreen pixelsPerMM],
                          TUCPhysicalSizeSourceName(source),
                          source == TUCPhysicalSizeSourceAssumed
                            ? @"  — every mm here is a guess" : @""]];
    }

    if (self.classifiesSurfaces) {
        [lines addObject:[NSString stringWithFormat:@"Probes:   %lu answered, %lu in time, %lu too late",
                          (unsigned long)self.surfaceReadingsDelivered,
                          (unsigned long)self.surfaceAnswersInTimeCount,
                          (unsigned long)self.surfaceLateAnswerCount]];
    }

    [lines addObject:@""];

    if (self.recentGestureLog.count == 0) {
        [lines addObject:@"(touch the screen)"];
    } else {
        // The tail only. The full record is kept for the diagnostics report; a readout meant to sit
        // in a corner while you work stops being one at twenty-four lines.
        static const NSUInteger kVisibleEntries = 8;
        NSUInteger start = self.recentGestureLog.count > kVisibleEntries
            ? self.recentGestureLog.count - kVisibleEntries : 0;
        for (NSUInteger i = start; i < self.recentGestureLog.count; i++) {
            [lines addObject:self.recentGestureLog[i]];
        }
    }

    return lines;
}


- (NSString *)diagnosticsReport {
    NSMutableString *report = [NSMutableString string];

    [report appendString:@"───── Screens ─────\n"];
    NSArray<TUCScreen *> *screens = [TUCScreen allScreens];
    if (screens.count == 0) {
        [report appendString:@"(none)\n"];
    }
    for (TUCScreen *screen in screens) {
        [report appendFormat:@"%@\n", [screen debugDescription]];
    }

    // Which screen each digitizer ended up driving. An unresolved mapping means touches are
    // being converted against no screen at all, which looks identical to "no touches" from
    // the outside.
    [report appendString:@"\n───── Digitizer mapping ─────\n"];
    if (self.frameIDsByLocationID.count == 0) {
        [report appendString:@"(no digitizer connected)\n"];
    }
    for (NSNumber *key in self.frameIDsByLocationID) {
        uint32_t locationID = key.unsignedIntValue;
        TUCScreen *screen = [self touchscreenForLocationID:locationID];
        CGFloat extraRotation = (self.delegate != nil)
            ? [self.delegate digitizerRotationForLocationID:locationID] : 0;

        BOOL flippedH = (self.delegate != nil)
            && [self.delegate digitizerIsFlippedHorizontallyForLocationID:locationID];
        BOOL flippedV = (self.delegate != nil)
            && [self.delegate digitizerIsFlippedVerticallyForLocationID:locationID];

        [report appendFormat:@"digitizer %#010x   declares itself: %@ (usage %#04x)\n", locationID,
         TUCNameForDigitizerKind([self digitizerKindForLocationID:locationID]),
         TouchDeviceHIDPrimaryUsage(locationID)];

        [report appendFormat:@"digitizer %#010x   drives pointer: %@\n", locationID,
         TouchDeviceDrivesPointer(locationID) ? @"YES" : @"NO - it will never produce any input"];

        NSNumber *rate = self.reportRatesByLocationID[key];
        [report appendFormat:@"digitizer %#010x   report rate: %@\n", locationID,
         rate ? [NSString stringWithFormat:@"%.0f Hz while touched", rate.doubleValue]
              : @"not measured yet - touch and drag for a moment, then copy this again"];

        [report appendFormat:@"digitizer %#010x -> %@   (extra rotation %+.0f°, mirrored %@)\n",
         locationID,
         screen ? screen.name : @"UNRESOLVED - no screen could be assigned",
         extraRotation,
         flippedH ? (flippedV ? @"H+V" : @"H") : (flippedV ? @"V" : @"no")];
    }

    if (self.classifiesSurfaces) {
        [report appendString:@"\n"];
        [report appendString:[TUCSurfaceProbe diagnosticsDescription]];
        [report appendFormat:@"Decisions: %lu answers delivered, %lu in time to be used,\n"
                              "           %lu arrived for a finger already gone, %lu contradicted a\n"
                              "           decision already made\n",
         (unsigned long)self.surfaceReadingsDelivered,
         (unsigned long)self.surfaceAnswersInTimeCount,
         (unsigned long)self.surfaceLateAnswerCount,
         (unsigned long)self.surfaceLateDisagreementCount];
    }

    [report appendString:@"\n───── Parameters ─────\n"];
    [report appendFormat:@"postMouseEvents:      %@\n", self.postMouseEvents ? @"YES" : @"NO"];
    [report appendFormat:@"tapTolerance:         %.2f mm\n", self.tapTolerance];
    [report appendFormat:@"holdDuration:         %.3f s\n", self.holdDuration];
    [report appendFormat:@"doubleClickTolerance: %.2f mm\n", self.doubleClickTolerance];
    [report appendFormat:@"errorResistance:      %ld reports\n", (long)self.errorResistance];
    [report appendFormat:@"ignoreOriginTouches:  %@\n", self.ignoreOriginTouches ? @"YES" : @"NO"];
    [report appendFormat:@"classifiesSurfaces:   %@\n", self.classifiesSurfaces ? @"YES" : @"NO"];
    [report appendFormat:@"hidesCursor:          %@%@\n",
     self.hidesCursor ? @"YES" : @"NO",
     self.hidesCursor && ![[TUCCursorUtilities sharedInstance] canHideCursorSystemWide]
        ? @" (only while Touch Up is frontmost - the system-wide hook was unavailable)" : @""];

    // What those millimetres are actually worth. Every mm figure above is divided through the mapped
    // screen's pt/mm before it is compared against anything, so a guessed physical size rescales all
    // of them together — and the parameters above read identically either way. This is the block
    // that tells a bug report "drags never start" from "the display never said how big it is".
    [report appendString:@"\n───── Millimetre basis ─────\n"];
    if (self.frameIDsByLocationID.count == 0) {
        [report appendString:@"(no digitizer connected)\n"];
    }
    for (NSNumber *key in self.frameIDsByLocationID) {
        uint32_t locationID = key.unsignedIntValue;
        TUCScreen *screen = [self touchscreenForLocationID:locationID];

        if (screen == nil) {
            [report appendFormat:@"digitizer %#010x   no screen resolved - no mm figure applies\n",
             locationID];
            continue;
        }

        TUCPhysicalSizeSource source = [screen physicalSizeSource];
        [report appendFormat:@"digitizer %#010x   %.2f pt/mm, physical size from %@%@\n",
         locationID, [screen pixelsPerMM], TUCPhysicalSizeSourceName(source),
         source == TUCPhysicalSizeSourceAssumed
            ? @"  ← GUESSED: every mm above is scaled by this" : @""];

        [report appendFormat:@"digitizer %#010x   tapTolerance %.2f mm = %.1f pt here; "
                              "hold stillness %.1f pt; swipe commit %.0f pt\n",
         locationID,
         self.tapTolerance,       self.tapTolerance       * [screen pixelsPerMM],
         kHoldStillnessTolerance * [screen pixelsPerMM],
         kSwipeCommitDistance    * [screen pixelsPerMM]];
    }

    [report appendString:@"\n───── Recent gestures ─────\n"];
    if (self.recentGestureLog.count == 0) {
        [report appendString:@"(nothing yet - touch the screen, then copy this again)\n"];
    }
    for (NSString *entry in self.recentGestureLog) {
        [report appendFormat:@"%@\n", entry];
    }

    [report appendString:@"\n───── HID discovery ─────\n"];
    const char *transcript = HIDDiagnostics();
    if (transcript == NULL || transcript[0] == '\0') {
        [report appendString:@"(empty - no touch device was matched by the HID manager)\n"];
    } else {
        [report appendFormat:@"%s", transcript];
    }
    if (HIDDiagnosticsDidTruncate()) {
        [report appendString:@"\n[transcript truncated: capacity reached]\n"];
    }

    return report;
}



#pragma mark - Bridge calls of C Header to Objective-C

void TouchInputManagerUpdateTouchPosition(void *self, uint32_t locationID, CFIndex contactID, CGFloat x, CGFloat y, Boolean onSurface, Boolean isValid) {
    CGPoint point = CGPointMake(x, y);
    [(__bridge id)self updateTouch:(NSInteger)contactID locationID:locationID withLocation:point onSurface:onSurface tooLargeForFinger:isValid];
}

void TouchInputManagerUpdateTouchSize(void *self, uint32_t locationID, CFIndex contactID, CGFloat width, CGFloat height, CGFloat azimuth) {
    CGSize size = CGSizeMake(width, height);
    [(__bridge id)self updateTouch:(NSInteger)contactID locationID:locationID withSize:size azimuth:azimuth];
}

void TouchInputManagerDidProcessReport(void *self, uint32_t locationID) {
    [(__bridge id)self didProcessReportForLocationID:locationID];
}

void TouchInputManagerDidConnectTouchscreen(void *self, uint32_t locationID, Boolean drivesPointer) {
    [(__bridge id)self didConnectTouchscreenWithLocationID:locationID drivesPointer:drivesPointer];
}

void TouchInputManagerDidDisconnectTouchscreen(void *self, uint32_t locationID) {
    [(__bridge id)self didDisconnectTouchscreenWithLocationID:locationID];
}


@end
