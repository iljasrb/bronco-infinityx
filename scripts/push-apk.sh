#!/usr/bin/env bash
# Fast iteration: rebuild one APK and swap it into the running phone. No OTA, no flash.
#
#   scripts/push-apk.sh SystemUI        # or Settings, Updater
#
# Builds only the module in the container, then copies the APK over the installed one
# on /system_ext and restarts the affected processes. Needs root on the device (KSU;
# `adb root` is blocked by the Play Integrity spoof, see docs/issues.md) and AVB
# sentinel-free vbmeta (--flags 3, the build default), which lets /system_ext remount rw.
set -u
module=${1:?usage: push-apk.sh <soong module, e.g. SystemUI>}
tree=$(cd "$(dirname "$0")/../.." && pwd)
cd "$tree" || exit 1

podman exec infinity-build bash -lc \
    "cd /work && source build/envsetup.sh && lunch infinity_bronco-userdebug &&
     WITH_DEXPREOPT=false m $module -j\${JOBS:-8}" || { echo "build failed" >&2; exit 1; }

apk=$(find out/target/product/bronco -maxdepth 4 -path "*/priv-app/$module/$module.apk" | head -1)
[ -n "$apk" ] || { echo "no $module.apk in out/" >&2; exit 1; }
part=$(echo "${apk#out/target/product/bronco/}" | cut -d/ -f1)

adb push "$apk" "/data/local/tmp/$module.apk" || exit 1
adb shell "su -c 'mount -o rw,remount /$part'" || { echo "remount failed" >&2; exit 1; }
adb shell "su -c 'cp /data/local/tmp/$module.apk /$part/priv-app/$module/$module.apk &&
    rm -rf /$part/priv-app/$module/oat /data/local/tmp/$module.apk'" \
    || { echo "copy failed (root? see docs/issues.md)" >&2; exit 1; }

# stale process keeps the old code; kill so system_server restarts it
adb shell "su -c 'kill \$(pidof com.android.systemui)'" >/dev/null 2>&1
adb shell "su -c 'kill \$(pidof com.android.settings)'" >/dev/null 2>&1

echo "pushed $module.apk to /$part/priv-app/$module/"
