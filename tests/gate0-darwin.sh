#!/bin/sh
# platform: host-agnostic -- each half checks its own host and skips (77) on the other
#   usage: gate0-darwin.sh round | mkimages | write | fsck-killed | replay | fsck | verify
#          Gate 0a's two-host round. `round`, on the 10.9 box, runs the whole thing, sending
#          the Linux halves through build/linux-host.sh. In order: `mkimages` (Linux); `write`
#          (10.9: writes, large offsets, kill -9 mid-write on ext4, xfs and ntfs-killed); `fsck-killed`
#          (on copies: e2fsck replays the killed ext4 journal, ntfsfix repairs the NTFS volume);
#          `replay` (10.9: LKL replays both journals; ntfs3 refuses the dirty NTFS volume
#          read-write, and it verifies read-only); `fsck` (Linux); `verify` (10.9). The round's state
#          is the images directory, $GATE0_IMAGES, which both hosts see. GATE0_DEVICE=disk or
#          rdisk makes each Mac phase attach the images as real disks (hdiutil, no mount) and work
#          on /dev/diskN or /dev/rdiskN, detaching them again before the phase ends.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C=$HOME/Library/Caches/mm-build/linuxfs-gate0
IMG=${GATE0_IMAGES:-$C/images}
OUT=${GATE0_DARWIN_OUT:-$C/darwin}
RW=$OUT/gate0-rw
PHASE=${1:-none}
n=0 bad=0
step() {
  n=$((n + 1)); what=$1; shift
  if "$@" > "$IMG/$PHASE-$n.log" 2>&1; then echo "ok $n - $what"
  else echo "not ok $n - $what (see $IMG/$PHASE-$n.log)"; bad=1; fi
}
DEV=${GATE0_DEVICE:-file}
case $DEV in file|disk|rdisk) ;; *)
  echo "gate0-darwin.sh: GATE0_DEVICE must be file, disk or rdisk, not '$DEV'" >&2; exit 2 ;; esac
attach_all() {
  : > "$IMG/devices"
  [ "$DEV" = file ] && return 0
  trap 'detach_all || exit 1' EXIT
  for name in ext4 btrfs xfs ntfs ntfs-killed ext4-8g; do
    # platform: guarded macOS-only call -- attach_all runs only in the Mac phases, which on() keeps to Darwin
    d=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG/$name.img" | awk '/^\/dev\/disk/ { print $1; exit }')
    [ -n "$d" ] || { echo "gate0-darwin.sh: cannot attach $name.img" >&2; exit 1; }
    [ "$DEV" = rdisk ] && d=/dev/r${d#/dev/}
    echo "$name $d" >> "$IMG/devices"
  done
}
detach_all() {
  : > "$IMG/devices.left"
  while read -r name d; do
    whole=$(echo "$d" | sed 's|^/dev/rdisk|/dev/disk|')
    # platform: guarded macOS-only call -- detach_all runs only in the Mac phases, which on() keeps to Darwin
    hdiutil detach "$whole" >/dev/null 2>&1 || hdiutil detach -force "$whole" >/dev/null \
      || { echo "gate0-darwin.sh: cannot detach $whole ($name.img)" >&2; echo "$name $d" >> "$IMG/devices.left"; }
  done < "$IMG/devices"
  mv "$IMG/devices.left" "$IMG/devices"
  [ ! -s "$IMG/devices" ]
}
node() {
  if [ "$DEV" = file ]; then echo "$IMG/$1.img"; else awk -v n="$1" '$1 == n { print $2 }' "$IMG/devices"; fi
}
fstype() { case $1 in ntfs) echo ntfs3 ;; *) echo "$1" ;; esac; }
on() {
  case "$1:$(uname -s)" in linux:Linux|mac:Darwin) ;; *)
    echo "gate0-darwin.sh: '$2' runs on the $1 host" >&2; exit 77 ;; esac
}
killed() {
  log=$IMG/churn-$2.log
  "$RW" -d "$1" -t "$2" -p killed-mid-write > "$log" 2>&1 & p=$!
  sleep "${GATE0_KILL_AFTER:-3}"; kill -9 "$p"; wait "$p"; rc=$?
  [ $rc -eq 137 ] && grep -q "^# churn [1-9]" "$log"
}
case "${1:-}" in
mkimages)
  on linux mkimages
  sh "$ROOT/tests/lib/mkimages.sh" "$IMG" ;;
fsck)
  on linux fsck
  sh "$ROOT/tests/lib/fsck-images.sh" "$IMG" ;;
fsck-killed)
  on linux fsck-killed
  sh "$ROOT/tests/lib/fsck-killed.sh" "$IMG/ext4.img" ext4 &&
  sh "$ROOT/tests/lib/fsck-killed.sh" "$IMG/ntfs-killed.img" ntfs ;;
replay)
  on mac replay
  attach_all
  for fs in ext4 xfs; do
    step "10.9: mount $fs read-write after kill (replays the journal)" "$RW" -d "$(node $fs)" -t "$fs" -p replay
  done
  step "10.9: ntfs3 refuses to mount the killed NTFS volume read-write" "$RW" -d "$(node ntfs-killed)" -t ntfs3 -p dirty-refused
  step "10.9: data written before the kill reads back (read-only)" "$RW" -d "$(node ntfs-killed)" -t ntfs3 -p verify
  echo "1..$n"; exit $bad ;;
write)
  on mac write
  attach_all
  for fs in ext4 btrfs xfs ntfs; do
    step "10.9: write $fs" "$RW" -d "$(node $fs)" -t "$(fstype $fs)" -p write
  done
  step "10.9: write 1 MiB at 7.9 GiB" "$RW" -d "$(node ext4-8g)" -t ext4 -p large-offset
  step "10.9: raw device write and read back past 4 GiB" "$RW" -d "$IMG/raw.img" -t none -p raw-large
  for fs in ext4 xfs; do
    step "10.9: kill -9 mid-write $fs" killed "$(node $fs)" "$fs"
  done
  step "10.9: write ntfs-killed" "$RW" -d "$(node ntfs-killed)" -t ntfs3 -p write
  step "10.9: kill -9 mid-write ntfs" killed "$(node ntfs-killed)" ntfs3
  echo "1..$n"; exit $bad ;;
verify)
  on mac verify
  attach_all
  for fs in ext4 btrfs xfs ntfs; do
    step "10.9: verify $fs" "$RW" -d "$(node $fs)" -t "$(fstype $fs)" -p verify
    step "10.9: upstream disk test $fs" "$OUT/tests/disk" -d "$(node $fs)" -t "$(fstype $fs)"
  done
  step "10.9: verify the 7.9 GiB write" "$RW" -d "$(node ext4-8g)" -t ext4 -p verify-large
  echo "1..$n"; exit $bad ;;
round)
  on mac round
  mkdir -p "$IMG"
  rm -f "$IMG"/*.log
  step "Linux: make images" sh "$ROOT/build/linux-host.sh" sh "$ROOT/tests/gate0-darwin.sh" mkimages
  [ "$bad" -eq 0 ] || { echo "1..$n"; exit 1; }
  step "10.9: write round" sh "$ROOT/tests/gate0-darwin.sh" write
  step "Linux: checkers repair the killed ext4 and NTFS volumes" sh "$ROOT/build/linux-host.sh" sh "$ROOT/tests/gate0-darwin.sh" fsck-killed
  step "10.9: replay round" sh "$ROOT/tests/gate0-darwin.sh" replay
  step "Linux: fsck after 10.9 writes" sh "$ROOT/build/linux-host.sh" sh "$ROOT/tests/gate0-darwin.sh" fsck
  step "10.9: verify round" sh "$ROOT/tests/gate0-darwin.sh" verify
  echo "1..$n"; exit $bad ;;
*)
  echo "usage: gate0-darwin.sh round | mkimages | write | fsck-killed | replay | fsck | verify" >&2; exit 2 ;;
esac
