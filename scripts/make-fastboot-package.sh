#!/usr/bin/env bash
# Assemble the browser-flashable package from an existing build.
#
#   scripts/make-fastboot-package.sh          # use the newest build in out/
#   scripts/make-fastboot-package.sh 22.10.2026
#
# Layout is what @lineageos-infra/android-fastboot's flashFactoryZip() (the LineageOS
# web flasher backend) expects — NOT the flat `m dist` layout:
#
#   bronco-fastboot-<tag>.zip
#   ├── avb_custom_key.img          required by the library, flashed before anything else
#   └── image-bronco.zip
#       ├── android-info.txt        require board=bronco
#       ├── super_empty.img         → fastbootd: update-super
#       └── boot dtbo vendor_boot vbmeta vbmeta_system   (bootloader)
#           system system_ext product vendor vendor_dlkm (fastbootd, logical)
#
# recovery.img is deliberately NOT packaged: it has no partition on A/B, the library would
# try to flash it and the bootloader would reject the whole run.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
prod=$(dirname "$root")/out/target/product/bronco
key=$root/../external/avb/test/data/testkey_rsa2048.pem
avbtool=$root/../external/avb/avbtool.py

tag=${1:-$(ls -t "$prod"/additional_images-*.zip 2>/dev/null | head -1 | grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}')}
[ -n "${tag:-}" ] || { echo "no build in $prod (pass a tag)" >&2; exit 1; }

boot_images="boot.img dtbo.img vendor_boot.img vbmeta.img vbmeta_system.img"
system_images="system.img system_ext.img product.img vendor.img vendor_dlkm.img"
for f in $boot_images $system_images super_empty.img android-info.txt; do
    [ -f "$prod/$f" ] || { echo "missing $prod/$f" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# avb_custom_key.img is the public half of BOARD_AVB_KEY_PATH, exactly what
# `fastboot flash avb_custom_key` takes.
python3 "$avbtool" extract_public_key --key "$key" --output "$tmp/avb_custom_key.img"

printf 'require board=bronco\n' > "$tmp/android-info.txt"
cp "$prod/super_empty.img" "$tmp/"
for f in $boot_images $system_images; do cp "$prod/$f" "$tmp/"; done

# deflate level 1: the images are already compressed blobs; level 9 buys a few percent for
# minutes of CPU on a 3.5 GB set. `zip` is not on every host, 7z is.
if command -v zip >/dev/null; then
    mkzip() { zip -q -1 -j "$@"; }
else
    mkzip() { out=$1; shift; 7z a -tzip -mx=1 -bso0 -bsp0 "$out" "$@" >/dev/null; }
fi
( cd "$tmp" && mkzip image-bronco.zip android-info.txt super_empty.img \
    $boot_images $system_images )

mkdir "$tmp/pkg"
mv "$tmp/avb_custom_key.img" "$tmp/pkg/"
mv "$tmp/image-bronco.zip" "$tmp/pkg/"
out=$prod/bronco-fastboot-$tag.zip
rm -f "$out"
( cd "$tmp/pkg" && mkzip "$out" avb_custom_key.img image-bronco.zip )

ls -l "$out"
sha256sum "$out"
echo
echo "browser manifest entry:"
printf '  "rom": { "url": "/bronco/latest/%s", "sha256": "%s" }\n' \
    "$(basename "$out")" "$(sha256sum "$out" | cut -d' ' -f1)"
