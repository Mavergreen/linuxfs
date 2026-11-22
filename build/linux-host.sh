#!/bin/sh
# platform: host-agnostic
#   usage: linux-host.sh CMD [ARG...]
#          Runs CMD in this repo's Linux build container (build/linux-host/Dockerfile), with the shared tree
#          ($LINUX_HOST_SHARE, default /Users) mounted at the same path and the current directory as the working
#          directory, so paths mean the same thing on both sides. Needs a working `docker` (Container Tools on 10.9).
#          SHIPYARD_SCRIPTS, when it is under the shared tree, is the container's; otherwise the sibling checkout
#          ../mavergreen-shipyard/scripts is. CI sets LINUX_HOST_SHARE to the runner's home, which holds the
#          workspace, the shipyard action's checkout and RUNNER_TEMP. LINUX_HOST_FUSE=1 also gives the container
#          /dev/fuse and the right to mount it.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SHARE=${LINUX_HOST_SHARE:-/Users}
case $ROOT/ in "$SHARE"/*) ;; *) echo "linux-host.sh: $ROOT is not under $SHARE (LINUX_HOST_SHARE)" >&2; exit 2 ;; esac
case ${SHIPYARD_SCRIPTS:-}/ in
  "$SHARE"/?*) sy=$SHIPYARD_SCRIPTS ;;
  *) sy=$(cd "$ROOT/../mavergreen-shipyard/scripts" 2>/dev/null && pwd) ||
       { echo "linux-host.sh: SHIPYARD_SCRIPTS is not under $SHARE, and there is no ../mavergreen-shipyard checkout" >&2; exit 2; } ;;
esac
img=linuxfs-gate0-host
docker build -q -t "$img" "$ROOT/build/linux-host" >/dev/null 2>&1
docker volume create linuxfs-gate0-work >/dev/null
docker run --rm -v linuxfs-gate0-work:/work "$img" sh -c "mkdir -p /work/tmp && chown $(id -u):$(id -g) /work /work/tmp"
fuse=
if [ "${LINUX_HOST_FUSE:-0}" = 1 ]; then
  # platform: fusermount3 refuses a user with no passwd entry, so the host user gets one, written under the shared tree
  pw=$HOME/Library/Caches/mm-build/linux-host-passwd
  mkdir -p "${pw%/*}"
  printf "root:x:0:0::/root:/bin/sh\n%s:x:%s:%s::%s:/bin/sh\n" "$(id -un)" "$(id -u)" "$(id -g)" "$HOME" > "$pw"
  fuse="--device /dev/fuse --cap-add SYS_ADMIN -v $pw:/etc/passwd:ro"
fi
# shellcheck disable=SC2086  # $fuse is deliberately split into options
exec docker run --rm $fuse -u "$(id -u):$(id -g)" -v "$SHARE:$SHARE" -v linuxfs-gate0-work:/work -w "$PWD" \
  -e HOME="$HOME" -e TMPDIR=/work/tmp \
  -e MAVERICKS_BUILD_ROOT="$HOME/Library/Caches/mm-build" \
  -e SHIPYARD_SCRIPTS="$sy" \
  -e MAVERICKS_SOURCE_CACHE="$HOME/Library/Caches/mavericks-sources" \
  "$img" "$@"
