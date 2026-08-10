//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCCursorUtilities.h"

@interface TUCTouchInputManager ()

@property NSMutableDictionary<NSNumber *, NSNumber *> *frameIDsByLocationID;

@property (weak, nullable) TUCTouch *cursorTouch;
@property (weak, nullable) TUCTouch *gestureAdditionalTouch;

@property CGPoint cursorTouchOrigin; // where the cursor touch first landed, in relative screen coordinates
@property BOOL cursorTouchQualifiedForTap; // NO once the cursor touch has travelled further than `tapTolerance` from its origin
@property BOOL cursorTouchDidHold; //
@property CGPoint cursorTouchStationaryAnchor; // reference point the hold clock is measured against
@property (strong) NSDate *cursorTouchStationarySinceDate;
@property BOOL cursorTouchDidActuatePress; // YES once this touch has put the mouse button down
@property BOOL cursorTouchDidActuateLongPress; // YES once this touch has opened a context menu
@property NSTimeInterval cursorTouchBeganTime; // when the cursor touch landed, for concurrency tests

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

/// Watches for pointer movement that did not come from us, so a real mouse can bring the pointer
/// back while `hidesCursor` is on.
@property (strong) id foreignPointerMonitor;

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

@synthesize hidesCursor = _hidesCursor;

- (void)setHidesCursor:(BOOL)hidesCursor {
    _hidesCursor = hidesCursor;

    [[TUCCursorUtilities sharedInstance] setIsCursorHidden:hidesCursor];

    if (hidesCursor) {
        [self startWatchingForForeignPointerMovement];
    } else {
        [self stopWatchingForForeignPointerMovement];
    }
}


/**
 Brings the pointer back as soon as something that is not us moves it.

 Our own events are stamped with `kCGEventSourceUserData`, so anything arriving without that stamp
 came from a real mouse or trackpad. Whoever is using one needs to see where it is — and would
 otherwise have to find an invisible pointer to reach the setting that turns hiding off. Touching
 the glass hides it again, so nothing about the tablet feel is lost.
 */
- (void)startWatchingForForeignPointerMovement {
    if (self.foreignPointerMonitor != nil) {
        return;
    }

    NSEventMask mask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged
                     | NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged;

    __weak typeof(self) weakSelf = self;
    self.foreignPointerMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.hidesCursor) return;

        CGEventRef cgEvent = event.CGEvent;
        if (cgEvent == NULL) return;

        int64_t source = CGEventGetIntegerValueField(cgEvent, kCGEventSourceUserData);
        if (source != kTUCSyntheticEventUserData) {
            [[TUCCursorUtilities sharedInstance] setIsCursorHidden:NO];
        }
    }];
}


- (void)stopWatchingForForeignPointerMovement {
    if (self.foreignPointerMonitor != nil) {
        [NSEvent removeMonitor:self.foreignPointerMonitor];
        self.foreignPointerMonitor = nil;
    }
}


- (void)setDigitizerDrivesPointer:(BOOL)drivesPointer forLocationID:(uint32_t)locationID {
    SetTouchDeviceDrivesPointer(locationID, drivesPointer);
}

- (BOOL)digitizerDrivesPointerForLocationID:(uint32_t)locationID {
    return TouchDeviceDrivesPointer(locationID);
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

        if (touch.lastUpdated + self.errorResistance < currentFrameID) {
            [touch setPhase:NSTouchPhaseCancelled];
            [self removeTouch:touch now:NO];
        }
    }

    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }

    self.frameIDsByLocationID[@(locationID)] = @(currentFrameID + 1);

    [self processTouchesForCursorInput];

}


/**
 Records something learned about a digitizer while interpreting its touches, at most once per
 device per `key`. These conditions are per-report by nature, so they would otherwise fill the
 transcript — but they are exactly what turns "my taps do nothing" into an answer, so they
 belong in the report a user pastes into an issue.
 */
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
    BOOL isSuspectOriginReport = self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero);

    if (isSuspectOriginReport && isOnSurface) {
        return;
    }

    // Touching hides the pointer again after a mouse brought it back. Cheap to do per report: the
    // setter is a no-op unless the state actually changes.
    if (self.hidesCursor && isOnSurface) {
        [[TUCCursorUtilities sharedInstance] setIsCursorHidden:YES];
    }

    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];

    // Keep the last known position when the lift-off report has none to give. The click this tap
    // is about to produce is posted at `touch.location`, so taking the reported zeroes would put
    // it in the top-left corner of the screen.
    if (!isSuspectOriginReport) {
        [touch setLocation:[self convertDigitizerPointToRelativeScreenPoint:digitizerPoint locationID:locationID]];
    } else {
        [self noteOnceForLocationID:locationID
                               key:@"zeroed-lift"
                           message:@"reports zeroed coordinates on lift-off; keeping the last known position. "
                                    "This is the report `ignoreOriginTouches` used to discard, which left taps unable to click."];
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
        self.cursorTouchBeganTime = [NSDate timeIntervalSinceReferenceDate];
        self.cursorTouchStationaryAnchor = touch.location;
        self.cursorTouchStationarySinceDate = [NSDate date];
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
- (void)updateTapAndHoldStateForCursorTouch:(TUCTouch *)touch onScreen:(TUCScreen *)screen {

    // A touch stays a tap until the finger leaves a slop radius around where it landed.
    // Once it has left, it can never become a tap again.
    if (self.cursorTouchQualifiedForTap
        && [screen millimetreDistanceBetweenRelativePoint:touch.location and:self.cursorTouchOrigin] > self.tapTolerance) {

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
    //
    // Once it has fired the touch is spent. Anything further from it is ignored — a menu is open,
    // and the way to choose from a menu is to tap an item, exactly as with a real right-click.
    if ([self actionForGesture:TUCCursorGestureLongPress] != TUCCursorActionNone) {
        [self performMouseEventForGesture:TUCCursorGestureLongPress];
        self.cursorTouchDidActuateLongPress = YES;
    }
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


    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }


    else if (phase == NSTouchPhaseStationary) {
        [self checkForSecondaryClick];

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
                if (!didActuatePress) {
                    [self performMouseEventForGesture:TUCCursorGestureTap];
                }
            } else {
                [self performMouseEventForGesture:TUCCursorGestureDrag];
            }
        }

        [self stopCurrentGesture];

        // The normal lift already ended the scroll and handed off its flick, so this is a no-op
        // there. It exists for the routes that skip that entirely — a multitouch gesture having
        // taken over, or a touch lost mid-drag — which otherwise left the gesture open for good.
        [[TUCCursorUtilities sharedInstance] cancelScrollGesture];

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
    
    if ([self checkForSecondaryClick]) {
        return;
    }
    
    if ([touches count] == 2 && [touches containsObject: cursorTouch]) {
        TUCTouch *otherTouch = touches[1];
        if (otherTouch.uuid == cursorTouch.uuid) {
            otherTouch = touches[0];
        }
        self.gestureAdditionalTouch = otherTouch;

        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone) {
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

    // Still inside the tap slop: the finger has not travelled far enough to mean anything
    // but a tap yet. Committing to a scroll or a drag here would emit a few pixels of stray
    // movement on every tap — exactly the noise the slop radius exists to absorb.
    if (self.cursorTouchQualifiedForTap) {
        return;
    }

    [self performMouseEventForGesture:TUCCursorGestureDrag];
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
    
    TUCCursorAction action = [self actionForGesture:gesture];
    
    CGFloat doubleClickSpan = self.doubleClickTolerance * [[self touchscreenForLocationID:touch.locationID] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];
    
    switch (action) {
        case TUCCursorActionNone:
            break;
            
        case TUCCursorActionMove:
            [utils moveCursorTo:screenLocation];
            break;
            
        case TUCCursorActionMoveClickIfNeeded:
            [utils moveCursorTo:screenLocation];
            if ([self isLocationOutsideFrontmostWindow:screenLocation locationID:touch.locationID]) {
                // Not `performClickAt:`. This click is ours, not the user's: it exists only to
                // raise the window, and it must stay outside the click sequence so that the
                // real click the same tap produces on lift-off is still counted as the first.
                [utils bringWindowToFrontAt:screenLocation];
            }

            break;
            
        case TUCCursorActionPointAndClick:
            [utils moveCursorTo:screenLocation];
            if (touch.phase == NSTouchPhaseEnded) {
                [utils performClickAt:screenLocation];
            }
            break;
            
        case TUCCursorActionDrag:
            [utils dragCursorTo:screenLocation phase:touch.phase];
            break;
            
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
            
        case TUCCursorActionMagnify:
            [utils magnifyLocationA:screenLocation
                          locationB:location2ndFinger
                         relativeP1:self.cursorTouch.location relP2:self.gestureAdditionalTouch.location];
            
            if (touch.phase == NSTouchPhaseEnded || self.gestureAdditionalTouch.phase == NSTouchPhaseEnded) {
                [utils stopMagnifying];
            }
            break;
    }
}


- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
    
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
- (CGPoint)convertDigitizerPointToRelativeScreenPoint:(CGPoint)devicePoint locationID:(uint32_t)locationID {
    TUCScreen *screen = [self touchscreenForLocationID:locationID];

    // Mirror the glass first, while still in the digitizer's own frame: this corrects how the
    // panel is wired, which is independent of how the display is currently oriented.
    if (self.delegate != nil) {
        if ([self.delegate digitizerIsFlippedHorizontallyForLocationID:locationID]) {
            devicePoint.x = 1 - devicePoint.x;
        }
        if ([self.delegate digitizerIsFlippedVerticallyForLocationID:locationID]) {
            devicePoint.y = 1 - devicePoint.y;
        }
    }

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


- (BOOL)isLocationOutsideFrontmostWindow:(CGPoint)point locationID:(uint32_t)locationID {

    if ([self isPointInMenuBar:point locationID:locationID]) {
        return NO;
    }

    pid_t frontmostPID = [[[NSWorkspace sharedWorkspace] frontmostApplication] processIdentifier];

    CFArrayRef array = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);

    // The window list is ordered front-to-back by window *level* (not grouped by app), so
    // high-level overlays — including our own screenSaver-level panels — come before the
    // active app's normal windows. `behindFrontmostWindow` flips once we pass the active
    // app's topmost window: windows seen before it are stacked above it, windows after are
    // behind it.
    BOOL behindFrontmostWindow = NO;
    BOOL res = NO;

    for (CFIndex i=0; i<CFArrayGetCount(array); i++) {
        CFDictionaryRef dic = CFArrayGetValueAtIndex(array, i);

        CFNumberRef numPid = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
        pid_t currPID;
        CFNumberGetValue(numPid, kCFNumberIntType,  &currPID);
        BOOL isFrontmostApp = currPID == frontmostPID;

        CFDictionaryRef bounds = CFDictionaryGetValue(dic, kCGWindowBounds);
        CGRect nextFrame;
        CGRectMakeWithDictionaryRepresentation(bounds, &nextFrame);
        BOOL isInside = CGRectContainsPoint(nextFrame, point);

        if (isFrontmostApp && !behindFrontmostWindow) {
            behindFrontmostWindow = YES;
        }

        if (!isInside) continue;

        NSString *ownerName = (__bridge NSString *)CFDictionaryGetValue(dic, kCGWindowOwnerName);
        if ([self isSystemChromeOwner:currPID name:ownerName]) {
            continue;
        }

        // First real window under the point = the one the finger actually hits.
        if (isFrontmostApp) {
            res = NO;   // already the active window — the tap actuates it directly
        } else if (!behindFrontmostWindow) {
            res = NO;   // stacked above the active app (an overlay or our own panel) — takes the tap directly
        } else {
            // A background window of another app — normally inject a click to raise it.
            // Exception: the title bar. A background title bar accepts clicks directly, so
            // our injected raise-click plus the tap's own click would register as a
            // title-bar double-click (→ zoom/fullscreen). A single tap already raises the
            // window, so skip the extra click within the title-bar strip.
            //
            // The raise-click no longer seeds a double click — it goes through
            // `-bringWindowToFrontAt:`, which stays out of the click sequence — so this strip
            // should now be redundant and could be dropped to make taps on a background
            // title bar raise the window again. It is kept until that is confirmed on real
            // hardware, because the failure it guards against (a window unexpectedly zooming
            // to fullscreen) is destructive and not worth risking on reasoning alone.
            //
            // CGWindowList can't tell us the actual title-bar/toolbar height, so this is a
            // heuristic constant. Erring high (toolbars on Tahoe are tall) costs at most a
            // missed raise-click near the top of a background window; erring low brings the
            // destructive double-click-zoom back.
            CGFloat titleBarHeight = 44;
            BOOL inTitleBar = (point.y - nextFrame.origin.y) <= titleBarHeight;
            res = inTitleBar ? NO : YES;
        }
        break;
    }

    CFRelease(array);
    return res;
}




#pragma mark -

- (instancetype)init {
    if(self = [super init]) {
        self.touchSet = [NSMutableSet new];
        self.postMouseEvents = YES;
        
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;

        self.frameIDsByLocationID = [NSMutableDictionary new];
        self.notedDeviceObservations = [NSMutableSet new];
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

        [report appendFormat:@"digitizer %#010x -> %@   (extra rotation %+.0f°, mirrored %@)\n",
         locationID,
         screen ? screen.name : @"UNRESOLVED - no screen could be assigned",
         extraRotation,
         flippedH ? (flippedV ? @"H+V" : @"H") : (flippedV ? @"V" : @"no")];
    }

    [report appendString:@"\n───── Parameters ─────\n"];
    [report appendFormat:@"postMouseEvents:      %@\n", self.postMouseEvents ? @"YES" : @"NO"];
    [report appendFormat:@"tapTolerance:         %.2f mm\n", self.tapTolerance];
    [report appendFormat:@"holdDuration:         %.3f s\n", self.holdDuration];
    [report appendFormat:@"doubleClickTolerance: %.2f mm\n", self.doubleClickTolerance];
    [report appendFormat:@"errorResistance:      %ld reports\n", (long)self.errorResistance];
    [report appendFormat:@"ignoreOriginTouches:  %@\n", self.ignoreOriginTouches ? @"YES" : @"NO"];
    [report appendFormat:@"hidesCursor:          %@%@\n",
     self.hidesCursor ? @"YES" : @"NO",
     self.hidesCursor && ![[TUCCursorUtilities sharedInstance] canHideCursorSystemWide]
        ? @" (only while Touch Up is frontmost - the system-wide hook was unavailable)" : @""];

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
