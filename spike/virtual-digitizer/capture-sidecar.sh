#!/bin/bash
#
# Capture what Sidecar's own virtual touchscreen looks like once it is live.
#
# This is now the highest-value capture in the spike. Our device gets claimed by
# AppleMultitouchHIDService but produces no touches, and the multitouch device it
# creates has none of the sensor-geometry properties a working one has. Sidecar's
# device is the same class of thing — a virtual touchscreen, not a trackpad — so its
# properties are the reference we are missing.
#
# Needs no entitlement and no AMFI change: run it on any Mac, with the iPad connected
# over Sidecar and touch working.
#
set -u
cd "$(dirname "$0")"
mkdir -p results-sidecar

echo "Connect the iPad over Sidecar first, and confirm touch works there."
echo "Capturing..."

{
  echo "=== sw_vers ==="; sw_vers
  echo; echo "=== ioreg -c IOHIDUserDevice (full properties) ==="
  ioreg -c IOHIDUserDevice -r -l -w0
  echo; echo "=== ioreg -c AppleMultitouchDevice (full properties) ==="
  ioreg -c AppleMultitouchDevice -r -l -w0
  echo; echo "=== ioreg -c AppleMultitouchHIDService ==="
  ioreg -c AppleMultitouchHIDService -r -l -w0
  echo; echo "=== hidutil list ==="
  hidutil list
} > results-sidecar/sidecar.ioreg.log 2>&1

if [ -x bin/touchcaps ]; then
  ./bin/touchcaps > results-sidecar/sidecar.touchcaps.log 2>&1
else
  swiftc -O -o bin/touchcaps src/touchcaps.swift 2>/dev/null \
    && ./bin/touchcaps > results-sidecar/sidecar.touchcaps.log 2>&1
fi

echo
echo "Sidecar-owned HID devices found:"
grep -c "SidecarDisplayAgent\|Sidecar" results-sidecar/sidecar.ioreg.log 2>/dev/null
echo
echo "Virtual devices in the registry:"
grep -E '"Transport" = "Virtual"|"HIDVirtualDevice"' results-sidecar/sidecar.ioreg.log | sort | uniq -c
echo
echo "Wrote results-sidecar/ — send that back."
