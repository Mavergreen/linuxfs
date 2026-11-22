#!/bin/sh
# platform: host-agnostic
#   usage: gate0-linux.sh
#          Gate 0a's baseline on Linux: build LKL as ELF, then write, check, verify and survive a
#          kill on ext4, btrfs, xfs and NTFS images. Run on the Linux host (build/linux-host.sh).
set -u
[ "$(uname -s)" = Linux ] || { echo "gate0-linux.sh: Linux host only" >&2; exit 77; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${GATE0_WORK:-/work/gate0-linux}
OUT=$WORK/out IMG=$WORK/images
n=0 bad=0
step() {
  n=$((n + 1)); what=$1; shift
  if "$@" > "$WORK/step-$n.log" 2>&1; then echo "ok $n - $what"
  else echo "not ok $n - $what (see $WORK/step-$n.log)"; bad=1; fi
}
fstype() { case $1 in ntfs) echo ntfs3 ;; ext4-8g) echo ext4 ;; *) echo "$1" ;; esac; }
mkdir -p "$WORK"
step "ELF to Mach-O converter" sh "$ROOT/tests/elf2macho-test.sh"
step "build LKL for Linux" sh "$ROOT/build/build-lkl-linux.sh" "$OUT"
[ "$bad" -eq 0 ] || { echo "1..$n"; exit 1; }
step "make images" sh "$ROOT/tests/lib/mkimages.sh" "$IMG"
for fs in ext4 btrfs xfs ntfs; do
  step "write $fs" "$OUT/gate0-rw" -d "$IMG/$fs.img" -t "$(fstype $fs)" -p write
done
step "write at 7.9 GiB" "$OUT/gate0-rw" -d "$IMG/ext4-8g.img" -t ext4 -p large-offset
step "raw device write and read back past 4 GiB" "$OUT/gate0-rw" -d "$IMG/raw.img" -t none -p raw-large
step "fsck after writes" sh "$ROOT/tests/lib/fsck-images.sh" "$IMG"
for fs in ext4 btrfs xfs ntfs ext4-8g; do
  [ "$fs" = ext4-8g ] || step "verify $fs" "$OUT/gate0-rw" -d "$IMG/$fs.img" -t "$(fstype $fs)" -p verify
  step "upstream disk test $fs" "$OUT/tests/disk" -d "$IMG/$fs.img" -t "$(fstype $fs)"
done
step "verify 7.9 GiB write" "$OUT/gate0-rw" -d "$IMG/ext4-8g.img" -t ext4 -p verify-large
step "unmount with no time to wait leaves nothing behind" "$OUT/gate0-rw" -d "$IMG/ext4.img" -t ext4 -p umount-timeout
step "and the image is still clean" e2fsck -fn "$IMG/ext4.img"
for fs in ext4 xfs; do
  step "kill -9 mid-write $fs" sh -c '"$1" -d "$2" -t "$3" -p killed-mid-write > "$4" 2>&1 & p=$!; sleep 3; kill -9 $p; wait $p; [ $? -eq 137 ] && grep -q "^# churn [1-9]" "$4"' \
    _ "$OUT/gate0-rw" "$IMG/$fs.img" "$fs" "$WORK/churn-$fs.log"
  [ "$fs" = ext4 ] && step "Linux checker replays ext4's journal after kill" sh "$ROOT/tests/lib/fsck-killed.sh" "$IMG/ext4.img"
  step "mount $fs read-write after kill (replays the journal)" "$OUT/gate0-rw" -d "$IMG/$fs.img" -t "$fs" -p replay
done
step "write ntfs-killed" "$OUT/gate0-rw" -d "$IMG/ntfs-killed.img" -t ntfs3 -p write
step "kill -9 mid-write ntfs" sh -c '"$1" -d "$2" -t ntfs3 -p killed-mid-write > "$3" 2>&1 & p=$!; sleep 3; kill -9 $p; wait $p; [ $? -eq 137 ] && grep -q "^# churn [1-9]" "$3"' \
  _ "$OUT/gate0-rw" "$IMG/ntfs-killed.img" "$WORK/churn-ntfs.log"
step "ntfsfix repairs the killed NTFS volume (on a copy)" sh "$ROOT/tests/lib/fsck-killed.sh" "$IMG/ntfs-killed.img" ntfs
step "ntfs3 refuses to mount the dirty volume read-write" "$OUT/gate0-rw" -d "$IMG/ntfs-killed.img" -t ntfs3 -p dirty-refused
step "data written before the kill reads back (read-only)" "$OUT/gate0-rw" -d "$IMG/ntfs-killed.img" -t ntfs3 -p verify
step "fsck after kills" sh "$ROOT/tests/lib/fsck-images.sh" "$IMG"
for fs in ext4 xfs; do
  step "verify $fs after kill and fsck" "$OUT/gate0-rw" -d "$IMG/$fs.img" -t "$fs" -p verify
done
echo "1..$n"
exit $bad
