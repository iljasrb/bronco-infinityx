#!/usr/bin/env bash
# Infinity X for bronco (ThinkPhone). Run inside the build container:
#   podman exec infinity-build /work/scripts/build.sh          full build + OTA
#   podman exec infinity-build env FAST_IMAGES=1 /work/scripts/build.sh   images only
#
# No set -e: envsetup.sh runs `tr </dev/urandom | head -c4` and SIGPIPE (141)
# would kill the build right after the ccache banner.

root=/work
bronco=device/motorola/bronco

cd "$root" || exit 1

# Local patches, one per repo. Re-applied after every repo sync.
# spec: repo:patch-name:file-the-patch-creates (moved aside if a stale copy exists)
PATCHES=(
    "frameworks/base:frameworks-base:"
    "packages/apps/Settings:apps-settings:"
    "packages/apps/Updater:apps-updater:"
    "device/motorola/bronco:device-bronco:infinity_bronco.mk"
    "device/motorola/sm8475-common:device-sm8475-common:"
    "vendor/motorola/bronco:vendor-bronco:proprietary/vendor/etc/display/advanced_sf_offsets.xml"
    "kernel/motorola/sm8475-modules:kernel-sm8475-modules:"
)

is_applied() { git -C "$1" apply --reverse --check "$2" 2>/dev/null; }

# pass 1: check everything before touching anything, so a conflict can't
# leave the tree half-patched. --3way is the fallback for upstream drift.
for spec in "${PATCHES[@]}"; do
    IFS=: read -r repo name created <<<"$spec"
    p="$root/patches/$name.patch"
    [[ -f $p ]] || { echo "missing patch: $p" >&2; exit 1; }
    is_applied "$repo" "$p" && continue
    [ -n "$created" ] && [ -e "$repo/$created" ] && mv "$repo/$created" "$repo/$created.bak"
    if ! git -C "$repo" apply --check "$p" 2>/dev/null &&
       ! git -C "$repo" apply --check --3way "$p" 2>/dev/null; then
        [ -e "$repo/$created.bak" ] && mv "$repo/$created.bak" "$repo/$created"
        echo "patch does not apply: $name -- regenerate patches/$name.patch" >&2
        git -C "$repo" apply --check "$p" 2>&1 | head -5 >&2
        exit 1
    fi
done

# pass 2: apply
for spec in "${PATCHES[@]}"; do
    IFS=: read -r repo name created <<<"$spec"
    p="$root/patches/$name.patch"
    is_applied "$repo" "$p" && continue
    if git -C "$repo" apply "$p" 2>/dev/null || git -C "$repo" apply --3way "$p"; then
        is_applied "$repo" "$p" || { echo "$name applied but not verifiable" >&2; exit 1; }
        [ -e "$repo/$created.bak" ] && rm -f "$repo/$created.bak"
    else
        [ -e "$repo/$created.bak" ] && mv "$repo/$created.bak" "$repo/$created"
        echo "failed to apply: $name" >&2
        exit 1
    fi
done

[ -n "$PATCH_ONLY" ] && { echo "patches ok"; exit 0; }

# motocamera prebuilts are too big for a patch; they live untracked in the tree.
[[ -d $bronco/motocamera ]] || {
    echo "motocamera prebuilts missing: $bronco/motocamera/" >&2
    exit 1; }

# aapt2 reports bad XML 25 min into the build; fail here instead.
python3 -c 'import xml.dom.minidom;xml.dom.minidom.parse("packages/apps/Settings/res/xml/screen_refresh_rate.xml")' 2>/dev/null || {
    echo "refresh-rate picker XML is malformed" >&2; exit 1; }
python3 -c 'import xml.dom.minidom;xml.dom.minidom.parse("device/motorola/bronco/resource-overlay/device/SystemUI/res/values/dimens.xml")' 2>/dev/null || {
    echo "SystemUI overlay dimens.xml is malformed" >&2; exit 1; }

export WITH_GAPPS="${WITH_GAPPS:-false}"
export INFINITY_MAINTAINER="${INFINITY_MAINTAINER:-iljasrb}"

source build/envsetup.sh
lunch infinity_bronco-userdebug || exit 1

if [ -n "$FAST_IMAGES" ]; then
    m droid -j"${JOBS:-8}" || { echo "build failed" >&2; exit 1; }
    echo "images built; flash system/product/system_ext/vendor/vendor_dlkm via fastbootd"
    exit 0
fi

m bacon -j"${JOBS:-8}" || {
    echo "build failed: not packaging artifacts from a stale out/" >&2
    exit 1
}

# additional_images.zip: boot chain + recovery for first install from stock.
# The OTA doesn't carry these, so package them under the same date tag as the OTA.
prod="$root/out/target/product/bronco"
zipfile=$(ls -t "$prod"/Project_Infinity-X-*.zip 2>/dev/null | head -1)
if [ -n "$zipfile" ]; then
    tag=$(basename "$zipfile" | grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}')
    imgs="boot.img vendor_boot.img dtbo.img vbmeta.img vbmeta_system.img recovery.img"
    ( cd "$prod" && rm -f "additional_images-$tag.zip" && zip -q -j "additional_images-$tag.zip" $imgs ) || {
        echo "packaging additional_images.zip failed" >&2; exit 1; }
    echo "artifacts:"
    ( cd "$prod" && ls -la "additional_images-$tag.zip" | awk '{printf "  %s  %.1f MB\n", $9, $5/1048576}' \
      && md5sum "additional_images-$tag.zip" && sha256sum "additional_images-$tag.zip" )
fi
