#!/usr/bin/env bash
# (Re)create the long-running build container. Builds run inside it:
#   scripts/container.sh
#   podman exec infinity-build /work/infinity/scripts/build.sh
#
# Host uid 1000 maps to uid 1000 in the container (--userns=keep-id), so out/ stays
# owned by you on the host. The ccache lives in the podman volume, not the tree.
set -eu
infra=$(cd "$(dirname "$0")/.." && pwd)
tree=$(dirname "$infra")

podman rm -f infinity-build >/dev/null 2>&1 || true
podman run -d --name infinity-build \
    --user 1000:1000 --userns=keep-id \
    --ipc=shareable --security-opt seccomp=unconfined \
    -e CCACHE_DIR=/ccache -e HOME=/work/.home \
    -v infinity-ccache:/ccache \
    -v "$tree:/work" \
    -w /work \
    localhost/bronco-rom-base:rom17 sleep infinity >/dev/null
podman exec infinity-build id
