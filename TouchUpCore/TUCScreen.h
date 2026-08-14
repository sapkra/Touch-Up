//
//  TUCScreen.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 21.03.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Where `-effectivePhysicalSize`'s answer came from.

 Worth reporting, because every millimetre threshold in the gesture engine is only as trustworthy as
 this one number. When it is `Assumed`, "2.5 mm" is not a measurement — it is `frame.size` divided by
 a guessed density, and on a panel driven at its native pixel grid that guess can be out by a factor
 of three, which scales *every* threshold at once. A diagnostics report that prints the millimetres
 without saying where they came from reads as though they had been measured, which is how the same
 misconfiguration gets investigated repeatedly.
 */
typedef NS_ENUM(NSUInteger, TUCPhysicalSizeSource) {
    /// The panel's own EDID, by way of `CGDisplayScreenSize`. Trustworthy.
    TUCPhysicalSizeSourceEDID = 0,

    /// EDID reported nothing usable, so the size is derived from `frame` and an assumed density.
    /// Every millimetre figure on this screen is a guess of the same accuracy.
    TUCPhysicalSizeSourceAssumed,
};

/// For diagnostics: `"EDID"` or `"assumed"`.
extern NSString *TUCPhysicalSizeSourceName(TUCPhysicalSizeSource source);


/**
 `TUCScreen` describes one physically connected display panel.

 Unlike `NSScreen`, a `TUCScreen` exists for every connected panel — including the
 individual members of a hardware-mirror set, which AppKit collapses into a single
 `NSScreen`. The list therefore always has exactly one entry per panel.

 Properties are split into two groups:

 - **native**: fixed characteristics of the hardware as it was built. They never change
   when the user rotates the display in System Settings.
 - **logical**: the current desktop arrangement and rotation, taken from the matching
   `NSScreen`. For a mirrored secondary panel (which has no `NSScreen` of its own) these
   describe the mirror master's content that the panel is showing.
 */
@interface TUCScreen : NSObject

#pragma mark Identity

/// The `CGDirectDisplayID` of the panel.
@property NSUInteger id;
/// Stable across launches and screen rearrangements; unique per physical panel.
@property (strong) NSString *uuid;
/// Human-readable display name.
@property (strong) NSString *name;

#pragma mark Native hardware (this panel's own EDID, mirror-independent)

/// This panel's own pixel grid, e.g. 3840 × 2160. Unlike `logicalResolution` it is the
/// panel's own hardware even while mirroring, but its width/height swap with `rotation`.
@property CGSize nativeResolution;
/// This panel's own physical size in millimetres, e.g. 600 × 340. Mirror-independent,
/// but its width/height swap with `rotation`.
@property CGSize nativePhysicalSize;

#pragma mark Logical layout (reflects the current arrangement & rotation)

/// Logical rotation in degrees: 0 / 90 / 180 / 270.
@property CGFloat rotation;
/// Framebuffer pixel resolution in the current orientation (points × backing scale).
@property CGSize logicalResolution;
/// Placement of the panel in the global, top-left-origin layout space (points).
/// `frame.size` is the logical (rotated) size.
@property CGRect frame;

#pragma mark -

/// Points per millimetre in the current on-screen orientation.
- (CGFloat)pixelsPerMM;
- (CGPoint)convertPointRelativeToAbsolute:(CGPoint)relativePoint;

/// `nativePhysicalSize`, guaranteed to be usable for distance maths. Panels that report no
/// (or a nonsensical) EDID size fall back to an assumed density, so millimetre thresholds
/// never collapse to zero or blow up to infinity.
- (CGSize)effectivePhysicalSize;

/// Whether `-effectivePhysicalSize` measured or guessed. Check before believing any millimetre
/// figure derived from this screen.
- (TUCPhysicalSizeSource)physicalSizeSource;

/// The fraction of the panel glass the drawn content occupies on each axis, as applied by
/// `-convertGlassPointToContentPoint:`. `{1, 1}` means the content fills the panel; anything less
/// means macOS is letterboxing, and touches near the affected edges are being rescaled.
- (CGSize)contentFractionOfGlass;

/// Physical distance in millimetres between two points given in this screen's relative
/// content coordinates (each axis normalised to [0,1]). Each axis is scaled by its own
/// physical extent, so the result stays correct on non-square panels.
- (CGFloat)millimetreDistanceBetweenRelativePoint:(CGPoint)p1 and:(CGPoint)p2;

/// Maps a point normalised over the full panel glass (in this screen's orientation) to one
/// normalised over the letterboxed content rectangle macOS actually draws
/// The result is clamped to [0,1]; touches on the bars snap to the edge.
- (CGPoint)convertGlassPointToContentPoint:(CGPoint)glassPoint;

/// The `NSScreen` backing this panel. For a mirrored secondary this is the mirror
/// master's `NSScreen`, since that is where the panel's content lives.
- (nullable NSScreen *)systemScreen;

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
               frameOfFirstScreen:(CGRect)firstFrame;

+ (NSArray<TUCScreen *> *)allScreens;

@end

NS_ASSUME_NONNULL_END
