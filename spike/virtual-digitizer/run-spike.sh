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
clang -O2 -o bin/vhid src/vhid.c -framework CoreFoundation -framework IOKit -framework CoreGraphics || exit 1
note "bin/vhid"
clang -O2 -o bin/mt2 src/mt2.c -framework CoreFoundation -framework IOKit -framework CoreGraphics || exit 1
note "bin/mt2"
swiftc -O -o bin/touchcaps src/touchcaps.swift 2>/dev/null \
  && note "bin/touchcaps" || note "touchcaps failed to build (needs the macOS 27 SDK) — oracle 1 unavailable"
swiftc -O -o bin/gesturetest src/gesturetest.swift 2>/dev/null \
  && note "bin/gesturetest" || note "gesturetest failed to build — oracle 2 unavailable"

# Two copies: the entitled one publishes, and an unentitled one reads real devices.
# The entitlement gets the process killed outright under an enforcing AMFI, so anything
# that does not need it must not carry it.
cp bin/vhid bin/vhid-probe
codesign --force --sign - --entitlements vhid.entitlements bin/vhid || exit 1
codesign --force --sign - --entitlements vhid.entitlements bin/mt2 || exit 1
codesign --force --sign - bin/vhid-probe || exit 1
note "signed bin/vhid and bin/mt2 (entitled), bin/vhid-probe (plain)"

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
  local pointer
  pointer=$(grep -c "POINTER MOVED" "$out.publish.log")
  note "pointer moved:      $([ "$pointer" -gt 0 ] && echo "YES — the system acted on our reports" || echo no)"
  note "direct touches:     $gestures"
  note "mouse-driven:       $mouseish  (emulated, or you touched the mouse)"

  printf '%-4s created=%-3s claimed=%-3s multitouch=%-3s pointer=%-3s touches=%s\n' \
    "$name" \
    "$([ "$created" -gt 0 ] && echo yes || echo no)" \
    "$([ "$claimed" -gt 0 ] && echo yes || echo no)" \
    "$([ "$multitouch" -gt 0 ] && echo yes || echo no)" \
    "$([ "$pointer" -gt 0 ] && echo yes || echo no)" \
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

# The configuration nobody had tried: an ordinary Windows-style touchscreen, announced
# honestly, fed reports in the shape such a panel actually sends. Round 3 showed that
# NSScreen reports touch capability for any 0x0D/0x04 device even when the multitouch
# driver never adopts it — so the generic HID driver, not AppleMultitouchHIDService, may
# be the path that matters. B2 was this test with the wrong descriptor and the wrong
# reports.
run_variant B8 descriptors/standard-touchscreen.bin 0x0D  4 "Touch Up" "--layout standard"

# C1. The Magic Trackpad 2 emulation. Everything so far has been adopted and silent;
# VoodooInput is driven successfully by this same stock driver, and the difference is
# that it answers the driver's GET_REPORT interrogation for sensor geometry. Whatever
# happens, the log of what the driver asks for is the finding.
say "Variant C1 — Magic Trackpad 2 emulation"
if [ -x bin/gesturetest ]; then ./bin/gesturetest 30 > results/C1.gesture.log 2>&1 & sleep 2; fi
./bin/mt2 --hold 15 > results/C1.publish.log 2>&1 &
C1PID=$!
sleep 8
{
  echo "=== ioreg -c IOHIDUserDevice ==="; ioreg -c IOHIDUserDevice -r -l -w0
  echo; echo "=== ioreg -c AppleMultitouchDevice ==="; ioreg -c AppleMultitouchDevice -r -l -w0
  echo; echo "=== hidutil list ==="; hidutil list 2>/dev/null
} > results/C1.ioreg.log 2>&1
[ -x bin/touchcaps ] && ./bin/touchcaps > results/C1.touchcaps.log 2>&1
wait $C1PID 2>/dev/null
pkill -f "bin/gesturetest" 2>/dev/null
python3 src/analyze.py results/C1.ioreg.log C1 | tee results/C1.verdict.log
C1_GET=$(grep -c "  GET " results/C1.publish.log)
C1_SET=$(grep -c "  SET " results/C1.publish.log)
C1_PTR=$(grep -c "POINTER MOVED" results/C1.publish.log)
C1_TOUCH=0; [ -f results/C1.gesture.log ] && C1_TOUCH=$(grep -c "SOURCE=directTouch" results/C1.gesture.log)
note "driver asked us:    $C1_GET get, $C1_SET set requests"
note "pointer moved:      $([ "$C1_PTR" -gt 0 ] && echo YES || echo no)"
note "direct touches:     $C1_TOUCH"
printf 'C1   interrogation=%s/%s pointer=%-3s touches=%s  (Magic Trackpad 2 emulation)\n' \
  "$C1_GET" "$C1_SET" \
  "$([ "$C1_PTR" -gt 0 ] && echo yes || echo no)" "$C1_TOUCH" >> results/SUMMARY.txt

# C3. The variant the hybrid actually depends on. One finger on a trackpad moves the
# pointer, which we do NOT want — absolute positioning stays with the existing synthesis.
# Two fingers scroll and leave the pointer alone, which is exactly the division of labour
# the hybrid proposes. Success here is a scroll arriving with the pointer unmoved.
say "Variant C3 — two-finger scroll on the emulated trackpad"
if [ -x bin/gesturetest ]; then ./bin/gesturetest 30 > results/C3.gesture.log 2>&1 & sleep 2; fi
./bin/mt2 --gesture scroll --hold 12 > results/C3.publish.log 2>&1 &
C3PID=$!
sleep 8
{ echo "=== ioreg -c AppleMultitouchDevice ==="; ioreg -c AppleMultitouchDevice -r -l -w0; } > results/C3.ioreg.log 2>&1
wait $C3PID 2>/dev/null
pkill -f "bin/gesturetest" 2>/dev/null
C3_PTR=$(grep -c "POINTER MOVED" results/C3.publish.log)
C3_SCROLL=0; [ -f results/C3.gesture.log ] && C3_SCROLL=$(grep -c "scrollWheel" results/C3.gesture.log)
note "pointer moved:      $([ "$C3_PTR" -gt 0 ] && echo "yes (unwanted for scroll)" || echo "no (correct)")"
note "scroll events seen: $C3_SCROLL"
printf 'C3   pointer=%-3s scrollEvents=%s  (two-finger scroll; pointer should NOT move)\n' \
  "$([ "$C3_PTR" -gt 0 ] && echo yes || echo no)" "$C3_SCROLL" >> results/SUMMARY.txt

# C2. The other reading of the disassembly: usage 7 on Apple's multitouch vendor page as
# the inbound counterpart of usage 6, carrying 96-byte MTContact records directly.
run_variant C2 descriptors/mt-vendor-ff60.bin      0xFF60 7 "Touch Up" "--mt-props --geometry --layout contacts"

say "Summary"
cat results/SUMMARY.txt
echo
note "Full evidence in $(pwd)/results/"
note "Send back results/ — SUMMARY.txt plus the .ioreg.log files are the ones that matter."
