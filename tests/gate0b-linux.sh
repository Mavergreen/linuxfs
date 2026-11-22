#!/bin/sh
# platform: host-agnostic
#   usage: gate0b-linux.sh
#          Gate 0b's baseline on Linux: lklfuse (ELF) mounts ext4, btrfs, xfs and NTFS images (and APFS, read-only), and
#          ordinary tools write through the mount. After `fusermount3 -u`, lklfuse must exit 0, the
#          image must be clean by Linux's checker, and a second mount must read everything back.
#          Needs build-lkl-linux.sh's output and /dev/fuse: run as
#          `LINUX_HOST_FUSE=1 build/linux-host.sh sh tests/gate0b-linux.sh`.
set -u
[ "$(uname -s)" = Linux ] || { echo "gate0b-linux.sh: Linux host only" >&2; exit 77; }
[ -c /dev/fuse ] || { echo "gate0b-linux.sh: no /dev/fuse (LINUX_HOST_FUSE=1?)" >&2; exit 77; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${GATE0_WORK:-/work/gate0-linux}
OUT=$WORK/out IMG=$WORK/images0b
# platform: the FUSE mount point is in the container's own /tmp, not on the /work volume: on GitHub's runner
#           fusermount3 refuses a mount point on that volume ("mount failed: Permission denied"), as
#           apfs-fixtures-linux.sh's /tmp one is not
MNT=$(mktemp -d /tmp/gate0b-mnt.XXXXXX)
LKLFUSE=${LKLFUSE:-$OUT/lklfuse}
n=0 bad=0 pid=
step() {
  n=$((n + 1)); what=$1; shift
  if "$@" > "$WORK/0b-step-$n.log" 2>&1; then echo "ok $n - $what"
  else echo "not ok $n - $what (see $WORK/0b-step-$n.log)"; sed 's/^/#   /' "$WORK/0b-step-$n.log" | tail -n 20; bad=1; fi
}
# platform: why fusermount3 refused a mount on this host (GitHub's runner refuses some that a local Docker allows): who
#           we are, the mount point, /dev/fuse, fusermount3, our capabilities and AppArmor label, and the mounts involved
fuse_diag() {
  echo "fuse_diag: $(id); $(ls -ld "$1"); $(ls -l /dev/fuse); $(ls -l "$(command -v fusermount3)")"
  grep -E '^(CapEff|CapBnd|NoNewPrivs)' /proc/self/status
  echo "apparmor: $(cat /proc/self/attr/current 2>/dev/null)"
  grep -E ' (/work|/tmp|/) ' /proc/mounts
}
fstype() { case $1 in ntfs) echo ntfs3 ;; *) echo "$1" ;; esac; }
checker() { sh "$ROOT/tests/lib/check-fs.sh" "$@"; }
# platform: the FUSE mount appears first, and a listing is answered only once lklfuse's loop runs, after LKL's
#           mount; a failed LKL mount ends lklfuse
mount_fs() {
  ! grep -q " $MNT " /proc/mounts || { echo "something is already mounted on $MNT"; return 1; }
  "$LKLFUSE" -f -o "type=$(fstype "$1")" "$IMG/$1.img" "$MNT" > "$WORK/lklfuse-$1.log" 2>&1 &
  pid=$!
  i=0
  until grep -q " $MNT " /proc/mounts; do
    i=$((i + 1)); [ $i -le 300 ] || { echo "no FUSE mount after 30 s"; cat "$WORK/lklfuse-$1.log"; return 1; }
    kill -0 "$pid" 2>/dev/null || { echo "lklfuse ended before mounting:"; cat "$WORK/lklfuse-$1.log"; fuse_diag "$MNT"; return 1; }
    sleep 0.1
  done
  ls "$MNT" > /dev/null && kill -0 "$pid" || { cat "$WORK/lklfuse-$1.log"; return 1; }
}
unmount_fs() {
  fusermount3 -u "$MNT" || return 1
  wait "$pid"; rc=$?
  pid=
  [ $rc -eq 0 ] || { echo "lklfuse exited $rc"; return 1; }
}
MTIME=$(date -u -d '2020-01-02 03:04' +%s)
mounted() { grep -q " $MNT " /proc/mounts || { echo "nothing mounted on $MNT"; return 1; }; }
write_through() {
  mounted &&
  cp "$WORK/payload" "$MNT/big" &&
  mkdir "$MNT/d" &&
  i=1 && while [ $i -le 200 ]; do echo $i > "$MNT/d/f$i" || return 1; i=$((i + 1)); done &&
  mv "$MNT/d/f1" "$MNT/d/moved" &&
  setfattr -n user.k -v v "$MNT/big" &&
  touch -d "@$MTIME" "$MNT/big"
}
read_back() {
  mounted &&
  cmp "$WORK/payload" "$MNT/big" &&
  [ "$(cat "$MNT/d/f200")" = 200 ] &&
  [ "$(cat "$MNT/d/moved")" = 1 ] && [ ! -e "$MNT/d/f1" ] &&
  [ "$(getfattr --only-values -n user.k "$MNT/big")" = v ] &&
  [ "$(stat -c %Y "$MNT/big")" = "$MTIME" ]
}
killed() {
  mount_fs "$1" || return 1
  echo 0 > "$WORK/writes"
  ( i=0; while cp "$WORK/payload" "$MNT/k$i" 2>/dev/null; do i=$((i + 1)); echo $i > "$WORK/writes"; done ) &
  w=$!
  sleep 3; kill -9 "$pid"; wait "$pid"; rc=$?; pid=
  wait "$w"
  fusermount3 -u -z "$MNT"
  echo "lklfuse exit $rc after $(cat "$WORK/writes") copies"
  [ $rc -eq 137 ] && [ "$(cat "$WORK/writes")" -ge 1 ]
}
needs_replay() { dumpe2fs -h "$1" 2>/dev/null | grep -q needs_recovery; }
dirty_refused() {
  "$LKLFUSE" -f -o type=ntfs3 "$IMG/ntfs.img" "$MNT" > "$WORK/lklfuse-dirty.log" 2>&1 &
  p=$! i=0
  while kill -0 "$p" 2>/dev/null; do
    i=$((i + 1)); [ $i -le 100 ] || { fusermount3 -u "$MNT"; wait "$p"; echo "lklfuse mounted the dirty volume"; return 1; }
    sleep 0.1
  done
  wait "$p"; rc=$?
  cat "$WORK/lklfuse-dirty.log"
  [ $rc -ne 0 ] && grep -q 'volume is dirty' "$WORK/lklfuse-dirty.log" && ! grep -q " $MNT " /proc/mounts
}
mkdir -p "$WORK"
trap 'fusermount3 -uz "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT
[ -x "$LKLFUSE" ] || { echo "gate0b-linux.sh: no $LKLFUSE (run build/build-lkl-linux.sh)" >&2; exit 1; }
head -c 4194304 /dev/urandom > "$WORK/payload"
truncate -s 64M "$WORK/ops.img" && mkfs.ext4 -q -F "$WORK/ops.img"
step "lklfuse callbacks report host errno values and flags" sh -c '"$1" "$2" > "$3"; r=$?; cat "$3"; exit $r' _ "$OUT/tests/lklfuse-ops" "$WORK/ops.img" "$WORK/ops.log"
step "make images" sh "$ROOT/tests/lib/mkimages.sh" --small "$IMG"
for fs in ext4 btrfs xfs ntfs; do
  step "lklfuse mounts $fs" mount_fs "$fs"
  step "write through the $fs mount" write_through
  step "unmount $fs; lklfuse exits 0" unmount_fs
  step "$fs is clean after unmount" checker "$fs" "$IMG/$fs.img"
  step "lklfuse mounts $fs again" mount_fs "$fs"
  step "everything reads back on $fs" read_back
  step "unmount $fs again" unmount_fs
  step "$fs is still clean" checker "$fs" "$IMG/$fs.img"
done
# spec: -o ro: the disk is read-only to the kernel too. P3-1's XFS (tests/fixtures/xfs, a clean log) failed so on 10.9:
#       XFS clears stale log blocks unless the device itself is read-only, and writes to a read-only descriptor fail
gunzip -c "$ROOT/tests/fixtures/xfs/ro-clean-log.img.gz" > "$IMG/xfsro.img" && chmod 444 "$IMG/xfsro.img"
xfs_ro() { "$LKLFUSE" -f -o type=xfs,ro "$IMG/xfsro.img" "$MNT" > "$WORK/lklfuse-xfsro.log" 2>&1 & pid=$!
  i=0; until grep -q " $MNT " /proc/mounts; do i=$((i + 1)); [ $i -le 100 ] && kill -0 "$pid" 2>/dev/null || { cat "$WORK/lklfuse-xfsro.log"; return 1; }; sleep 0.1; done
  ls "$MNT" > /dev/null && kill -0 "$pid" || { cat "$WORK/lklfuse-xfsro.log"; return 1; }; }
step "lklfuse -o ro mounts the XFS that 10.9 could not (its disk read-only to the kernel)" xfs_ro
step "unmount it" unmount_fs
step "not one byte of it changed" sh -c 'gunzip -c "$1" | cmp - "$2"' _ "$ROOT/tests/fixtures/xfs/ro-clean-log.img.gz" "$IMG/xfsro.img"
# spec: build/graft-apfs.sh --
#       APFS: linuxfs mounts it read-only. The image is filled through linux-apfs-rw's experimental write support
#       (readwrite, here only), must then pass apfsck, and must read back on a plain, read-only mount that refuses writes.
truncate -s 512M "$IMG/apfs.img" && mkapfs -L linuxfs "$IMG/apfs.img" > /dev/null
apfs_rw() { "$LKLFUSE" -f -o type=apfs,opts=readwrite "$IMG/apfs.img" "$MNT" > "$WORK/lklfuse-apfs.log" 2>&1 & pid=$!
  i=0; until grep -q " $MNT " /proc/mounts; do i=$((i + 1)); [ $i -le 100 ] && kill -0 "$pid" 2>/dev/null || return 1; sleep 0.1; done
  ls "$MNT" > /dev/null; }
apfs_fill() { mounted && cp "$WORK/payload" "$MNT/big" && mkdir "$MNT/d" &&
  i=1 && while [ $i -le 200 ]; do echo $i > "$MNT/d/f$i" || return 1; i=$((i + 1)); done && mv "$MNT/d/f1" "$MNT/d/moved"; }
apfs_read() { mounted && cmp "$WORK/payload" "$MNT/big" && [ "$(cat "$MNT/d/f200")" = 200 ] &&
  [ "$(cat "$MNT/d/moved")" = 1 ] && [ ! -e "$MNT/d/f1" ]; }
refuses_write() { ! touch "$MNT/nope" 2> "$WORK/apfs-ro.err" && grep -q 'Read-only' "$WORK/apfs-ro.err"; }
step "lklfuse mounts apfs read-write (to fill it)" apfs_rw
step "fill apfs" apfs_fill
step "unmount apfs; lklfuse exits 0" unmount_fs
step "apfs is clean after unmount" checker apfs "$IMG/apfs.img"
step "lklfuse mounts apfs read-only (as linuxfs does)" mount_fs apfs
step "everything reads back on apfs" apfs_read
step "the read-only apfs mount refuses a write" refuses_write
step "unmount apfs again" unmount_fs
step "apfs is still clean" checker apfs "$IMG/apfs.img"
# spec: patches/lkl/0007-lklfuse-passfd.patch --
#       passfd=: an encrypted volume's password, from a descriptor, into the mount data (a volume that is not encrypted
#       ignores it); the encrypted volumes themselves come from macOS (tests/apfs-fixtures-linux.sh)
pass_mount() { "$LKLFUSE" -f -o type=apfs,ro,passfd=5 "$IMG/apfs.img" "$MNT" > "$WORK/lklfuse-pass.log" 2>&1 5<<'P' &
not-needed
P
  pid=$!
  i=0; until grep -q " $MNT " /proc/mounts; do i=$((i + 1)); { [ $i -le 100 ] && kill -0 "$pid" 2>/dev/null; } || { cat "$WORK/lklfuse-pass.log"; return 1; }; sleep 0.1; done
  apfs_read; }
bad_passfd() { timeout 20 "$LKLFUSE" -f -o type=apfs,ro,passfd=9 "$IMG/apfs.img" "$MNT" > "$WORK/lklfuse-badpass.log" 2>&1; rc=$?
  fusermount3 -u "$MNT" 2>/dev/null; cat "$WORK/lklfuse-badpass.log"; [ $rc -ne 0 ] && [ $rc -ne 124 ] && grep -q passfd "$WORK/lklfuse-badpass.log"; }
step "lklfuse takes a password from passfd= (an unencrypted volume ignores it)" pass_mount
step "unmount apfs (passfd)" unmount_fs
step "a passfd= that is not open is refused" bad_passfd
# spec: patches/lkl/0006-lklfuse-tier2file.patch --
#       APFS Fusion: one container on two devices; lklfuse attaches the second (tier2file=) and the driver reads both
truncate -s 64M "$IMG/ssd.img" && truncate -s 256M "$IMG/hdd.img" && mkapfs -L Fused -F "$IMG/hdd.img" "$IMG/ssd.img" > /dev/null
fusion_mount() { "$LKLFUSE" -f -o "type=apfs,tier2file=$IMG/hdd.img" "$IMG/ssd.img" "$MNT" > "$WORK/lklfuse-fusion.log" 2>&1 & pid=$!
  i=0; until grep -q " $MNT " /proc/mounts; do i=$((i + 1)); { [ $i -le 100 ] && kill -0 "$pid" 2>/dev/null; } || { cat "$WORK/lklfuse-fusion.log"; return 1; }; sleep 0.1; done
  ls -la "$MNT" > /dev/null && kill -0 "$pid"; }
no_tier2() { timeout 20 "$LKLFUSE" -f -o type=apfs "$IMG/ssd.img" "$MNT" > "$WORK/lklfuse-notier2.log" 2>&1; rc=$?
  fusermount3 -u "$MNT" 2>/dev/null; cat "$WORK/lklfuse-notier2.log"; [ $rc -ne 0 ] && [ $rc -ne 124 ]; }
step "lklfuse mounts an APFS Fusion container from its two devices" fusion_mount
step "unmount the Fusion container; lklfuse exits 0" unmount_fs
step "without its second device, the Fusion container is refused" no_tier2
step "the Fusion container is clean" sh -c 'apfsck -F "$1" "$2"' _ "$IMG/hdd.img" "$IMG/ssd.img"
step "kill -9 lklfuse mid-write on ext4" killed ext4
step "ext4's journal needs replaying" needs_replay "$IMG/ext4.img"
step "lklfuse mounts ext4 after the kill (replays the journal)" mount_fs ext4
step "what was written before still reads back" read_back
step "unmount ext4" unmount_fs
step "ext4 is clean after the replay" checker ext4 "$IMG/ext4.img"
step "kill -9 lklfuse mid-write on ntfs" killed ntfs
step "lklfuse refuses the dirty NTFS volume, and says why" dirty_refused
lock_symlink() {
  ln -sf "$WORK/victim" "$WORK/lock-link"; : > "$WORK/victim"
  timeout 10 "$LKLFUSE" -f -o type=ext4,lock="$WORK/lock-link" "$IMG/ext4.img" "$MNT" > "$WORK/lklfuse-lock.log" 2>&1; rc=$?
  fusermount3 -u "$MNT" 2>/dev/null
  cat "$WORK/lklfuse-lock.log"; [ $rc -eq 1 ] && grep -q "failed to open" "$WORK/lklfuse-lock.log"
}
step "a lock= path that is a symlink is refused, not followed" lock_symlink
[ -z "$pid" ] || { fusermount3 -u "$MNT" 2>/dev/null; kill "$pid" 2>/dev/null; }
[ "$bad" -ne 0 ] || rm -rf "$IMG" "$WORK/payload" "$WORK/ops.img"   # on failure, keep the images as evidence
echo "1..$n"
exit $bad
