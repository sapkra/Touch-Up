//
//  TUCVirtualTrackpad.h
//  Touch Up Core
//

#ifndef TUCVirtualTrackpad_h
#define TUCVirtualTrackpad_h

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

/**
 A trackpad macOS drives itself, fed from the touchscreen.

 Everything this framework does elsewhere is synthesis: a gesture is recognised here and
 turned into the events it ought to have produced. Scrolling, momentum, pinch and rotate
 are the parts of that which are hardest to get right and least like the real thing,
 because each application treats trackpad input a little differently and none of them can
 be talked into it from outside.

 So those are not synthesised at all. A virtual Magic Trackpad is published, the contacts
 are handed to it, and macOS produces the gestures — with its own momentum, its own
 acceleration, and whatever each application does with a real trackpad.

 **Only ever two fingers or more.** One finger on a trackpad moves the pointer relatively,
 and the whole premise here is that the pointer goes where the finger is. Single-finger
 touches stay with the existing synthesis, which puts them somewhere absolute.

 Requires the entitlement `com.apple.developer.hid.virtual.device`; without it the publish
 fails and the caller is expected to carry on synthesising. The report format is Apple's
 and undocumented — see `spike/virtual-digitizer/FINDINGS.md` for how it was established
 and what it cost to find out — so treat a working device as something that can stop
 working, and keep the fallback intact.
 */

/// One contact, in the same normalised space as `TUCTouch.location`: 0…1 across the panel
/// and 0…1 down it, already mirrored and rotated to match the screen.
typedef struct {
    double x;
    double y;
    /// Stable for the life of the contact. Anything outside 1…15 is folded into range.
    uint8_t identifier;
} TUCVirtualContact;

/// Creates the device and answers the interrogation macOS makes of it. Returns false when
/// the entitlement is missing or the kernel refuses; the caller keeps synthesising.
bool TUCVirtualTrackpadPublish(void);

/// Ends any gesture in flight and destroys the device.
void TUCVirtualTrackpadRetire(void);

/// Whether a device exists. Says nothing about whether macOS is driving it.
bool TUCVirtualTrackpadIsPublished(void);

/**
 Whether the multitouch driver has adopted the device and would act on what it is sent.

 Worth checking rather than assuming: publishing succeeds whether or not anything binds,
 and a device nothing has adopted swallows every frame in silence. This is what tells the
 caller to go back to synthesising rather than sending gestures into a void.
 */
bool TUCVirtualTrackpadIsDriven(void);

/// One frame of contacts. The first after an idle period opens the gesture; the timestamp
/// advances on its own, which matters — the system drops frames it considers duplicates.
void TUCVirtualTrackpadSubmit(const TUCVirtualContact *contacts, size_t count);

/// Closes the gesture: the fingers have gone. Momentum afterwards is the system's business.
/// Doing nothing if no gesture is in flight is safe and cheap.
void TUCVirtualTrackpadLiftoff(void);

#endif /* TUCVirtualTrackpad_h */
