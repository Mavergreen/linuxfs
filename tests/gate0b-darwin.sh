#!/bin/sh
# platform: macOS-only -- mounts through Mavergreen macFUSE on 10.9; the Linux halves go through build/linux-host.sh
#   usage: gate0b-darwin.sh
#          Gate 0b on 10.9: the Darwin lklfuse mounts ext4, btrfs, xfs and NTFS images made by Linux,
#          and ordinary macOS tools write through the mount. After `umount` (or `diskutil unmount`
#          on the second pass), lklfuse must exit 0, Linux's checker must find the image clean, and
#          a second mount must read everything back. Then: kill -9 mid-write must replay on ext4
#          and be refused, with the reason, on NTFS. GATE0_DEVICE=rdisk mounts /dev/rdiskN
#          (hdiutil, no mount) instead of the file. Exits 77 without Mavergreen macFUSE.
#          GATE0B_BUNDLE=DIR runs from a bundle made by build/gate0b-bundle.sh, on a 10.9 host with
#          no Linux beside it: images come gzipped from DIR/images, and each Linux check is instead
#          a gzipped snapshot of the image in DIR/run-MODE/snapshots, named for what it must show,
#          for tests/gate0b-check-bundle.sh to check later.
set -u
case "$(uname -s)" in Darwin) ;; *) echo "gate0b-darwin.sh: runs on the 10.9 box" >&2; exit 77 ;; esac
# platform: upstream macFUSE 4.x (libfuse 2 only) may be installed too; lklfuse needs Mavergreen macFUSE's libfuse 3
if [ ! -d /usr/local/mavergreen/macfuse ] || [ ! -e /usr/local/lib/libfuse3.4.dylib ]; then
  echo "gate0b-darwin.sh: Mavergreen macFUSE (libfuse 3) is not installed" >&2; exit 77
fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C=$HOME/Library/Caches/mm-build/linuxfs-gate0
B=${GATE0B_BUNDLE:-}
if [ -n "$B" ]; then
  OUT=$B/bin WORK=$B/run-${GATE0_DEVICE:-file}
else
  OUT=${GATE0_DARWIN_OUT:-$C/darwin} WORK=$C/gate0b
fi
IMG=$WORK/images MNT=$WORK/mnt
LKLFUSE=${LKLFUSE:-$OUT/lklfuse}
DEV=${GATE0_DEVICE:-file}
case $DEV in file|rdisk) ;; *) echo "gate0b-darwin.sh: GATE0_DEVICE must be file or rdisk" >&2; exit 2 ;; esac
n=0 bad=0 pid= disk=
step() {
  n=$((n + 1)); what=$1; shift
  if "$@" > "$WORK/step-$n.log" 2>&1; then echo "ok $n - $what"
  else echo "not ok $n - $what (see $WORK/step-$n.log)"; bad=1; fi
}
linux() { sh "$ROOT/build/linux-host.sh" "$@"; }
fstype() { case $1 in ntfs) echo ntfs3 ;; *) echo "$1" ;; esac; }
snapshot() { detach || return 1; mkdir -p "$WORK/snapshots" && gzip -c "$IMG/$1.img" > "$WORK/snapshots/$n-$1-$2.img.gz"; }
checker() {
  if [ -n "$B" ]; then snapshot "$1" clean; return; fi
  detach || return 1; linux sh "$ROOT/tests/lib/check-fs.sh" "$1" "$IMG/$1.img"
}
# platform: target sets $t and $disk in this shell; a $(...) subshell would forget $disk before detach
target() {
  if [ "$DEV" = file ]; then t=$IMG/$1.img; return 0; fi
  [ -n "$disk" ] || disk=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG/$1.img" | awk '/^\/dev\/disk/ { print $1; exit }')
  [ -n "$disk" ] || return 1
  t=/dev/r${disk#/dev/}
}
detach() {
  [ -n "$disk" ] || return 0
  hdiutil detach "$disk" >/dev/null || hdiutil detach -force "$disk" >/dev/null || { echo "cannot detach $disk"; return 1; }
  disk=
}
# platform: a disk detached under a running lklfuse leaves its mount dead, so lklfuse stops first
trap '[ -z "$pid" ] || { umount -f "$MNT"; kill "$pid"; wait "$pid"; } 2>/dev/null; detach' EXIT
mounted() { mount | grep -q " on $MNT " || { echo "nothing mounted on $MNT"; return 1; }; }
# platform: the mount shows up as soon as FUSE's does, and a listing is answered only once lklfuse's loop runs,
#           after LKL's mount; a failed LKL mount ends lklfuse, so the listing fails
mount_fs() {
  ! mount | grep -q " on $MNT " || { echo "something is already mounted on $MNT"; return 1; }
  target "$1" || return 1
  "$LKLFUSE" -f -o "type=$(fstype "$1"),volname=gate0b-$1" "$t" "$MNT" > "$WORK/lklfuse-$1.log" 2>&1 &
  pid=$! i=0
  until mount | grep -q " on $MNT "; do
    i=$((i + 1)); [ $i -le 100 ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
  done
  ls "$MNT" > /dev/null && kill -0 "$pid"
}
# platform: Spotlight's mdworker, Time Machine's TMHelperAgent and the like open every new volume
holders() { echo "# holders of $MNT:"; lsof -n 2>/dev/null | grep -F " $MNT" || echo "# (none visible to this user)"; }
unmount_fs() {
  holders
  i=0
  until "$@" "$MNT"; do
    i=$((i + 1)); [ $i -le 10 ] || return 1
    echo "# busy; retry $i in 1 s"; holders; sleep 1
  done
  [ $i -eq 0 ] || echo "# unmounted after $i retries"
  wait "$pid"; rc=$?; pid=
  [ $rc -eq 0 ] || { echo "lklfuse exited $rc"; return 1; }
}
MTIME=1577934240   # 2020-01-02 03:04 UTC
write_through() {
  mounted &&
  cp "$WORK/payload" "$MNT/big" &&
  mkdir "$MNT/d" &&
  i=1 && while [ $i -le 200 ]; do echo $i > "$MNT/d/f$i" || return 1; i=$((i + 1)); done &&
  mv "$MNT/d/f1" "$MNT/d/moved" &&
  xattr -w user.k v "$MNT/big" &&
  TZ=UTC touch -t 202001020304 "$MNT/big"
}
read_back() {
  mounted &&
  cmp "$WORK/payload" "$MNT/big" &&
  [ "$(cat "$MNT/d/f200")" = 200 ] &&
  [ "$(cat "$MNT/d/moved")" = 1 ] && [ ! -e "$MNT/d/f1" ] &&
  [ "$(xattr -p user.k "$MNT/big")" = v ] &&
  [ "$(stat -f %m "$MNT/big")" = "$MTIME" ]
}
killed() {
  mount_fs "$1" || return 1
  echo 0 > "$WORK/writes"
  ( i=0; while cp "$WORK/payload" "$MNT/k$i" 2>/dev/null; do i=$((i + 1)); echo $i > "$WORK/writes"; done ) &
  w=$!
  sleep 3; kill -9 "$pid"; wait "$pid"; rc=$?; pid=
  wait "$w"
  umount -f "$MNT" 2>/dev/null || diskutil unmount force "$MNT"
  echo "lklfuse exit $rc after $(cat "$WORK/writes") copies"
  [ $rc -eq 137 ] && [ "$(cat "$WORK/writes")" -ge 1 ]
}
needs_replay() {
  if [ -n "$B" ]; then snapshot ext4 needs-replay; return; fi
  detach || return 1; linux sh -c 'dumpe2fs -h "$1" 2>/dev/null | grep -q needs_recovery' _ "$IMG/ext4.img"
}
unpack() { rm -rf "$IMG" "$WORK/snapshots" && mkdir -p "$IMG" && for z in "$B"/images/*.img.gz; do gunzip -c "$z" > "$IMG/$(basename "$z" .gz)" || return 1; done; }
dirty_refused() {
  target ntfs || return 1
  "$LKLFUSE" -f -o type=ntfs3 "$t" "$MNT" > "$WORK/lklfuse-dirty.log" 2>&1 &
  p=$! i=0
  while kill -0 "$p" 2>/dev/null; do
    i=$((i + 1)); [ $i -le 100 ] || { umount "$MNT"; wait "$p"; echo "lklfuse mounted the dirty volume"; return 1; }
    sleep 0.1
  done
  wait "$p"; rc=$?
  cat "$WORK/lklfuse-dirty.log"
  [ $rc -ne 0 ] && grep -q 'volume is dirty' "$WORK/lklfuse-dirty.log" && ! mount | grep -q " on $MNT "
}
mkdir -p "$WORK" "$MNT"
[ -x "$LKLFUSE" ] || { echo "gate0b-darwin.sh: no $LKLFUSE (run build/build-lkl-darwin.sh)" >&2; exit 1; }
head -c 4194304 /dev/urandom > "$WORK/payload"
if [ -n "$B" ]; then
  step "unpack the images Linux made" unpack
  step "lklfuse callbacks report Darwin errno values and flags" sh -c '"$1" "$2" > "$3" 2>&1; r=$?; cat "$3"; exit $r' _ "$OUT/lklfuse-ops" "$IMG/ops.img" "$WORK/ops.log"
else
  step "Linux: make images" linux sh "$ROOT/tests/lib/mkimages.sh" --small "$IMG"
  step "lklfuse callbacks report Darwin errno values and flags" sh "$ROOT/tests/lklfuse-ops-darwin.sh"
fi
for fs in ext4 btrfs xfs ntfs; do
  step "lklfuse mounts $fs" mount_fs "$fs"
  step "write through the $fs mount" write_through
  step "umount $fs; lklfuse exits 0" unmount_fs umount
  step "Linux: $fs is clean after unmount" checker "$fs"
  step "lklfuse mounts $fs again" mount_fs "$fs"
  step "everything reads back on $fs" read_back
  step "diskutil unmount $fs; lklfuse exits 0" unmount_fs diskutil unmount
  step "Linux: $fs is still clean" checker "$fs"
done
step "kill -9 lklfuse mid-write on ext4" killed ext4
step "Linux: ext4's journal needs replaying" needs_replay
step "lklfuse mounts ext4 after the kill (replays the journal)" mount_fs ext4
step "what was written before still reads back" read_back
step "umount ext4" unmount_fs umount
step "Linux: ext4 is clean after the replay" checker ext4
step "kill -9 lklfuse mid-write on ntfs" killed ntfs
step "lklfuse refuses the dirty NTFS volume, and says why" dirty_refused
detach || { echo "# a disk would not detach"; bad=1; }
[ "$bad" -ne 0 ] || rm -rf "$IMG" "$WORK/payload"   # on failure, keep the images as evidence (snapshots stay either way)
echo "1..$n"
exit $bad
