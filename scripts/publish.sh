#!/usr/bin/env bash
# Publish the newest build to rom.flac.moe and update the OTA feed.
#
#   scripts/publish.sh --dry-run              # default: print, change nothing
#   scripts/publish.sh                        # latest/ replaced, old build deleted
#   scripts/publish.sh --no-push              # upload only, leave the git feed alone
#   scripts/publish.sh --yes --feed-only      # repair bronco.json only (no upload)
#
# Only one build is kept: the upload lands in a staging directory, its size is checked, and
# only then is latest/ replaced — so a failed or interrupted upload leaves the published
# build intact.
#
# Server details are not in this file: this repo is public. They come from
# infinity/.env.publish (gitignored) or the environment:
#   PUBLISH_HOST  ssh alias/host           (required)
#   PUBLISH_ROOT  directory served below the base url (required)
#   PUBLISH_URL   public base url          (default https://rom.flac.moe/bronco)
# The remote login shell there is fish, so everything remote goes through `bash -lc`.
set -eu
infra=$(cd "$(dirname "$0")/.." && pwd)
prod=$(dirname "$infra")/out/target/product/bronco
# .env.publish fills only what the environment did not already set, so an explicit
# PUBLISH_ROOT=... on the command line wins over the file.
if [ -f "$infra/.env.publish" ]; then
    while IFS='=' read -r k v; do
        case $k in PUBLISH_*) [ -n "${!k:-}" ] || export "$k=$v" ;; esac
    done < <(grep -v '^#' "$infra/.env.publish")
fi
host=${PUBLISH_HOST:?publish: set PUBLISH_HOST (see infinity/.env.publish)}
site=${PUBLISH_ROOT:?publish: set PUBLISH_ROOT (see infinity/.env.publish)}
baseurl=${PUBLISH_URL:-https://rom.flac.moe/bronco}
stage=$site/_staging

dry=1 push=1 feed_only=0
for a in "$@"; do
    case $a in
        --dry-run) dry=1 ;;
        --yes|-y) dry=0 ;;
        --no-push) push=0 ;;
        --feed-only) feed_only=1 ;;
        *) echo "usage: $0 [--yes] [--no-push] [--feed-only] [--dry-run]" >&2; exit 2 ;;
    esac
done

run() {  # echo, or execute when not dry
    if [ "$dry" = 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi
}
rsh() {  # remote command; the login shell there is fish, so wrap in bash -lc
    if [ "$dry" = 1 ]; then printf '  would: ssh %s bash -lc %s\n' "$host" "$*"; else ssh "$host" "bash -lc \"$*\""; fi
}

zip=$(ls -t "$prod"/Project_Infinity-X-*-VANILLA-UNOFFICIAL.zip 2>/dev/null | head -1)
[ -n "$zip" ] || { echo "no OTA zip in $prod" >&2; exit 1; }
name=$(basename "$zip")
tag=$(grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}' <<<"$name" | head -1)   # release date
# Project_Infinity-X-<rom version>-<device>-<date>-VANILLA-<type>.zip — read the ROM
# version out of the artifact instead of hardcoding it, so a vendor/infinity bump
# (4.1 -> 4.2 -> ...) does not silently publish a wrong feed version.
romver=$(sed -n 's/^Project_Infinity-X-\([^-]*\)-.*/\1/p' <<<"$name")
[ -n "$romver" ] || { echo "cannot parse the ROM version from $name" >&2; exit 1; }
imgs=$prod/additional_images-$tag.zip
rec=$prod/recovery.img
fb=$prod/bronco-fastboot-$tag.zip      # optional: browser-flashable package
for f in "$zip" "$imgs" "$rec"; do
    [ -f "$f" ] || { echo "missing artifact: $f" >&2; exit 1; }
done

build_date=$(sed -n 's/^ro\.build\.date\.utc=//p' "$prod/system/build.prop" 2>/dev/null | head -1)
[ -n "$build_date" ] || { echo "no ro.build.date.utc in $prod/system/build.prop" >&2; exit 1; }
url=$baseurl/latest/$name
md5=$(md5sum "$zip" | cut -d' ' -f1)
size=$(stat -c %s "$zip")
echo "publishing $name"
echo "  tag $tag   ROM $romver   $size bytes   md5 $md5   build date $build_date"

# checksums next to the zip, as the release page has always had them
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
extra=()
[ -f "$fb" ] && extra=("$(basename "$fb")")
sums=("$name" "additional_images-$tag.zip" recovery.img "${extra[@]}")
( cd "$prod" && md5sum "${sums[@]}" > "$tmp/MD5SUMS" )
( cd "$prod" && sha256sum "${sums[@]}" > "$tmp/SHA256SUMS" )

# The web flasher points at this file instead of at a versioned zip, so a new build never needs
# a config edit there: url, size and sha256 of both artifacts are read from latest/ itself.
imgs_name=$(basename "$imgs")
ota_ver=$(sed -n 's/.*Project_Infinity-X-\([0-9.]*\)-.*/\1/p' <<<"$name")
sha_of() { awk -v name="$1" '$2 == name { print $1 }' "$tmp/SHA256SUMS"; }
cat > "$tmp/latest.json" <<EOF
{
  "build": "Project Infinity X $ota_ver · $tag",
  "ota": { "url": "$url", "size": $size, "sha256": "$(sha_of "$name")" },
  "images": { "url": "$baseurl/latest/$imgs_name", "size": $(stat -c %s "$imgs"), "sha256": "$(sha_of "$imgs_name")" }
}
EOF

if [ "$feed_only" = 1 ]; then
    echo "feed-only: skipping upload and swap"
else
    echo "1/4 upload -> $stage/"
    rsh "mkdir -p $stage"
    rsync_opts=(-ah --partial)
    [ -t 1 ] && rsync_opts+=(--info=progress2)   # progress spam only on a terminal
    run rsync "${rsync_opts[@]}" \
        "$zip" "$imgs" "$rec" "${extra[@]/#/$prod/}" "$tmp/MD5SUMS" "$tmp/SHA256SUMS" "$tmp/latest.json" "$host:$stage/"

    echo "2/4 verify what landed"
    for f in "${sums[@]}"; do
        local_size=$(stat -c %s "$prod/$f")
        if [ "$dry" = 1 ]; then
            printf '  would: check %s is %s bytes on the server\n' "$f" "$local_size"
            continue
        fi
        remote_size=$(ssh "$host" "bash -lc \"stat -c %s $stage/$f\"" 2>/dev/null || echo 0)
        [ "$remote_size" = "$local_size" ] ||
            { echo "upload incomplete: $f is $remote_size of $local_size bytes; latest/ untouched" >&2; exit 1; }
        echo "  ok $f ($local_size bytes)"
    done

    echo "3/4 swap into place"
    rsh "rm -rf $site/latest && mv $stage $site/latest"

    echo "4/4 verify the served file"
    if [ "$dry" = 0 ]; then
        got=$(curl -sIL "$url" | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
        [ "$got" = "$size" ] || { echo "verify FAILED: $url serves $got bytes, want $size" >&2; exit 1; }
        echo "  verified: $url ($got bytes)"
    else
        echo "  would: curl -sIL $url"
    fi

fi  # end feed_only guard

# OTA feed: the Updater app reads this from raw.githubusercontent.com
if [ "$dry" = 1 ]; then
    echo "  would: rewrite bronco.json for $name"
else
    python3 - "$infra/bronco.json" "$name" "$url" "$size" "$md5" "$build_date" "$romver" <<'PY'
import json, sys
feed, name, url, size, md5, build_date, romver = sys.argv[1:8]
json.dump({"response": [{"filename": name, "download": url, "size": int(size),
                         "timestamp": int(build_date), "version": romver, "md5": md5}]},
          open(feed, "w"), indent=2)
open(feed, "a").write("\n")
PY
fi

iso=$(awk -F. '{print $3"-"$2"-"$1}' <<<"$tag")   # changelog uses yyyy-mm-dd
if grep -qE "$tag|$iso" "$infra/changelog/bronco.txt"; then
    echo "changelog mentions $tag"
else
    echo "WARNING: changelog/bronco.txt does not mention $tag — edit it before pushing" >&2
fi

if [ "$push" = 1 ]; then
    run git -C "$infra" add bronco.json changelog/bronco.txt
    run git -C "$infra" commit -m "Feed: publish build $tag"
    run git -C "$infra" push origin HEAD
fi
