#!/bin/sh
# platform: host-agnostic
#   usage: fsck-images.sh DIR
#          Checks every image mkimages.sh made in DIR with Linux's own checker, read-only. Exits 0
#          only if all are clean; prints one TAP line per image. Linux only.
set -u
[ "$#" -eq 1 ] || { echo "usage: fsck-images.sh DIR" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "fsck-images.sh: needs Linux's fsck tools" >&2; exit 77; }
d=$1 n=0 bad=0
check() {
  n=$((n + 1))
  if "$@" > "$d/fsck-$n.log" 2>&1; then echo "ok $n - $*"
  else echo "not ok $n - $* (see $d/fsck-$n.log)"; bad=1; fi
}
L=$(cd "$(dirname "$0")" && pwd)
check sh "$L/check-fs.sh" ext4 "$d/ext4.img"
check sh "$L/check-fs.sh" ext4 "$d/ext4-8g.img"
check sh "$L/check-fs.sh" btrfs "$d/btrfs.img"
check sh "$L/check-fs.sh" xfs "$d/xfs.img"
check sh "$L/check-fs.sh" ntfs "$d/ntfs.img"
exit $bad
