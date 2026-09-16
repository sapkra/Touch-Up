// Oracle 1: does any screen report multi-touch capability?
//
// Per TN3212 this returns true for EVERY screen when a touch-capable Sidecar display
// is connected — so keep the iPad unplugged while running the spike, or this says
// "yes" regardless of what the virtual device did.
import AppKit

let screens = NSScreen.screens
print("screens: \(screens.count)")
var any = false
for screen in screens {
    let caps = screen.touchCapabilities
    let multi = caps.contains(.multiTouch)
    any = any || multi
    print("  \(screen.localizedName): multiTouch=\(multi) raw=\(caps.rawValue)")
}
print("ORACLE1: \(any ? "SOME SCREEN REPORTS MULTITOUCH" : "no screen reports multitouch")")
