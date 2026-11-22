#!/bin/sh
# platform: host-agnostic
#   usage: apfs-image.sh IMAGE
#          Makes IMAGE, a 64 MiB APFS container (volume "linuxfs") holding hello.txt ("hello apfs") and
#          d/f1..d/f50, written through linux-apfs-rw's experimental write support (readwrite: tests only,
#          linuxfs never passes it) and checked by apfsck. Needs build-lkl-linux.sh's lklfuse ($LKLFUSE, else
#          /work/gate0-linux/out/lklfuse), mkapfs, apfsck and /dev/fuse. Linux only.
set -eu
[ "$#" -eq 1 ] || { echo "usage: apfs-image.sh IMAGE" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "apfs-image.sh: Linux only" >&2; exit 77; }
LKLFUSE=${LKLFUSE:-/work/gate0-linux/out/lklfuse}
img=$1 m=$(mktemp -d "${TMPDIR:-/tmp}/apfs-image.XXXXXX")
rm -f "$img"; truncate -s 64M "$img"; mkapfs -L linuxfs "$img" > /dev/null
"$LKLFUSE" -f -o type=apfs,opts=readwrite "$img" "$m" > "$m.log" 2>&1 & p=$!
i=0; until grep -q " $m " /proc/mounts; do
  i=$((i + 1)); { [ $i -le 100 ] && kill -0 "$p" 2>/dev/null; } || { cat "$m.log" >&2; exit 1; }; sleep 0.1
done
echo "hello apfs" > "$m/hello.txt"; mkdir "$m/d"
i=1; while [ $i -le 50 ]; do echo $i > "$m/d/f$i"; i=$((i + 1)); done
fusermount3 -u "$m"; wait "$p"
rmdir "$m"; rm -f "$m.log"
apfsck "$img" > /dev/null
