#!/usr/bin/env bash
# capture-aod-bug.sh — record logcat + kernel log while you watch the phone.
# Press SPACE at the moment the artefact is visible: it drops a marker into both
# logs, takes a screencap and a small state dump. Press q to stop.
#
#   ./capture-aod-bug.sh [outdir]
#
# Framebuffer black-but-panel-lit shows up as a ~15.5 KB screencap; a panel-only
# light (FOD HBM) never appears in the PNG, so the size plus `mark-N.txt` decides.
set -uo pipefail
out="${1:-/tmp/bronco-capture-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out" || exit 1
adb get-state >/dev/null 2>&1 || { echo "no adb device" >&2; exit 1; }

adb logcat -c 2>/dev/null
adb logcat -v threadtime -b all >"$out/logcat.txt" 2>&1 & lc=$!
adb shell 'su -c "dmesg -w"' >"$out/kmsg.txt" 2>&1 & km=$!
trap 'kill $lc $km 2>/dev/null; wait 2>/dev/null; echo; echo "capture in $out"' EXIT INT TERM

echo "recording -> $out      [SPACE] mark the moment      [q] quit"
n=0
grace_end=$(($(date +%s) + 2))   # ignore stray pty bytes right after start
while IFS= read -rsn1 k; do
  case "$k" in
    ' ')
      [ "$(date +%s)" -lt "$grace_end" ] && continue
      n=$((n + 1))
      msg="===== MARK $n @ $(date -Is) ====="
      printf '%s\n' "$msg" >>"$out/marks.txt"
      printf '\n%s\n' "$msg" >>"$out/logcat.txt"
      printf '\n%s\n' "$msg" >>"$out/kmsg.txt"
      adb exec-out screencap -p >"$out/mark-$n.png" 2>/dev/null
      {
        echo "$msg"
        echo "-- power:";   adb shell 'dumpsys power | grep -E "mWakefulness=|mScreenBrightnessBoostInProgress"'
        echo "-- display:"; adb shell 'dumpsys display | grep -m3 -E "mScreenState=|mState="'
        echo "-- udfps:";   adb shell 'dumpsys window windows | grep -i udfps | head -3'
        echo "-- backlight:"; adb shell 'cat /sys/class/backlight/panel0-backlight/brightness'
        echo "-- hbm:";     adb shell 'su -c "dmesg | grep -E \"Set HBM to|re-applying HBM|clearing cached HBM\" | tail -8"'
      } >"$out/mark-$n.txt" 2>&1
      echo "mark $n saved: screencap $(stat -c%s "$out/mark-$n.png" 2>/dev/null || echo 0) bytes"
      ;;
    q|Q) break ;;
  esac
done
