#!/bin/bash
#
# Capture an attached touchscreen's HID report descriptor, for variant B4.
#
# Run this on whichever Mac the touchscreen is plugged into — it needs no
# entitlement and no AMFI changes. Then copy descriptors/real-panel.bin to the
# test machine before running run-spike.sh.
#
set -u
cd "$(dirname "$0")"
mkdir -p bin descriptors
clang -O2 -o bin/vhid-probe src/vhid.c -framework CoreFoundation -framework IOKit || exit 1
codesign --force --sign - bin/vhid-probe || exit 1
./bin/vhid-probe --dump-real descriptors/real-panel.bin
