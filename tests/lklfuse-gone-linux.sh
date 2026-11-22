#!/bin/sh
# platform: host-agnostic -- on the Linux host (build/linux-host.sh, LINUX_HOST_FUSE=1), building lklfuse if need be
#   usage: lklfuse-gone-linux.sh
#          A disk pulled out while lklfuse has it mounted: once its reads fail with ENXIO (tests/lib/gone-shim.c
#          stands in for the pull, preloaded into lklfuse), lklfuse says the device is gone, takes its FUSE mount
#          down and exits 1, rather than serving I/O errors from a dead mount forever. Skips (77) off Linux or
#          without /dev/fuse. Builds lklfuse (LKLFUSE, default /work/gate0-linux/out/lklfuse) when it is missing.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LKLFUSE=${LKLFUSE:-/work/gate0-linux/out/lklfuse}
[ "$(uname -s)" = Linux ] || { echo "lklfuse-gone-linux.sh: Linux host only" >&2; exit 77; }
[ -c /dev/fuse ] || { echo "lklfuse-gone-linux.sh: no /dev/fuse (LINUX_HOST_FUSE=1?)" >&2; exit 77; }
if [ ! -x "$LKLFUSE" ]; then
  sh "$ROOT/build/build-lkl-linux.sh" "$(dirname "$LKLFUSE")" > "${TMPDIR:-/tmp}/lklfuse-gone-build.log" 2>&1 &&
    [ -x "$LKLFUSE" ] || { echo "lklfuse-gone-linux.sh: building lklfuse failed:" >&2; tail -20 "${TMPDIR:-/tmp}/lklfuse-gone-build.log" >&2; exit 1; }
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/lklfuse-gone.XXXXXX")
# platform: the FUSE mount point is in the container's own /tmp, not on the /work volume: on GitHub's runner
#           fusermount3 refuses a mount point on that volume ("mount failed: Permission denied"), as
#           apfs-fixtures-linux.sh's /tmp one is not
MNT=$(mktemp -d /tmp/lklfuse-gone-mnt.XXXXXX)
pid=
trap 'fusermount3 -uz "$MNT" 2>/dev/null; [ -z "$pid" ] || kill -9 "$pid" 2>/dev/null; rm -rf "$W"; rmdir "$MNT" 2>/dev/null' EXIT
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }

cc -shared -fPIC -O2 -Wall -o "$W/gone-shim.so" "$ROOT/tests/lib/gone-shim.c" -ldl; ok $? "build the stand-in for a pull"
truncate -s 64M "$W/disk.img" && mkfs.ext4 -q -F "$W/disk.img"; ok $? "an ext4 disk"
GONE_TRIGGER=$W/pulled GONE_IMAGE=$W/disk.img LD_PRELOAD=$W/gone-shim.so \
  "$LKLFUSE" -f -o type=ext4 "$W/disk.img" "$MNT" > "$W/log" 2>&1 &
pid=$!
i=0; until grep -q " $MNT " /proc/mounts && ls "$MNT" > /dev/null 2>&1; do
  i=$((i + 1)); [ $i -le 200 ] && kill -0 "$pid" 2>/dev/null || break; sleep 0.1
done
echo hello > "$MNT/before" && sync; ok $? "mounted, and written to"

touch "$W/pulled"
# platform: what the user does next: anything that reaches the disk (a new file, then a sync, so the write goes out)
#           each bounded: on a dead mount they can hang for good, which is the failure this test is about
timeout 20 sh -c 'head -c 1048576 /dev/urandom > "$1/after"; sync; ls -R "$1"' _ "$MNT" > /dev/null 2>&1
i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
! kill -0 "$pid" 2>/dev/null || false; ok $? "lklfuse ends within 15 s of the disk going"
if kill -0 "$pid" 2>/dev/null; then rc=running; else wait "$pid"; rc=$?; pid=; fi
[ "$rc" = 1 ]; ok $? "and exits 1 ($rc)"
grep -q "is gone" "$W/log"; r=$?; ok $r "saying the device is gone ($(grep 'gone' "$W/log" | head -n 1))"
if [ $r -ne 0 ]; then
  sed 's/^/#   /' "$W/log" | tail -n 30
  # platform: why fusermount3 refused a mount on this host (GitHub's runner refuses some that a local Docker allows): who
  #           we are, the mount point, /dev/fuse, fusermount3, our capabilities and AppArmor label, and the mounts involved
  fuse_diag() {
    echo "fuse_diag: $(id); $(ls -ld "$1"); $(ls -l /dev/fuse); $(ls -l "$(command -v fusermount3)")"
    grep -E '^(CapEff|CapBnd|NoNewPrivs)' /proc/self/status
    echo "apparmor: $(cat /proc/self/attr/current 2>/dev/null)"
    grep -E ' (/work|/tmp|/) ' /proc/mounts
  }
  fuse_diag "$MNT" | sed 's/^/#   /'
  # platform: the same mount, from an image in the container's /tmp (apfs-fixtures-linux.sh's, which mounts)
  cp "$W/disk.img" /tmp/lklfuse-gone-probe.img && m2=$(mktemp -d /tmp/lklfuse-gone-m2.XXXXXX) &&
    { timeout 20 "$LKLFUSE" -f -o type=ext4 /tmp/lklfuse-gone-probe.img "$m2" > "$W/log2" 2>&1 & p2=$!; sleep 5
      grep " $m2 " /proc/mounts | sed 's/^/#   from \/tmp: mounted: /'; fusermount3 -u "$m2" 2>/dev/null; wait $p2
      sed 's/^/#   from \/tmp: /' "$W/log2"; rm -f /tmp/lklfuse-gone-probe.img; rmdir "$m2"; }
fi
! grep -q "^lklfuse: I/O error on" "$W/log" || false; ok $? "and nothing more about it: no I/O error line for a device already gone (10.9's pull printed both)"
! grep -q " $MNT " /proc/mounts || false; ok $? "its FUSE mount is down, not left dead"
[ -z "$pid" ] || { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=; }
echo "1..$n"; exit $bad
