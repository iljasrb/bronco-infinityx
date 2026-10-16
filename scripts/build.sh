#!/usr/bin/env bash
# Build Project Infinity X (branch 17 = Android 17 = LineageOS 24.0) for the Motorola
# ThinkPhone (bronco), converting the stock LineageOS device tree.
#
#   podman exec -it infinity-build /work/scripts/build.sh
#
# Idempotent: re-applies the conversion and every local fix, so `repo sync --force-sync`
# cannot silently undo them.
#
# No `set -e`/pipefail on purpose: vendor/infinity/build/envsetup.sh:1029 runs
# `tr </dev/urandom | head -c 4`, and SIGPIPE on tr (141) would abort the build just
# after the ccache banner. Errors are checked explicitly instead.

root="/work"
bronco="device/motorola/bronco"
common="device/motorola/sm8475-common"
cfg="$bronco/resource-overlay/device/Frameworks/res/values/config.xml"

cd "$root" || exit 1

# --- LineageOS -> Infinity X device tree conversion --------------------------
# Only three things are Lineage-specific: the common inherit path, the makefile name,
# and PRODUCT_NAME (Infinity X lunches infinity_<device>). Everything else
# (vendor.lineage.* HALs, lineage.dependencies) is unchanged.

[[ -f $bronco/lineage_bronco.mk ]] && mv -f $bronco/lineage_bronco.mk $bronco/infinity_bronco.mk
sed -i \
    -e 's|vendor/lineage/config|vendor/infinity/config|g' \
    -e 's|PRODUCT_NAME := lineage_bronco|PRODUCT_NAME := infinity_bronco|' \
    "$bronco/infinity_bronco.mk"
sed -i 's|lineage_bronco\.mk|infinity_bronco.mk|' "$bronco/AndroidProducts.mk"
sed -i 's|vendor/lineage/config|vendor/infinity/config|' "$common/BoardConfigCommon.mk"

# =============================================================================
# Local fixes, re-applied on every run. None of these are upstream.
# =============================================================================

# --- double-tap to wake ------------------------------------------------------
# Upstream never sets BOARD_USES_DOUBLE_TAP_CTRL, so the MMI touch driver never
# creates the double_tap_* sysfs nodes LineageOS's sensors sub-HAL polls, and
# DoubleTapSensor's open() fails silently.
grep -q '^BOARD_USES_DOUBLE_TAP_CTRL := true' "$common/BoardConfigCommon.mk" ||
    printf '\nBOARD_USES_DOUBLE_TAP_CTRL := true\n' >> "$common/BoardConfigCommon.mk"

# Doze must enable the sensor before the panel goes off, or the touch IC is already
# suspended when the enable lands.
sed -i 's|<bool name="config_dozeAfterScreenOffByDefault">true</bool>|<bool name="config_dozeAfterScreenOffByDefault">false</bool>|' "$cfg"

# The gesture re-arm is gated on touch_powered, which ts_mmi_queued_stop() does not
# clear, so an enable arriving after the panel is off is dropped: it "defers to the
# next suspend", and there is no next suspend while the screen stays off. Gate on panel
# state instead.
python3 - <<'PY'
p = ("kernel/motorola/sm8475-modules/motorola/drivers/input/"
     "touchscreen/touchscreen_mmi/touchscreen_mmi_notif.c")
s = open(p).read()
old = "\t\tcase TS_MMI_SET_GESTURES:\n\t\t\tif (touch_cdev->touch_powered)\n\t\t\t\tbreak;"
new = "\t\tcase TS_MMI_SET_GESTURES:\n\t\t\tif (IS_ACTIVE_MODE)\n\t\t\t\tbreak;"
if old in s:
    open(p, "w").write(s.replace(old, new))
PY

# --- refresh rate flicker ----------------------------------------------------
# The panel shifts gamma on every rate change, so anything that changes the rate is
# visible as flicker. Two independent layers do it; both must stop.
#
# Layer 1, framework: hold the display inside its "low blocking zone" -- Vote
# .forPhysicalRefreshRates() emits DisableRefreshRateSwitching whenever min == max.
# Two traps: config_defaultRefreshRateInZone defaults to 0 (hasValidLowZone() false,
# mechanism silently off), and every ambient entry must be >= 0 or hasValidThreshold()
# fails, the light sensor is never registered and updateFlickerRefreshRateVotes() bails
# out at mBrightness == NaN.
python3 - <<'PY'
import re
p = "device/motorola/bronco/resource-overlay/device/Frameworks/res/values/config.xml"
s = open(p).read()
s = re.sub(r'(name="config_brightnessThresholdsOfPeakRefreshRate">).*?(</integer-array>)',
           r'\1\n        <item>255</item>\n    \2', s, flags=re.S)
s = re.sub(r'(name="config_ambientThresholdsOfPeakRefreshRate">).*?(</integer-array>)',
           r'\1\n        <item>100000</item>\n    \2', s, flags=re.S)
if 'config_defaultRefreshRateInZone' not in s:
    s = s.replace('</resources>',
                  '    <integer name="config_defaultRefreshRateInZone">144</integer>\n</resources>')
open(p, 'w').write(s)
PY

# Layer 2, display HAL: libsdmcore runs its own dynamic fps and drops the panel to 60
# behind SurfaceFlinger's back:
#   SDM : DisplayBase::CommitThread: Received idle timeout
#   [drm:dsi_panel_dfps_send_cmd] fps switch 120 to 60
# Layer 1 already pins the framework at the user's chosen peak, so this costs nothing.
grep -q '^vendor.display.disable_dynamic_fps=1' "$common/vendor.prop" ||
    printf '\nvendor.display.disable_dynamic_fps=1\n' >> "$common/vendor.prop"

# Layer 3, AOD: layer 2 is also what used to drop the panel to its idle rate, so AOD
# inherited the awake rate (measured: 120 Hz while Dozing). Cap the min/peak votes while
# dozing instead. It rides the existing user-setting vote priority (10), below
# PRIORITY_UDFPS (26), so the fingerprint sensor still overrides it. Device-verified:
#   [drm:dsi_panel_dfps_send_cmd] fps switch 120 to 60
python3 - <<'PY'
import sys
p = ("frameworks/base/services/core/java/com/android/server/display/mode/"
     "DisplayModeDirector.java")
s = open(p).read()
if 'DOZE_REFRESH_RATE = 60f' in s:
    sys.exit(0)

const_old = ('    private static final String TAG = "DisplayModeDirector";\n'
             '    private boolean mLoggingEnabled;\n')
const_new = const_old + (
    '\n'
    '    // bronco: the rate AOD is pinned to while the display is dozing. See\n'
    '    // SettingsObserver.updateDozeRefreshRateLocked().\n'
    '    private static final float DOZE_REFRESH_RATE = 60f;\n')

field_old = '        private boolean mIsLowPower = false;\n'
field_new = field_old + '        private boolean mIsDoze = false;\n'

hook_old = ('                    public void onDisplayChanged(int displayId) {\n'
            '                        synchronized (mLock) {\n'
            '                            updateLowPowerModeAllowedModesLocked();\n')
hook_new = hook_old + '                            updateDozeRefreshRateLocked(displayId);\n'

vote_old = ('            updateRefreshRateSettingLocked(minRefreshRate, peakRefreshRate, mDefaultRefreshRate,\n'
            '                    displayId);\n'
            '        }\n')
vote_new = (
    '            if (mIsDoze) {\n'
    '                // bronco: dynamic frame rate switching is disabled device-wide\n'
    '                // (vendor.display.disable_dynamic_fps, which is what stops the panel\n'
    '                // shifting gamma mid-use), so the panel no longer drops to its idle rate\n'
    '                // in AOD. Cap it here instead, riding the user-setting votes so that every\n'
    '                // higher-priority vote -- notably UDFPS -- can still override it.\n'
    '                minRefreshRate = Math.min(minRefreshRate, DOZE_REFRESH_RATE);\n'
    '                peakRefreshRate = Math.min(peakRefreshRate, DOZE_REFRESH_RATE);\n'
    '            }\n'
    '\n' + vote_old +
    '\n'
    '        /**\n'
    '         * bronco: re-vote the refresh rate when the display enters or leaves doze, so AOD\n'
    '         * runs at DOZE_REFRESH_RATE while the awake rate is left alone.\n'
    '         */\n'
    '        @GuardedBy("mLock")\n'
    '        private void updateDozeRefreshRateLocked(int displayId) {\n'
    '            final boolean isDoze = mInjector.isDozeState(mInjector.getDisplay(displayId));\n'
    '            if (isDoze == mIsDoze) {\n'
    '                return;\n'
    '            }\n'
    '            mIsDoze = isDoze;\n'
    '            updateRefreshRateSettingLocked(displayId);\n'
    '        }\n')

for name, old, new in (("TAG", const_old, const_new), ("mIsLowPower", field_old, field_new),
                       ("onDisplayChanged", hook_old, hook_new), ("vote", vote_old, vote_new)):
    assert old in s, "DisplayModeDirector: anchor %s not found" % name
    s = s.replace(old, new, 1)
open(p, 'w').write(s)
PY
# Fail loudly if an upstream change moved those anchors.
grep -q 'DOZE_REFRESH_RATE = 60f' \
    frameworks/base/services/core/java/com/android/server/display/mode/DisplayModeDirector.java || {
    echo "AOD refresh-rate patch did not apply: anchors moved upstream" >&2; exit 1; }

# The picker: a min/max pair is meaningless at a pinned rate -- it was what produced
# the range that flickered -- so the screen is one list (60/90/120/144) whose selection
# sets both min and peak. Those two files are edited wholesale, which a `repo sync
# --force-sync` of packages/apps/Settings would revert, so verify rather than rewrite.
grep -q 'extreme_refresh_rate' packages/apps/Settings/res/xml/screen_refresh_rate.xml && {
    echo "refresh-rate picker reverted: min/max or extreme switch is back" >&2; exit 1; }
grep -q 'setRefreshRate(refreshRate, refreshRate)' \
    packages/apps/Settings/src/com/infinity/settings/display/refreshrate/PeakRefreshRatePreferenceController.java || {
    echo "refresh-rate picker reverted: peak no longer sets min+peak" >&2; exit 1; }
# XML comments may not contain '--'; aapt2 only reports it 25 minutes into the build.
python3 -c 'import xml.dom.minidom;xml.dom.minidom.parse("packages/apps/Settings/res/xml/screen_refresh_rate.xml")' 2>/dev/null || {
    echo "refresh-rate picker XML is malformed: rejecting it now, before the build spends 25 minutes" >&2; exit 1; }

# --- stock Motorola camera ---------------------------------------------------
# MotCamera4 + MotCamera3AI, their shared libraries and the hidden-API whitelist.
# TheMuppets' vendor tree ships none of it.
[[ -f $bronco/motocamera/motocamera.mk ]] || { echo "motocamera prebuilts missing" >&2; exit 1; }
grep -q 'motocamera/motocamera.mk' "$bronco/infinity_bronco.mk" ||
    printf '\n$(call inherit-product, device/motorola/bronco/motocamera/motocamera.mk)\n' >> "$bronco/infinity_bronco.mk"

# `adb root` is unavailable (SetSafetyNetProps() forces ro.debuggable=0 every boot, for
# Play Integrity), so there is no push-based iteration: every test costs build + flash.

# --- OTA feed and changelog --------------------------------------------------
# Both URLs are compiled into the ROM, so they cannot change without a rebuild *and a
# reflash*: they must point somewhere permanent. GitHub raw is free and stable. The
# ~1.8 GB downloads are named inside the feed JSON and can be moved to any mirror
# without touching these. blocked_update_info_url is left alone: it is a LineageOS
# wiki help link, not a feed.
updater="packages/apps/Updater/app/src/main/res/values/strings.xml"
base="https://raw.githubusercontent.com/iljasrb/bronco-infinityx/main"
feed="$base/bronco.json"
sed -i "s|https://raw.githubusercontent.com/ProjectInfinity-X/official_devices/17/vanilla/{device}.json|$feed|" \
    "$updater"
grep -q "name=\"updater_server_url\" translatable=\"false\">$feed<" "$updater" || {
    echo "OTA feed retarget did not apply: strings.xml anchor moved upstream" >&2; exit 1; }

# The "Show changelog" link points into the same upstream tree. Swap the path prefix
# only, leaving the xliff device substitution (%1$s -> changelog/<device>.txt) intact.
sed -i "s|https://raw.githubusercontent.com/ProjectInfinity-X/official_devices/17/changelog/|$base/changelog/|" \
    "$updater"
grep -q "$base/changelog/" "$updater" || {
    echo "changelog retarget did not apply: strings.xml anchor moved upstream" >&2; exit 1; }

# --- self-check: fail loudly if a future sync changes the upstream shape -----
[[ -f $bronco/infinity_bronco.mk ]] || { echo "no infinity_bronco.mk" >&2; exit 1; }
grep -q 'PRODUCT_NAME := infinity_bronco' "$bronco/infinity_bronco.mk" || { echo "PRODUCT_NAME not converted" >&2; exit 1; }
grep -q 'infinity_bronco\.mk' "$bronco/AndroidProducts.mk" || { echo "AndroidProducts.mk not converted" >&2; exit 1; }
if grep -rq 'vendor/lineage/config' "$bronco" "$common"; then
    echo "stray vendor/lineage/config inherit" >&2
    exit 1
fi

# --- build -------------------------------------------------------------------
# -j4 by default: higher parallelism has been SIGKILLed by systemd-oomd here (Soong
# *analysis* is the RAM hog, not the compile). 32 GB RAM + zram.
export WITH_GAPPS="${WITH_GAPPS:-false}"
export INFINITY_MAINTAINER="${INFINITY_MAINTAINER:-iljasrb}"

source build/envsetup.sh
lunch infinity_bronco-userdebug || exit 1
m bacon -j"${JOBS:-4}"
