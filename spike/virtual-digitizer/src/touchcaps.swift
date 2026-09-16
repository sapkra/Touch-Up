// Oracle 1: does any screen report multi-touch capability?
//
// Per TN3212 this returns true for EVERY screen when a touch-capable Sidecar display
// is connected — so keep the iPad unplugged while running the spike, or this says
// "yes" regardless of what the virtual device did.
import AppKit
import ApplicationServices
import IOKit.hid

// Permission state, recorded rather than assumed. A real USB touchscreen needs no
// permission for its events to flow, and our virtual device sits at the same layer —
// but "did you grant something in Privacy & Security" is a fair question to ask of a
// silent device, so the answer belongs in the evidence.
let trusted = AXIsProcessTrusted()
let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
let post = IOHIDCheckAccess(kIOHIDRequestTypePostEvent)
func describe(_ access: IOHIDAccessType) -> String {
    switch access {
    case kIOHIDAccessTypeGranted: return "granted"
    case kIOHIDAccessTypeDenied: return "denied"
    default: return "unknown/not requested"
    }
}
print("accessibility (AXIsProcessTrusted): \(trusted)")
print("input monitoring (listen events):   \(describe(listen))")
print("post events:                        \(describe(post))")

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
