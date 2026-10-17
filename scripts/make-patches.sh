#!/usr/bin/env bash
# Regenerate patches/*.patch from the current working tree.
#
# Run after editing any patched file. The working tree is the source of truth; these
# patches are just how it survives `repo sync`. Files a patch *creates* must be
# intent-to-added first, or `git diff` omits them and the patch silently loses content.
#
#   ./scripts/make-patches.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1

emit() {  # repo patch-name [file-to-add]
    local repo=$1 name=$2 add=${3:-}
    [ -n "$add" ] && git -C "$repo" add -N "$add" 2>/dev/null
    git -C "$repo" diff > "patches/$name.patch" || { echo "failed: $repo" >&2; return 1; }
    printf "  %-30s %4d lines\n" "$name.patch" "$(wc -l < "patches/$name.patch")"
}

emit frameworks/base                frameworks-base
emit packages/apps/Settings         apps-settings
emit packages/apps/Updater          apps-updater
emit device/motorola/bronco         device-bronco        infinity_bronco.mk
emit device/motorola/sm8475-common  device-sm8475-common
emit vendor/motorola/bronco         vendor-bronco        proprietary/vendor/etc/display/advanced_sf_offsets.xml
emit kernel/motorola/sm8475-modules kernel-sm8475-modules
