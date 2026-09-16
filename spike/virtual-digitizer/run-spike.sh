#!/bin/bash
#
# E2: publish candidate virtual digitizers and record whether macOS claims any of them.
# Run this on a Mac booted with amfi_get_out_of_my_way=1 (see README.md).
#
set -u
cd "$(dirname "$0")"
mkdir -p bin results

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

say "Preflight"
SW=$(sw_vers -productVersion)
note "macOS $SW (build $(sw_vers -buildVersion))"
case "$SW" in
  27*) ;;
  *) note "WARNING: this spike is about macOS 27. Results from $SW mean nothing for it." ;;
esac
note "SIP: $(csrutil status 2>/dev/null | head -1)"
BOOTARGS=$(nvram boot-args 2>/dev/null || echo "boot-args not set")
note "$BOOTARGS"
case "$BOOTARGS" in
  *amfi_get_out_of_my_way*) note "AMFI bypass present in boot-args." ;;
  *) note "WARNING: amfi_get_out_of_my_way=1 not in boot-args — publishing will be killed." ;;
esac
command -v clang >/dev/null  || { echo "clang not found — install Xcode Command Line Tools"; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found — install Xcode Command Line Tools"; exit 1; }

say "Build"
clang -O2 -o bin/vhid src/vhid.c -framework CoreFoundation -framework IOKit || exit 1
note "bin/vhid"
swiftc -O -o bin/touchcaps src/touchcaps.swift 2>/dev/null \
  && note "bin/touchcaps" || note "touchcaps failed to build (needs the macOS 27 SDK) — oracle 1 unavailable"
swiftc -O -o bin/gesturetest src/gesturetest.swift 2>/dev/null \
  && note "bin/gesturetest" || note "gesturetest failed to build — oracle 2 unavailable"

# Two copies: the entitled one publishes, and an unentitled one reads real devices.
# The entitlement gets the process killed outright under an enforcing AMFI, so anything
# that does not need it must not carry it.
cp bin/vhid bin/vhid-probe
codesign --force --sign - --entitlements vhid.entitlements bin/vhid || exit 1
codesign --force --sign - bin/vhid-probe || exit 1
note "signed bin/vhid (entitled) and bin/vhid-probe (plain)"

say "Clearing any leftovers from an earlier run"
pkill -x vhid 2>/dev/null && sleep 2
note "done"

say "Gate check: can an entitled binary even run here?"
./bin/vhid --desc descriptors/mt-vendor-ff60.bin --usage-page 0xFF60 --usage 7 --hold 1 >/dev/null 2>&1
GATE=$?
if [ $GATE -eq 137 ]; then
  cat <<'MSG'

  STOP: the entitled binary was killed at launch (SIGKILL).

  AMFI is still enforcing the restricted entitlement, so nothing below can run.
  Boot to recovery, set Reduced Security, then:

      sudo nvram boot-args=amfi_get_out_of_my_way=1
      sudo reboot

  See README.md for the full sequence.
MSG
  exit 1
fi
note "entitled binary runs (exit $GATE) — AMFI is not blocking"

say "Looking for a real panel (for variant B4)"
if [ -s descriptors/real-panel.bin ]; then
  note "using descriptors/real-panel.bin captured earlier ($(wc -c < descriptors/real-panel.bin | tr -d ' ') bytes)"
  HAVE_REAL=0
else
  ./bin/vhid-probe --dump-real descriptors/real-panel.bin
  HAVE_REAL=$?
  [ $HAVE_REAL -ne 0 ] && note "run ./capture-panel.sh on the Mac that has the touchscreen, then copy descriptors/real-panel.bin here"
fi

run_variant() {
  local name="$1" desc="$2" page="$3" usage="$4" manufacturer="$5" extra="$6"
  say "Variant $name"
  note "descriptor=$desc usage=$page/$usage manufacturer=\"$manufacturer\" $extra"

  local out="results/$name"
  : > "$out.publish.log"

  if [ -x bin/gesturetest ]; then
    ./bin/gesturetest 30 > "$out.gesture.log" 2>&1 &
    sleep 2
  fi

  # shellcheck disable=SC2086
  ./bin/vhid --desc "$desc" --usage-page "$page" --usage "$usage" \
             --manufacturer "$manufacturer" $extra --feed --hold 20 > "$out.publish.log" 2>&1 &
  local vpid=$!
  sleep 6

  {
    echo "=== ioreg -c IOHIDUserDevice ==="
    ioreg -c IOHIDUserDevice -r -l -w0
    echo
    echo "=== ioreg -c AppleMultitouchDevice ==="
    ioreg -c AppleMultitouchDevice -r -l -w0
    echo
    echo "=== hidutil list ==="
    hidutil list 2>/dev/null
  } > "$out.ioreg.log" 2>&1

  if [ -x bin/touchcaps ]; then ./bin/touchcaps > "$out.touchcaps.log" 2>&1; fi

  wait $vpid 2>/dev/null
  pkill -f "bin/gesturetest" 2>/dev/null

  # Verdicts. grep -c always prints a count, so no "|| echo 0" — that appended a second
  # line and put a stray 0 in the summary.
  local created claimed multitouch gestures mouseish
  created=$(grep -c "RESULT: created" "$out.publish.log")
  python3 src/analyze.py "$out.ioreg.log" "$name" | tee "$out.verdict.log"
  claimed=$(grep -c "VERDICT $name: claimed" "$out.verdict.log")
  multitouch=0; [ -f "$out.touchcaps.log" ] && multitouch=$(grep -c "SOME SCREEN REPORTS MULTITOUCH" "$out.touchcaps.log")
  # Only touch-driven callbacks count. A mouse click fires the click recognizer too,
  # so counting every callback would turn a stray click into a false positive.
  gestures=0; [ -f "$out.gesture.log" ] && gestures=$(grep -c "SOURCE=directTouch" "$out.gesture.log")
  mouseish=0; [ -f "$out.gesture.log" ] && mouseish=$(grep -c "SOURCE=mouse" "$out.gesture.log")

  note "created:            $([ "$created" -gt 0 ] && echo YES || echo "NO — kernel refused")"
  note "screen multitouch:  $([ "$multitouch" -gt 0 ] && echo YES || echo no)  (baseline was $BASELINE_MT)"
  note "direct touches:     $gestures"
  note "mouse-driven:       $mouseish  (emulated, or you touched the mouse)"

  printf '%-4s created=%-3s claimed=%-3s multitouch=%-3s touches=%s\n' \
    "$name" \
    "$([ "$created" -gt 0 ] && echo yes || echo no)" \
    "$([ "$claimed" -gt 0 ] && echo yes || echo no)" \
    "$([ "$multitouch" -gt 0 ] && echo yes || echo no)" \
    "$gestures" >> results/SUMMARY.txt
}

BASELINE_MT="unknown"
if [ -x bin/touchcaps ]; then
  ./bin/touchcaps > results/baseline.touchcaps.log 2>&1
  if grep -q "SOME SCREEN REPORTS MULTITOUCH" results/baseline.touchcaps.log; then
    BASELINE_MT="yes — something already reports multitouch before we publish anything"
  else
    BASELINE_MT="no"
  fi
fi

: > results/SUMMARY.txt
echo "macOS $SW  $(date)" >> results/SUMMARY.txt
echo >> results/SUMMARY.txt

# B3 first: the vendor-page path that needs no false manufacturer string.
run_variant B3 descriptors/mt-vendor-ff60.bin      0xFF60 7 "Touch Up" "--mt-props"
run_variant B1 descriptors/sidecar-touchscreen.bin 0x0D   4 "Apple"    ""
run_variant B2 descriptors/sidecar-touchscreen.bin 0x0D   4 "Touch Up" ""
if [ $HAVE_REAL -eq 0 ]; then
  run_variant B4 descriptors/real-panel.bin        0x0D   4 "Apple"    ""
else
  echo "B4   skipped (no real panel attached)" >> results/SUMMARY.txt
fi

# Round 2. B3 and B1 were both adopted by the multitouch driver and then emitted nothing,
# and the device they produced had no surface geometry at all. These repeat exactly those
# two shapes with geometry added, which is the cheapest remaining explanation to test.
run_variant B5 descriptors/mt-vendor-ff60.bin      0xFF60 7 "Touch Up" "--mt-props --geometry"
run_variant B6 descriptors/mt-vendor-ff60.bin      0xFF60 7 "Touch Up" "--mt-props --geometry --family 106"
run_variant B7 descriptors/sidecar-touchscreen.bin 0x0D   4 "Apple"    "--geometry"

say "Summary"
cat results/SUMMARY.txt
echo
note "Full evidence in $(pwd)/results/"
note "Send back results/ — SUMMARY.txt plus the .ioreg.log files are the ones that matter."
