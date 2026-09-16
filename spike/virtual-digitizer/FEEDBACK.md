# Feedback Assistant draft

Suggested area: macOS → Hardware / Input Devices. Attach `results/` and `FINDINGS.md`.

---

**Title:** No supported way for a third-party touchscreen to deliver direct touch on macOS 27

**Summary**

macOS 27 delivers direct touch to applications through gesture recognizers, which is a
welcome addition, but the only input source that can feed it appears to be Sidecar. A
third-party USB touchscreen — or a virtual HID device published by a third-party
application — cannot deliver touch events by any documented means. I would like either a
documented way in, or for one of the two existing paths to be opened.

**What I tried**

I publish a virtual HID device with `IOHIDUserDeviceCreateWithProperties` (entitlement
`com.apple.developer.hid.virtual.device`) and feed it input reports. Eight configurations,
on macOS 27.0 (26A428), Apple Silicon:

1. An ordinary Windows-style touchscreen: usage `0x0D/0x04`, standard `Tip Switch`,
   `Contact Identifier`, 16-bit X/Y, `Contact Count`; reports in the matching layout.
   Adopted by `AppleUserHIDEventDriver`. `NSScreen.touchCapabilities` reported
   `multiTouch` on the display. **No touch events, no gesture-recognizer callbacks, and no
   pointer movement.** All reports were accepted (`IOHIDUserDeviceHandleReportWithTimeStamp`
   returned `kIOReturnSuccess`).
2. The same device on the vendor page `0xFF60`/usage 7 with `parser-type = 1`,
   `parser-options = 16`, `HIDServiceSupport = true`. This matches the `MTUserDevice`
   personality in `AppleMultitouchDriver.kext` and **was adopted by
   `AppleMultitouchHIDService`**, creating an `AppleMultitouchDevice`. That device carries
   none of the sensor geometry a working one has (`Sensor Surface Width`/`Height`,
   `Sensor Rows`/`Columns`, `Sensor Region Descriptor`, `Family ID`), and supplying those
   as IOKit properties on the HID device does not propagate them. No events resulted.
3. Variants isolating the manufacturer condition: with Apple's own touchscreen report
   descriptor and `Manufacturer = "Apple"`, `AppleMultitouchHIDService` adopts the device;
   with an honest manufacturer string and the same descriptor, it does not, and
   `AppleUserHIDEventDriver` takes it instead. The `(0x0D,0x04)` personality in
   `AppleMultitouchDriver.kext` requires `Manufacturer == "Apple"`.

**What the platform appears to require**

Sidecar does not publish a HID device for touch. With an iPad connected, its touchscreen
appears in `hidutil list` (`VendorID 0x5ac`, `ProductID 0x8600`, usage `13/4`) with no
IORegistry object, no report descriptor and no readable properties — it is an
`IOHIDVirtualService`, dispatched via `IOHIDVirtualServiceClientDispatchEvent` under
`com.apple.private.hid.client.event-dispatch`. That entitlement is not available to
third-party developers.

So the two routes into the touch pipeline are a private entitlement, and an undocumented
multitouch protocol behind a manufacturer check.

**What I am asking for**

Any one of these would be sufficient:

1. Deliver direct touch events from ordinary HID digitizers on usage `0x0D/0x04`, as the
   platform already does for Sidecar. `NSScreen.touchCapabilities` already reports such a
   display as touch-capable, so the capability is advertised while no events follow.
2. Document the multitouch protocol expected by the `MTUserDevice` personality — the
   sensor descriptors and frame format — so a virtual device that is already adopted can
   be driven.
3. Or make `com.apple.developer.hid.virtual.device` sufficient to dispatch digitizer
   events through `IOHIDVirtualServiceClient`, which is already exported from `IOKit.tbd`
   while its entitlement is private.

**Why it matters**

Touchscreens that work out of the box on Windows do nothing on a Mac. macOS 27 is the
first release with a real touch story, and third-party displays are excluded from it by
mechanism rather than by design intent, as far as I can tell. Option 1 would make every
standards-compliant touchscreen work on macOS with no work by the vendor.

**Attached:** full `ioreg` dumps per configuration, the report descriptors used, and the
harness that produced them.
