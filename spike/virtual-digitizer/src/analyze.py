#!/usr/bin/env python3
"""
Decide what happened to OUR virtual devices in an ioreg dump.

Two mistakes this exists to prevent, both made on the first run:

  1. `grep -c AppleMultitouch` over the whole dump matches the machine's own built-in
     trackpad, so every variant looks claimed. Only the subtree rooted at a device
     carrying our serial number counts.
  2. More than one of our devices can be alive at once — a leftover from an earlier
     invocation sits alongside the current one. Looking at only the first match reads
     the wrong device and can inarguably invert the result.

usage: analyze.py <ioreg.log> [variant-name]
"""
import re
import sys
import pathlib

SERIAL = "TouchUp-Virtual-0001"


def _indent(line: str) -> int:
    m = re.match(r"^([\s|]*)\+-o ", line)
    return len(m.group(1)) if m else -1


def _field(text: str, pattern: str, default: str = "?") -> str:
    m = re.search(pattern, text)
    return m.group(1) if m else default


def devices(path: str) -> list:
    lines = pathlib.Path(path).read_text(errors="replace").splitlines()
    # Later sections re-root the tree elsewhere and would double-count.
    cut = next((i for i, l in enumerate(lines)
                if l.startswith("=== ioreg -c AppleMultitouchDevice")), len(lines))
    lines = lines[:cut]

    found = []
    for i, line in enumerate(lines):
        if SERIAL not in line or "Multitouch Serial" in line:
            continue
        start = next(j for j in range(i, -1, -1) if _indent(lines[j]) >= 0)
        base = _indent(lines[start])
        stop = len(lines)
        for k in range(start + 1, len(lines)):
            ind = _indent(lines[k])
            if ind >= 0 and ind <= base:
                stop = k
                break
        text = "\n".join(lines[start:stop])
        found.append({
            "line": start + 1,
            "manufacturer": _field(text, r'"Manufacturer" = "([^"]*)"'),
            "usage": _field(text, r'"DeviceUsagePairs" = (\(.*?\))'),
            # Two ways in, found the hard way: the touchscreen-ish personalities bind
            # AppleMultitouchHIDService, while a device that looks like a Magic Trackpad
            # gets AppleMultitouchTrackpadHIDEventDriver instead. Only the second one has
            # ever produced input.
            "claimed": ("AppleMultitouchHIDService" in text
                        or "AppleMultitouchTrackpadHIDEventDriver" in text),
            "driver": ("AppleMultitouchTrackpadHIDEventDriver"
                       if "AppleMultitouchTrackpadHIDEventDriver" in text
                       else ("AppleMultitouchHIDService" if "AppleMultitouchHIDService" in text else "")),
            "generic": "AppleUserHIDEventDriver" in text,
            # Geometry the multitouch stack needs before a contact means anything.
            "sensor": sorted(set(re.findall(r'"(Sensor [^"]+|Family ID|MTHIDDevice)"', text))),
        })
    return found


def main() -> int:
    path = sys.argv[1]
    name = sys.argv[2] if len(sys.argv) > 2 else pathlib.Path(path).stem
    found = devices(path)

    if not found:
        print(f"{name}: our device is not in this dump at all")
        return 1

    if len(found) > 1:
        print(f"  note: {len(found)} of our devices were alive — a leftover from an earlier run")

    claimed_any = False
    for d in found:
        if d["claimed"]:
            verdict, claimed_any = f"CLAIMED by {d['driver']}", True
        elif d["generic"]:
            verdict = "generic AppleUserHIDEventDriver only"
        else:
            verdict = "nothing bound"
        print(f"  line {d['line']:>4}  manufacturer={d['manufacturer']!r} usage={d['usage']}")
        print(f"            -> {verdict}")
        if d["claimed"]:
            print(f"            -> sensor properties: {', '.join(d['sensor']) if d['sensor'] else 'NONE (no surface geometry)'}")

    print(f"VERDICT {name}: {'claimed' if claimed_any else 'not claimed'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
