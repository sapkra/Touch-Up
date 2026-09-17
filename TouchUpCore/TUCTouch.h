//
//  TUCTouch.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN


typedef NS_OPTIONS(NSUInteger, TUCCursorGesture) {
    _TUCCursorGestureNone           = 0,       // internal, used if two finger gesture not identifed yet
    TUCCursorGestureTouchDown       = 1 << 1,
    TUCCursorGestureTap             = 1 << 2,
    TUCCursorGestureLongPress       = 1 << 3,
    TUCCursorGestureDrag            = 1 << 4,
    TUCCursorGestureHoldAndDrag     = 1 << 5,
    TUCCursorGestureTwoFingerDrag   = 1 << 7,
    TUCCursorGesturePinch           = 1 << 8, // internal: pinch cannot be remapped

    // Three or more fingers travelling together. Direction is in the gesture rather than passed
    // alongside it so each one can be mapped separately, the way the trackpad pane does.
    TUCCursorGestureSwipeLeft       = 1 << 9,
    TUCCursorGestureSwipeRight      = 1 << 10,
    TUCCursorGestureSwipeUp         = 1 << 11,
    TUCCursorGestureSwipeDown       = 1 << 12
};


typedef NS_ENUM(NSUInteger, TUCCursorAction) {
    TUCCursorActionNone,
    TUCCursorActionMove,
    TUCCursorActionMoveClickIfNeeded,  // moves cursor: if location is not in frontmost window, click first to bring that to front
    TUCCursorActionPointAndClick, // like move, but clicks on release
    TUCCursorActionDrag,
    TUCCursorActionClick,
    TUCCursorActionSecondaryClick,
    TUCCursorActionScroll,
    TUCCursorActionMagnify,

    // Whole-system navigation, delivered as the keyboard shortcuts macOS already assigns to it.
    TUCCursorActionSpacePrevious,
    TUCCursorActionSpaceNext,
    TUCCursorActionMissionControl,
    TUCCursorActionApplicationWindows
};



/**
 What a digitizer's HID descriptor claims it is.

 Worth distinguishing from "may it drive the pointer", which is one bit derived from this plus the
 user's decision. A panel that only admits to being a `Digitizer`, or claims to be a `TouchPad`, is
 the usual reason a screen does nothing on plugging in — and it is also a reason to be less willing
 to read a gesture as direct manipulation of whatever is under it, since a device that is not a
 screen has nothing under it.
 */
typedef NS_ENUM(NSUInteger, TUCDigitizerKind) {
    /// Nothing is registered for that location ID, or its descriptor would not say.
    TUCDigitizerKindUnknown = 0,
    TUCDigitizerKindTouchScreen,
    TUCDigitizerKindTouchPad,
    /// Declares itself a digitizer without saying which sort.
    TUCDigitizerKindDigitizer,
};


/**
 What sort of thing a finger landed on.

 The point of knowing is that one finger cannot mean the same thing everywhere: a flick over a list
 should scroll it, the same flick over a window's title bar should move the window, and over a slider
 it should move the slider. Nothing about a touch report says which of those is under the finger, so
 it has to be asked separately — see `-classifiesSurfaces`.
 */
typedef NS_ENUM(NSUInteger, TUCSurfaceKind) {
    /**
     Nothing could be established.

     Zero, like `_TUCCursorGestureNone`, so an uninitialised field means "no information" and every
     default is the cautious one. Deliberately distinct from `TUCSurfaceKindContent`: a failed read
     is not the same answer as a successful read of something ordinary, and treating it as one would
     mean an application that is merely busy gets acted on as though it had been understood.
     */
    TUCSurfaceKindUnknown = 0,

    /// The desktop, and the icons on it. Dragging here selects or moves; it never scrolls.
    TUCSurfaceKindDesktop,

    /// Title bars, toolbars, the Dock, the menu bar. Dragging moves the thing itself.
    TUCSurfaceKindWindowChrome,

    /// A web page, a list, a document — something whose content moves under a flick.
    TUCSurfaceKindScrollArea,

    /// A slider, a scroll bar, a stepper. Follows the finger from the first movement, and must
    /// never be scrolled: scrolling a slider does nothing at all.
    TUCSurfaceKindControl,

    /// Somewhere text can be typed and selected.
    TUCSurfaceKindTextArea,

    /// Read successfully, and it is none of the above — a plain window interior.
    TUCSurfaceKindContent,
};


/// How much a `TUCSurfaceKind` is worth, which is not the same question as what it says.
typedef NS_ENUM(NSUInteger, TUCSurfaceSource) {
    TUCSurfaceSourceNone = 0,

    /**
     Established from window ownership and geometry alone.

     Certain about where windows are and who owns them, and guessing about anything inside one. A
     window with no accessibility support looks identical to a full-screen game, so an answer from
     here may only ever be used to *suppress* something — never to start a drag, which is the one
     mistake with consequences the user has to undo.
     */
    TUCSurfaceSourceWindowList,

    /// The element under the finger answered for itself.
    TUCSurfaceSourceAXElement,
};


/// Whether the surface is known yet, and whether waiting would help.
typedef NS_ENUM(NSUInteger, TUCSurfaceState) {
    /// Not asked, or not wanted.
    TUCSurfaceStateNone = 0,
    /// Asked; the answer has not arrived. It may still arrive, or it may not.
    TUCSurfaceStatePending,
    /// Answered.
    TUCSurfaceStateKnown,
    /// Asked, and no answer is possible — nothing there can be read. Waiting is pointless.
    TUCSurfaceStateUnavailable,
};


/**
 Everything known about the circumstances of a gesture, beyond the gesture itself.

 An object rather than more selector parameters because this is the third time deciding what a
 gesture should do has turned out to need something `-actionForGesture:` does not carry — first
 which digitizer, then what is under the finger, then what sort of device it came from. Each of
 those as its own selector would be another `respondsToSelector:` branch that never goes away; as a
 property on one object, the next of them costs nothing.

 Immutable, and safe to hold: it copies what it was told rather than referring to a live touch.
 */
@interface TUCGestureContext : NSObject

/// What the finger is on, as far as anything could tell.
@property (readonly) TUCSurfaceKind surface;

/// How `surface` was arrived at. Check this before acting on anything irreversible.
@property (readonly) TUCSurfaceSource surfaceSource;

/// Whether an answer is still coming. `Pending` means the mapping should fall back rather than wait.
@property (readonly) TUCSurfaceState surfaceState;

/// What the digitizer says it is.
@property (readonly) TUCDigitizerKind digitizerKind;

/// Which digitizer the finger is on.
@property (readonly) uint32_t locationID;

/// Where the finger is, in global top-left-origin points — the space `CGEvent` uses.
@property (readonly) CGPoint screenLocation;

/// Whether this touch had already been held still long enough to count as a hold.
@property (readonly) BOOL didHold;

- (instancetype)initWithSurface:(TUCSurfaceKind)surface
                         source:(TUCSurfaceSource)source
                          state:(TUCSurfaceState)state
                  digitizerKind:(TUCDigitizerKind)digitizerKind
                     locationID:(uint32_t)locationID
                 screenLocation:(CGPoint)screenLocation
                        didHold:(BOOL)didHold NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end


@interface TUCTouch : NSObject

@property (strong) NSUUID *uuid;

/**
 One finger, for as long as it is on the glass — and unlike `contactID`, ours rather than
 the digitizer's.

 A panel is free to stop reporting a contact and start reporting the same finger under a
 different contact ID a few milliseconds later, and several of them do. Anything that has
 to keep calling the same finger the same thing across reports has to key off something the
 panel cannot change underneath it, which is this.

 Distinct from `uuid` only in being cheap to compare and to put in a report. Both last the
 life of the touch.
 */
@property (readonly) NSUInteger identity;

/**
 Rises whenever a deferred removal is scheduled, and again whenever the touch is resumed.

 A `dispatch_after` cannot be called off once scheduled, so the block carries the value it
 was scheduled under and does nothing if it no longer matches. Without it, a touch that is
 resumed after ending would be deleted half a second later by a timer belonging to the life
 it had before.
 */
@property (readonly) NSUInteger removalGeneration;

/// The contact ID this touch had before it was resumed under another, or `NSNotFound`.
/// Diagnostics, and how a repair that the panel later contradicts is noticed.
@property (readonly) NSInteger previousContactID;

/// How many times this finger has been resumed under a new contact ID.
@property (readonly) NSUInteger timesResumed;

/// Retires any pending deferred removal, so it will not fire against this touch.
- (void)invalidatePendingRemoval;

/**
 Takes over a contact ID the digitizer has started using for this same finger.

 Keeps everything that makes it the same touch: where it is, where it was, when it landed,
 its identity and its uuid — so the gesture state held elsewhere against this object stays
 attached to it. Only the contact ID changes, and the phase, which becomes `Stationary`
 because the touch is still down and what it is doing is about to be recomputed from its
 real movement.
 */
- (void)resumeUnderContactID:(NSInteger)contactID;
@property NSInteger contactID;
@property uint32_t locationID;

@property BOOL isOnSurface; //tip

/**
 Whether the digitizer is confident this contact is a fingertip rather than a palm or a sleeve.

 This is HID's `TouchValid` usage, and its sense is the one the specification gives it: **true
 means trust this contact**. It was previously carried under a name that said the opposite, which
 mattered the moment anything acted on it.

 Defaults to true, and stays true for the whole of a touch on a panel whose descriptor omits the
 usage — which is most of them. A contact nobody has expressed an opinion about is a finger; the
 alternative reading would reject every touch on every screen that does not report confidence.
 */
@property BOOL isConfidentFinger;

@property CGSize size;
@property CGFloat azimuth;

@property (nonatomic) NSTouchPhase phase;
@property NSTouchPhase previousPhase;

@property (nonatomic) CGPoint location;
@property CGPoint previousLocation;

@property NSInteger lastUpdated; // the page ID during last update

/// Wall-clock time of the last report for this touch, as a `timeIntervalSinceReferenceDate`.
/// `lastUpdated` counts HID reports, which only advance while the device has something to say —
/// so it measures activity, not elapsed time, and cannot answer "was this touch on the glass at
/// the same moment as that one".
@property NSTimeInterval lastUpdatedTime;


- (instancetype)initWithContactID:(NSInteger)contactID locationID:(uint32_t)locationID;



- (BOOL)isActive;

- (NSComparisonResult) compareWithAnotherTouch:(TUCTouch*) anotherTouch;

- (CGPoint)trajectory;
- (CGPoint)trajectorySign;

@end

NS_ASSUME_NONNULL_END
