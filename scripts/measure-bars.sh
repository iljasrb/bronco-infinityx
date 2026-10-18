#!/usr/bin/env bash
# Exact bounds of the SystemUI views the bronco overlays move, per screen state.
#
# Two readings per state:
#   ink     screenshot threshold+trim of the status bar row (left / right region) —
#           the only way to see the status bar TextClock, which uiautomator does not expose
#   rect    uiautomator bounds of named views (battery, QS panel, carrier, shade clock)
#
# QS is checked on a *short* pull (partial shade), not full expand: fully expanded hides
# the status bar row and only shows the big shade-header clock.
#
#   scripts/measure-bars.sh          # home, qs, keyguard
#   scripts/measure-bars.sh qs
set -u
want=${1:-all}

read -r -d '' FILTER <<'PY'
import re, sys
tag = sys.argv[1]
keys = ('clock', 'battery', 'carrier', 'status_icon', 'quick_settings_panel', 'qs_pager')
for m in re.finditer(r'<node[^>]*>', sys.stdin.read()):
    n = m.group(0)
    rid = re.search(r'resource-id="([^"]*)"', n)
    rid = rid.group(1).split('/')[-1] if rid else ''
    b = re.search(r'bounds="([^"]*)"', n)
    if b and any(k in rid for k in keys):
        print(f'{tag:9s} rect {rid:30s} {b.group(1)}')
PY

ink() {  # $1 = state tag: status bar row ink, left then right
    adb exec-out screencap -p > "/tmp/mb-$1.png"
    local l r
    l=$(magick "/tmp/mb-$1.png" -crop 300x120+0+0 +repage -colorspace gray \
            -threshold 60% -trim info: 2>/dev/null | awk '{print $4}')
    r=$(magick "/tmp/mb-$1.png" -crop 300x120+780+0 +repage -colorspace gray \
            -threshold 60% -trim info: 2>/dev/null | awk '{print $4}')
    echo "$1 ink  left=$l  right=$r"
}

adb shell svc power stayon true

grab() {  # $1 = state tag, $2 = commands that put the device in that state
    local tag=$1 cmd=$2
    [ "$want" = all ] || [ "$want" = "$tag" ] || return 0
    eval "$cmd" >/dev/null 2>&1
    adb shell input keyevent 224 >/dev/null 2>&1   # wake: screenshots are blank when dozing
    sleep 2
    ink "$tag"
    adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    adb shell cat /sdcard/ui.xml 2>/dev/null | python3 -c "$FILTER" "$tag"
}

grab home      'adb shell cmd statusbar collapse; adb shell wm dismiss-keyguard; adb shell input keyevent 3'
grab qs        'adb shell input swipe 540 15 540 700 300'
grab keyguard   'adb shell cmd statusbar collapse; adb shell input keyevent 26; sleep 1; adb shell input keyevent 224'
