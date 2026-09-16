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

B4 tested nothing useful, and worse than that, it tested the wrong hardware. The
touchscreen this project exists for was never connected to the spike machine, so the
capture took the first digitizer-ish device it found — that machine's own pointing device
— and cloned it. Everything said about "the panel declaring `13/5 TouchPad`" refers to
that, not to any touchscreen. Nothing is known here about how the real panel announces
itself, and nothing needs to be: the route that worked fabricates its own descriptor.

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

## Round 3 — geometry was not the missing piece

Seven variants, same machine. Adoption reproduced exactly: B3, B1, B5, B6 and B7 claimed;
B2 and B4 not. **Touches delivered: zero, in every case.**

The geometry properties did reach our HID device — B5, B6 and B7 carry
`Sensor Surface Width`/`Height`, `Sensor Rows`/`Columns`, the region descriptors and
`MTHIDDevice`, where B3 and B1 carry none. But they went no further. The
`AppleMultitouchDevice` created underneath is identical either way:

```
"Multitouch ID", "MT Built-In", "Multitouch Serial Number", "Max Packet Size" = 1024,
"parser-type" = 1, "parser-options" = 16, "DeviceUsagePairs", "Transport" = "Virtual",
"Product", "HIDServiceSupport", plus IOKit bookkeeping
```

No sensor geometry, no `Family ID`, no surface descriptors — with or without our
properties, and regardless of `Family ID` being declared (B6 behaves as B5).

So the multitouch driver does not take geometry from IOKit properties. The real trackpad's
surface descriptors come from the device itself, through the multitouch protocol, and a
device that answers nothing never gets past being an empty shell. B5 and B6 also fed no
reports at all — there is no known report layout for the vendor page — so the one
informative feed was B7: Apple's own descriptor, geometry attached, 60 frames of a
two-contact sweep, nothing out.

## Where the wall is

Everything up to the protocol works, and nothing beyond it does:

- a third-party process **can** publish a virtual HID device (needs the entitlement, which
  is grantable);
- that device **is** adopted by `AppleMultitouchHIDService`, without impersonating Apple;
- the adopted device produces **no touch events**, because it does not speak Apple's
  multitouch protocol (`parser-type 1`), which is undocumented, and there is no reference
  to copy — Sidecar reaches the event system by a different, private route entirely.

What would be needed next is emulating that protocol: answering whatever the driver asks
of a device during setup, then emitting frames in the binary format of some multitouch
family. That is reverse engineering of an interface Apple has never published, with no
compatibility promise, in a code path that already has a working alternative.

One cheap probe remains before giving up on it: register a `GetReport` handler on the
virtual device and log what the multitouch driver asks for. If it requests feature reports
during setup, their IDs and lengths are a map of what it wants. If it asks for nothing,
the protocol is input-report-driven and the only way forward is guessing, which is where
this should stop.

## Round 5 — a trustworthy negative

Rounds 1–4 measured touch delivery through a 900×700 window while the synthetic sweep
crossed most of a 2560-wide display, so every "no touches" reading was taken through an
instrument that could not tell silence from a miss. Round 5 fixed that: the window covers
the screen and floats, and the publisher records the pointer position around each sweep —
an oracle that needs no window, no focus and no permission.

**Pointer movement: none, on every variant.** Every report was accepted by the kernel (no
error returns from `IOHIDUserDeviceHandleReportWithTimeStamp`) and acted on by nothing.

The decisive variant is B8: an ordinary Windows-style touchscreen, standard contacts,
standard reports, adopted by the generic `AppleUserHIDEventDriver`, with the display duly
reporting `multiTouch=true`. It produced nothing at all — **which is exactly what macOS
does with a real USB touchscreen, and is the reason this project exists.** B8 faithfully
reproduced the status quo.

## Conclusion: the native touch path is not reachable from a HID device

The answer to "can Touch Up use the macOS 27 touch APIs" is no, and the evidence is now
specific about why:

- `NSScreen.touchCapabilities` flips to true for any `0x0D/0x04` device, so AppKit's
  *capability advertisement* is driven by HID usage. That is all it is — an advertisement.
  No events follow.
- Direct touch reaches applications through `IOHIDVirtualService`, which Sidecar drives
  under `com.apple.private.hid.client.event-dispatch`. Private, not issuable to third
  parties, and confirmed live: Sidecar's touchscreen exists in the HID service list with
  no registry object, no descriptor and no readable properties.
- `AppleMultitouchHIDService` *will* adopt a third-party virtual device, without any
  impersonation — but it then expects Apple's undocumented multitouch protocol, and no
  amount of geometry supplied through IOKit properties substitutes for it.

So there are two doors. One is private. The other opens onto a protocol with no
specification and no reference implementation to copy.

## What is worth doing instead

1. **Keep the existing CGEvent synthesis.** It works, and nothing found here improves on it.
2. **File the Feedback Assistant report** (drafted in `FEEDBACK.md`). The evidence is
   unusually concrete, and the ask is small and specific.
3. **Report `NSScreen.touchCapabilities` in diagnostics** — ten lines, and it distinguishes
   "this user has a Sidecar iPad" from "this user has a third-party panel", which produce
   very different bug reports.

A direction deliberately not pursued: emulating a Magic Trackpad rather than a touchscreen.
`AppleMultitouchHIDService` adoption already works, and Apple drives real Magic Trackpads
over HID, so native scroll, pinch and swipe might be reachable that way. It would mean
indirect input — relative pointer motion, losing the absolute "touch what you want" premise
unless combined with the current synthesis — and it still requires the same undocumented
protocol. Worth remembering, not worth starting today.

## Round 6 — it works

Emulating a Magic Trackpad 2 succeeds where six rounds of touchscreens failed.

**C1 — one finger.** The driver interrogated the device (`GET 0x00`, `SET 0x01`+selector,
`GET 0x01`, `GET 0xDB` → 72 bytes, `GET 0x7F`, then `SET 0x02` to enable multitouch),
believed the answers, and **moved the pointer 700 points**. `AppleMultitouchTrackpadHIDEventDriver`
bound the device — a driver no earlier round reached — and the `AppleMultitouchDevice` it
created carries 68 properties instead of 11, every sensor value read back from our replies:

```
Family ID = 129          Sensor Rows = 22        Sensor Columns = 30
Sensor Surface Width = 15600   Sensor Surface Height = 11040
Sensor Surface Descriptor = <f03c0000202b000044e352ffbd1ee426>    (our bytes)
```

The silence through rounds 1–5 was never a protocol we couldn't guess. It was a
conversation we never answered: no get-report handler was registered at all, so the driver
asked what the device was, heard nothing, and waited.

**C3 — two fingers.** 112 scroll events, and **the pointer did not move** (2264,210 →
2264,210). The phases tell the story:

```
phase=1  ×  1     began
phase=4  × 65     changed
phase=8  ×  1     ended
phase=0  × 45     momentum, decaying to dy=0
```

macOS generated the momentum itself. That is the machinery `TUCCursorUtilities`
hand-rolls today — velocity smoothing, flick seeding, sub-pixel carry, cancellation — all
of it replaced by the system's own, with correct per-application behaviour for free.

**C2 is dead.** Feeding 96-byte `MTContact` records on usage 7 was adopted and silent.
The Magic Trackpad route is the live one.

## The hybrid is real

The division of labour holds exactly as hoped, and is now measured rather than assumed:

| Fingers | Path | Evidence |
|---|---|---|
| One | Existing CGEvent synthesis — absolute positioning, clicks, drags, surface classification | C1: a single finger on a trackpad *moves the pointer*, which is why it must not go here |
| Two or more | Virtual Magic Trackpad — native scroll, pinch, rotate, swipes | C3: scroll delivered, pointer untouched, momentum from the system |

What it costs, stated plainly:

- The entitlement `com.apple.developer.hid.virtual.device` is required, and AMFI enforces
  it, so development needs either the grant or a reduced-security machine. It is now worth
  requesting: we can show it works.
- The device must claim to be Apple hardware — vendor `0x05AC`, product `0x0265`,
  "Magic Trackpad 2" — because that is what the trackpad driver matches. Unlike the earlier
  manufacturer-string question, there is no honest variant of this known. It is a decision
  to take deliberately, not a detail.
- The protocol is private and undocumented. It will break without warning, so the watchdog
  fallback to synthesis is mandatory, not optional.
