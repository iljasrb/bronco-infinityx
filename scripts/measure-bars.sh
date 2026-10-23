#!/usr/bin/env bash
# Exact bounds of the views the bronco overlays move, per screen state, with the gaps
# that matter: how far the clock sits from the left edge and the battery from the right.
#
#   scripts/measure-bars.sh          # home, qs, keyguard
#   scripts/measure-bars.sh qs
#   scripts/measure-bars.sh shot s.png   # measure a screenshot taken by hand (dot visible)
#
# Two readings per state:
#   ink   screenshot threshold+trim of the status bar row — the only way to see the status
#         bar TextClock, which uiautomator does not expose on the launcher
#   rect  uiautomator bounds of named views (battery, QS panel, carrier, shade clock)
#
# QS is measured on a *short* pull: a fully expanded shade shows the big header clock
# instead of the status bar row, and comparing the two is the classic mistake.
#
# 1080 px wide at 400 dpi = 2.5 px/dp. Symmetric layout means left_gap == right_gap.
set -u
want=${1:-all}
W=1080
PXDP=2.5

adb shell svc power stayon true >/dev/null 2>&1

ink() {  # $1 = state tag -> one line with both gaps in px and dp
    [ "$1" = shot ] || adb exec-out screencap -p > "/tmp/mb-$1.png"
    local lx lw rx rw right
    read -r lx lw < <(box "/tmp/mb-$1.png" "300x120+0+0")
    read -r rx rw < <(box "/tmp/mb-$1.png" "300x120+780+0")
    right=$((780 + rx + rw))
    LC_ALL=C printf '%-9s ink  left=%3spx gap (%4.1fdp)   right=%4spx gap (%4.1fdp)\n' \
        "$1" "$lx" "$(dp "$lx")" \
        "$right" "$(dp "$((W - right))")"
}

dp() { awk -v px="$1" -v d="$PXDP" 'BEGIN{printf "%.1f", px/d}'; }

box() {  # img crop -> "x width" of the ink inside the crop
    magick "$1" -crop "$2" +repage -colorspace gray -threshold 60% -trim info: 2>/dev/null |
        awk '{split($3,s,"x"); split($4,g,"[x+]"); print g[3]+0, s[1]+0}'
}

dotrow() {  # privacy dot: green-pixel run in the corner, and the battery to its left
    local img=${1:-/tmp/mb-dot.png} dot dl dr bx bw bri gap
    dot=$(magick "$img" -crop ${W}x44+0+38 +repage -depth 8 txt:- 2>/dev/null | python3 -c '
import re, sys
cols = set()
for line in sys.stdin:
    m = re.match(r"(\d+),(\d+): \((\d+),(\d+),(\d+)", line)
    if not m:
        continue
    x, r, g = int(m.group(1)), int(m.group(3)), int(m.group(4))
    if g > 120 and g > r + 40:
        cols.add(x)
xs = sorted(cols)
runs = []
if xs:
    s = p = xs[0]
    for x in xs[1:]:
        if x - p > 3:
            runs.append((s, p)); s = x
        p = x
    runs.append((s, p))
runs = [r for r in runs if r[1] - r[0] > 5 and r[0] > 1000]
print(*runs[-1]) if runs else print("")
')
    if [ -z "$dot" ]; then
        echo "  dot       not visible in this screenshot"
        return
    fi
    read -r dl dr <<<"$dot"
    read -r bx bw < <(box "$img" "${dl}x120+0+0")   # everything left of the dot
    bri=$((bx + bw))
    gap=$((dl - bri - 1))
    LC_ALL=C printf '  dot       dot=%s..%spx   battery right=%spx   gap=%spx (%4.1fdp)   dot right margin=%spx\n' \
        "$dl" "$dr" "$bri" "$gap" "$(dp "$gap")" "$((W - dr - 1))"
}

rects() {
    adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    adb shell cat /sdcard/ui.xml 2>/dev/null | python3 -c '
import re, sys
tag = sys.argv[1]
keys = ("clock", "battery", "carrier", "status_icon", "quick_settings_panel", "qs_pager")
for m in re.finditer(r"<node[^>]*>", sys.stdin.read()):
    n = m.group(0)
    rid = re.search(r"resource-id=\"([^\"]*)\"", n)
    rid = rid.group(1).split("/")[-1] if rid else ""
    b = re.search(r"bounds=\"([^\"]*)\"", n)
    if b and any(k in rid for k in keys):
        print(f"{tag:9s} rect {rid:30s} {b.group(1)}")
' "$tag"
}

grab() {  # $1 = tag, $2 = commands that put the device in that state
    local tag=$1 cmd=$2
    [ "$want" = all ] || [ "$want" = "$tag" ] || return 0
    eval "$cmd" >/dev/null 2>&1
    adb shell input keyevent 224 >/dev/null 2>&1   # wake: screenshots are blank when dozing
    sleep 2
    ink "$tag"
    rects
}

if [ "${1:-}" = shot ]; then   # measure a screenshot taken by hand (dot visible or not)
    [ -f "${2:?usage: measure-bars.sh shot <png>}" ] || exit 1
    cp "$2" /tmp/mb-shot.png
    ink shot
    dotrow /tmp/mb-shot.png
    exit 0
fi

grab home    'adb shell cmd statusbar collapse; adb shell wm dismiss-keyguard; adb shell input keyevent 3'
grab qs      'adb shell input swipe 540 15 540 700 300'
grab keyguard 'adb shell cmd statusbar collapse; adb shell input keyevent 26; sleep 1; adb shell input keyevent 224'
