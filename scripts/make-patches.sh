#!/usr/bin/env bash
# Regenerate patches/*.patch from the working tree of the AOSP checkout.
#
# The working tree is the source of truth; the patches are only how it survives
# `repo sync`. Files a patch *creates* must be intent-to-added first, or `git diff`
# omits them and the patch silently loses content.
#
#   scripts/make-patches.sh
set -u
infra=$(cd "$(dirname "$0")/.." && pwd)
tree=$(dirname "$infra")
cd "$tree" || exit 1

emit() {  # repo patch-name [file-to-add]
    local repo=$1 name=$2 add=${3:-}
    [ -n "$add" ] && git -C "$repo" add -N "$add" 2>/dev/null
    git -C "$repo" diff > "$infra/patches/$name.patch" || { echo "failed: $repo" >&2; return 1; }
    printf "  %-30s %4d lines\n" "$name.patch" "$(wc -l < "$infra/patches/$name.patch")"
}

while IFS=: read -r repo name created; do
    [[ $repo == \#* || -z $repo ]] && continue
    emit "$repo" "$name" "$created"
done < "$infra/scripts/patches.txt"
