# Virtual digitizer spike (E2)

Answers one question: **does macOS 27 claim a virtual HID digitizer published by a
third-party process, and does native touch come out the other end?**

That determines whether Touch Up can drive the Mac through the native touch path
instead of synthesizing CGEvents. If nothing claims the device, the native path is
closed and there is no point requesting the entitlement from Apple.

## Why this needs a second Mac

Publishing any virtual HID device requires `com.apple.developer.hid.virtual.device`.
AMFI treats it as restricted: a binary carrying it is `SIGKILL`ed before `main()` runs
unless a provisioning profile grants it. Verified on the main Mac — ad-hoc signing,
Apple Development signing and a sandboxed app bundle were all killed (exit 137), while
the same binaries without the entitlement ran fine and were simply refused by the kernel.

So either Apple grants the entitlement first, or the check runs on a machine where AMFI
is not enforcing. This kit is the second route.

## Requirements

- A Mac running **macOS 27** (`sw_vers`). Results from any other version say nothing
  about this question.
- **Xcode Command Line Tools** (`xcode-select --install`) — needs `clang` and `swiftc`.
- **No iPad connected over Sidecar.** Per TN3212, a connected touch-capable Sidecar
  display makes `NSScreen.touchCapabilities` report multi-touch on *every* screen, which
  is one of the oracles here. It would read as success no matter what the spike did.

## Setting up the test machine

This lowers the machine's security. Do it on a spare Mac, and undo it afterwards.

**Apple Silicon**

Reduced Security is not the target — **Permissive Security** is. Custom boot args are
gated separately, as `bputil -h` on this machine spells out:

```
-a, --disable-boot-args-restriction
    Enables sending custom boot args to the kernel
    Automatically downgrades to Permissive Security mode if not already true
```

The two checkboxes in the Startup Security Utility's Reduced Security pane are **not**
needed and do not help here. They correspond to `bputil -m` (MDM management of software
updates and kernel extensions) and `bputil -k` (trust in third-party kexts) — this spike
loads no kernel extension.

1. Shut down. Hold the power button until "Loading startup options" appears.
2. **Options → Continue**, pick the system disk, authenticate.
3. **Utilities → Terminal**, then `csrutil disable` and confirm. This is the step that
   matters; it moves the policy to Permissive Security. (The GUI offers only Full and
   Reduced — Permissive is reached from the command line.)
4. Reboot into macOS, then:

```
sudo nvram boot-args=amfi_get_out_of_my_way=1
sudo reboot
```

If the `nvram` write is refused or the boot arg does not take effect, enable it
explicitly and reboot again:

```
sudo bputil -a
```

**Intel**: boot recovery with ⌘R, `csrutil disable` in Terminal, reboot, then the same
`nvram` command. There is no `bputil` and no policy checkbox to worry about.

Do not take the recovery UI wording above as exact — it moves between releases. The
reliable check is the script itself: `run-spike.sh` refuses to continue and tells you if
AMFI is still enforcing.

**Undo when finished** — leaving SIP off is a real downgrade:

```
sudo nvram -d boot-args
# then reboot to recovery and run: csrutil enable
```

## Running it

```
./run-spike.sh
```

It builds and signs everything, checks that an entitled binary can run at all, then
publishes four candidate devices in turn and records what the system did with each.
Takes about two minutes.

Optional, for variant B4 — run this on whichever Mac has the touchscreen plugged in
(no entitlement or AMFI change needed), then copy `descriptors/real-panel.bin` across:

```
./capture-panel.sh
```

Heads-up: the script feeds synthetic touch reports and opens a test window. If a device
*is* claimed, those touches may move the pointer or click things. Don't run it while
something important is on screen.

## The variants

| # | Descriptor | Manufacturer | What it tests |
|---|---|---|---|
| **B3** | vendor page `0xFF60`/usage 7 | honest | The `MTUserDevice` personality, which has **no** manufacturer condition. The path that needs no lie — tried first. |
| **B1** | Sidecar's own 256-byte descriptor | `"Apple"` | The known-good shape, matching `AppleMultitouchHIDService (0x0D,0x04)`. |
| **B2** | Sidecar's own descriptor | honest | Isolates whether the `Manufacturer == "Apple"` match is really enforced. |
| **B4** | your panel's real descriptor | `"Apple"` | Whether a real Windows-style descriptor is claimed — and if so, whether it parses. |

B1 and B2 are also fed a two-contact sweep in Sidecar's 81-byte report layout (see
`TouchUpCore/TUCVirtualDigitizerDescriptor.h` for the decode this mirrors).

## Reading the result

`results/SUMMARY.txt` has a line per variant with four facts:

- **created** — the kernel accepted the device at all. If this is `no` everywhere, the
  entitlement or the properties are wrong, not the concept.
- **claimed** — an `AppleMultitouch` service bound to it. **This is the answer.** Claimed
  means the native path is reachable; unclaimed everywhere means it is closed.
- **multitouch** — some `NSScreen` reports multi-touch capability.
- **gestures** — how many gesture-recognizer callbacks the test window received. Non-zero
  means real touches arrived, which is the strongest possible result.

The interesting failure is **claimed but zero gestures**: the OS took the device and then
could not parse its reports. For B4 that would confirm that cloning a real panel's
descriptor is a dead end (it would also mean a shipped version could leave a user with a
seized panel and no input at all). For B1 it would point at the 63-byte `0xFF1A` vendor
blob being load-bearing.

Send back the whole `results/` directory — `SUMMARY.txt` plus the `.ioreg.log` files are
what matter.
