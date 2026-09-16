# Findings

## Round 1 — can a third-party virtual device reach the native touch path?

Run on macOS 27.0 with AMFI not enforcing. Verdicts below come from walking the subtree
under our own serial number; the summary the script printed at the time was wrong (it
counted `AppleMultitouch` anywhere in the dump, which matches the built-in trackpad).

| Variant | Descriptor | Manufacturer | Outcome |
|---|---|---|---|
| **B3** | vendor `0xFF60`/usage 7 + `parser-type=1`, `parser-options=16`, `HIDServiceSupport` | `"Touch Up"` | **Claimed** by `AppleMultitouchHIDService` |
| B1 | Sidecar's 256-byte descriptor | `"Apple"` | **Claimed**, plus an `AppleMultitouchDeviceUserClient` |
| B2 | Sidecar's descriptor | `"Touch Up"` | Not claimed — `AppleUserHIDEventDriver` only |
| B4 | a real panel's descriptor | `"Apple"` | Not claimed — see below |

**The native path is reachable without impersonating Apple.** B3 is the `MTUserDevice`
personality, which carries no manufacturer condition, and it bound to a device announcing
itself honestly.

B1 versus B2 differ only in the manufacturer string, so the `Manufacturer == "Apple"`
condition on the `(0x0D,0x04)` personality is real and enforced. That is the argument for
building on B3 rather than B1.

B4 tested nothing useful: the panel declares
`{1/2 mouse, 1/1 pointer, 13/5 TouchPad, 65280/12}` — TouchPad, not TouchScreen, with a
mouse collection first — so it never matched the personality. Its failure says nothing
about whether a cloned descriptor parses.

**But no touches came out of any of them.** Zero gesture-recognizer callbacks. The reason
is visible in the registry: our claimed multitouch device has 17 properties where the
built-in trackpad's has 62, and everything describing a *surface* is missing —
`Sensor Surface Width`/`Height`, `Sensor Rows`/`Columns`, `Sensor Surface Descriptor`,
`Sensor Region Descriptor`/`Param`, `Family ID`, `MTHIDDevice`, `HSTouchHIDService`.
The device is instantiated but has no geometry to map a contact onto.

## Round 2 — what Sidecar actually does (and why we cannot copy it)

Captured with an iPad connected over Sidecar, touch working. `NSScreen.touchCapabilities`
reported `multiTouch=true` on **both** screens, built-in included, exactly as TN3212
describes. So the session was genuinely touch-capable.

Sidecar's touchscreen appears in `hidutil list`:

```
VendorID ProductID LocationID UsagePage Usage RegistryID       Transport Class  Product
0x5ac    0x8600    0x0        13        4     0x7bbb6ff4000001 (null)    (null) (null)
```

and **nowhere else**. It is not in the IORegistry at all (`ioreg -l | grep 7bbb6ff4` →
no hits), it has no `ReportDescriptor`, and every property reads back null. Its registry
ID is not an IORegistry object id.

So Sidecar does not publish a HID device for touch. It creates an `IOHIDVirtualService`
and dispatches `IOHIDEvent`s into the event system directly — the
`IOHIDVirtualServiceClientCreate` / `…DispatchEvent` imports in the binary, gated by
`com.apple.private.hid.client.event-dispatch`. That entitlement is Apple-private and not
issuable to third parties.

Two consequences:

1. **Sidecar's recipe is closed to us**, and the touchscreen descriptor embedded in
   `SidecarDisplayAgent` is not what carries touch in a live session. Whatever it is for,
   it is not the path being exercised.
2. **Our route is a different door, and it is open.** `AppleMultitouchHIDService` binding
   to a third-party `IOHIDUserDevice` is something Sidecar never does. B3 stands on its
   own evidence.

## Where this leaves the idea

Reachable, unproven. Getting claimed was the hard gate everyone assumed would fail, and
it does not. What remains is making a claimed device actually emit touches, which needs
sensor geometry and a report format the Apple multitouch parser accepts. There is no
reference implementation available to copy: Sidecar's is a different mechanism, and the
only worked example on the machine is the built-in trackpad (`Family ID` 106,
`Sensor Surface Width` 15780, `Height` 9780, 18 rows × 24 columns), whose frame format is
Apple-internal.

Cheapest next experiment, needing no iPad: republish B1 and B3 **with** sensor-geometry
properties copied in shape from the trackpad, feed the same sweep, and see whether
anything arrives. If geometry alone is enough, the format question may answer itself. If
not, the remaining work is reverse-engineering Apple's multitouch frame format, which is
a different size of undertaking and considerably more fragile than the plan assumed.
