#!/usr/bin/env bash
# Publish the newest build to rom.flac.moe and update the OTA feed.
#
#   scripts/publish.sh --dry-run              # default: print, change nothing
#   scripts/publish.sh                        # latest/ replaced, previous kept in archive/
#   scripts/publish.sh --purge                # delete every old rom on the VPS first
#   scripts/publish.sh --purge --no-push      # ... without touching the git feed
#
# Uploads the OTA zip, additional_images-<tag>.zip, recovery.img and the checksum
# files, rewrites bronco.json (the URL the in-ROM Updater reads), commits and pushes
# bronco.json + changelog/bronco.txt to GitHub.
#
# Remote detail: caddy serves /home/rocky/podman/caddy/site as rom.flac.moe, and the
# login shell there is fish — everything remote goes through `bash -lc`.
set -eu
infra=$(cd "$(dirname "$0")/.." && pwd)
prod=$(dirname "$infra")/out/target/product/bronco
host=mc
site=/home/rocky/podman/caddy/site/bronco
baseurl=https://rom.flac.moe/bronco

dry=1 purge=0 push=1
for a in "$@"; do
    case $a in
        --dry-run) dry=1 ;;
        --yes|-y) dry=0 ;;
        --purge)  purge=1 ;;
        --no-push) push=0 ;;
        *) echo "usage: $0 [--yes] [--purge] [--no-push] [--dry-run]" >&2; exit 2 ;;
    esac
done

run() {  # echo, or execute when not dry
    if [ "$dry" = 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi
}
rsh() {  # remote command; the login shell there is fish, so wrap in bash -lc
    if [ "$dry" = 1 ]; then printf '  would: ssh %s bash -lc %s\n' "$host" "$*"; else ssh "$host" bash -lc "$*"; fi
}

zip=$(ls -t "$prod"/Project_Infinity-X-*-VANILLA-UNOFFICIAL.zip 2>/dev/null | head -1)
[ -n "$zip" ] || { echo "no OTA zip in $prod" >&2; exit 1; }
name=$(basename "$zip")
tag=$(grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}' <<<"$name" | head -1)   # release date
imgs=$prod/additional_images-$tag.zip
rec=$prod/recovery.img
for f in "$zip" "$imgs" "$rec"; do
    [ -f "$f" ] || { echo "missing artifact: $f" >&2; exit 1; }
done

md5=$(md5sum "$zip" | cut -d' ' -f1)
size=$(stat -c %s "$zip")
echo "publishing $name"
echo "  tag $tag   $size bytes   md5 $md5"

# checksums next to the zip, as the release page has always had them
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
( cd "$prod" && md5sum "$name" "additional_images-$tag.zip" recovery.img > "$tmp/MD5SUMS" )
( cd "$prod" && sha256sum "$name" "additional_images-$tag.zip" recovery.img > "$tmp/SHA256SUMS" )

if [ "$purge" = 1 ]; then
    echo "remote: deleting every old rom"
    rsh "rm -rf $site"
else
    echo "remote: latest/ -> archive/$tag/"
    rsh "mkdir -p $site/archive/$tag && mv $site/latest/* $site/archive/$tag/ 2>/dev/null || true"
fi
rsh "mkdir -p $site/latest"

run rsync -ah --info=progress2 \
    "$zip" "$imgs" "$rec" "$tmp/MD5SUMS" "$tmp/SHA256SUMS" "$host:$site/latest/"

url=$baseurl/latest/$name
if [ "$dry" = 0 ]; then
    got=$(curl -sIL "$url" | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
    [ "$got" = "$size" ] || { echo "verify FAILED: $url serves $got bytes, want $size" >&2; exit 1; }
    echo "verified: $url ($got bytes)"
else
    echo "  would: curl -sIL $url"
fi

# OTA feed: the Updater app reads this from raw.githubusercontent.com
if [ "$dry" = 1 ]; then echo "  would: rewrite bronco.json for $name"; fi
[ "$dry" = 1 ] || python3 - "$infra/bronco.json" "$name" "$url" "$size" "$md5" <<'PY'
import json, sys, time
feed, name, url, size, md5 = sys.argv[1:6]
json.dump({"response": [{"filename": name, "download": url, "size": int(size),
                         "timestamp": int(time.time()), "version": "4.1", "md5": md5}]},
          open(feed, "w"), indent=2)
open(feed, "a").write("\n")
PY

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
