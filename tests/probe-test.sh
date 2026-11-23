#!/bin/sh
# platform: host-agnostic
#   usage: probe-test.sh
#          tools/linuxfs-probe names the filesystem on images Linux made, prints its label, and says "unknown"
#          (exit 1) for anything else, including a file shorter than the superblock it looks for. On Linux it
#          runs the host build; on a Mac it makes the images through build/linux-host.sh and runs the Mac build
#          (clang22, 10.9 SDK), so both builds are tested.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(uname -s)" = Linux ]; then
  D=${PROBE_TEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/probe-test.XXXXXX")}
  cc -O2 -Wall -Werror -o "$D/probe" "$ROOT/tools/probe.c" || exit 1
  cc -O2 -Wall -Werror -DLINUXFS_PROBE_NO_MAIN -o "$D/probe-uuid" "$ROOT/tests/probe-uuid.c" "$ROOT/tools/probe.c" || exit 1
else
  . "$ROOT/build/msc.sh"
  D=$HOME/Library/Caches/mm-build/linuxfs-probe-test; rm -rf "$D"; mkdir -p "$D"
  CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
  SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
  "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld \
    -o "$D/probe" "$ROOT/tools/probe.c" || exit 1
  "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld -DLINUXFS_PROBE_NO_MAIN \
    -o "$D/probe-uuid" "$ROOT/tests/probe-uuid.c" "$ROOT/tools/probe.c" || exit 1
fi
if [ "$(uname -s)" = Linux ]; then sh "$ROOT/tests/lib/probe-images.sh" "$D" || exit 1
else sh "$ROOT/build/linux-host.sh" sh "$ROOT/tests/lib/probe-images.sh" "$D" || exit 1; fi
n=0 bad=0
want() { # IMAGE OUT RC
  n=$((n + 1)); got=$("$D/probe" "$D/$1" 2>&1); rc=$?
  if [ "$got" = "$2" ] && [ $rc -eq "$3" ]; then echo "ok $n - $1: $2"
  else echo "not ok $n - $1: got '$got' ($rc), want '$2' ($3)"; bad=1; fi
}
T=$(printf '\t')
want ext4.img "ext4${T}my data" 0
want btrfs.img "btrfs${T}backup" 0
want xfs.img "xfs${T}scratch" 0
want ntfs.img "ntfs3${T}Windows" 0
want ntfs-utf.img "ntfs3${T}Données 😀" 0
want ext4-badlabel.img "ext4${T}ok?x" 0
want exfat.img "exfat${T}CARD" 0
want vfat.img "vfat${T}STICK" 0
want fat32.img "vfat${T}BIG32" 0
want f2fs.img "f2fs${T}flash" 0
want apfs.img "apfs${T}Time Machine" 0
n=$((n + 1)); m=$("$D/probe" "$D/fusion-ssd.img"); t=$("$D/probe" "$D/fusion-hdd.img")
u=$(printf '%s\n' "$m" | sed -n "s/^apfs${T}Fused${T}fusion-main \([0-9a-f]\{32\}\)\$/\1/p")
if [ -n "$u" ] && [ "$t" = "apfs${T}${T}fusion-tier2 $u" ]; then echo "ok $n - a Fusion container's two devices name their roles and the same container"
else echo "not ok $n - Fusion: main '$m', second '$t'"; bad=1; fi
want short.img unknown 1
want ext4-cut.img unknown 1
want zero.img unknown 1
want hfs-magic.img unknown 1
want apfs-magic.img "apfs${T}" 0
want ext-bogus.img unknown 1
n=$((n + 1)); "$D/probe" "$D/missing" > /dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then echo "ok $n - an unreadable path exits 2"; else echo "not ok $n - missing file exit $rc, want 2"; bad=1; fi
# filesystem UUIDs (-k): equal to blkid's, case-insensitively; none for ntfs, f2fs, vfat, exfat
uuid() { # IMAGE: the expected UUID, from blkid on Linux
  if [ "$(uname -s)" = Linux ]; then blkid -s UUID -o value "$D/$1"; else sh "$ROOT/build/linux-host.sh" blkid -s UUID -o value "$D/$1"; fi
}
for i in ext4 btrfs xfs apfs; do
  n=$((n + 1)); want_u=$(uuid $i.img | tr a-f A-F); got=$("$D/probe-uuid" "$D/$i.img"); rc=$?
  if [ -n "$want_u" ] && [ "$got" = "$want_u" ] && [ $rc -eq 0 ]; then echo "ok $n - $i.img: UUID $got"
  else echo "not ok $n - $i.img: UUID got '$got' ($rc), want '$want_u'"; bad=1; fi
done
for i in ntfs f2fs vfat exfat fat32; do
  n=$((n + 1)); got=$("$D/probe-uuid" "$D/$i.img"); rc=$?
  if [ -z "$got" ] && [ $rc -eq 1 ]; then echo "ok $n - $i.img: no UUID"
  else echo "not ok $n - $i.img: UUID got '$got' ($rc), want none (1)"; bad=1; fi
done
# a zeroed UUID is none (as blkid); the Fusion main device has the container's, its tier2 none; edge cases in one process
cp "$D/ext4.img" "$D/ext4-nouuid.img"; dd if=/dev/zero of="$D/ext4-nouuid.img" bs=1 seek=$((1024 + 0x68)) count=16 conv=notrunc 2>/dev/null
head -c 2048 "$D/btrfs.img" > "$D/btrfs-cut.img"
none() { # NAME WHY ARGS...: the driver prints nothing and exits 1
  n=$((n + 1)); w=$1; shift; got=$("$D/probe-uuid" "$@"); rc=$?
  if [ -z "$got" ] && [ $rc -eq 1 ]; then echo "ok $n - $w"; else echo "not ok $n - $w: got '$got' ($rc), want none (1)"; bad=1; fi
}
none "ext4-nouuid.img: an all-zero UUID is none" "$D/ext4-nouuid.img"
none "btrfs-cut.img: a truncated btrfs image is not recognised, so no UUID" "$D/btrfs-cut.img"
none "a 36-byte buffer is too small" --small "$D/ext4.img"
none "no stale UUID after a failed probe (unknown)" --stale "$D/ext4.img" "$D/zero.img"
none "no stale UUID after a failed probe (short)" --stale "$D/ext4.img" "$D/short.img"
none "Fusion tier2 device: no UUID" "$D/fusion-hdd.img"
n=$((n + 1)); want_u=$(uuid fusion-ssd.img | tr a-f A-F); got=$("$D/probe-uuid" "$D/fusion-ssd.img"); rc=$?
if [ -n "$want_u" ] && [ "$got" = "$want_u" ] && [ $rc -eq 0 ]; then echo "ok $n - Fusion main device: the container's UUID $got"
else echo "not ok $n - Fusion main: got '$got' ($rc), want '$want_u'"; bad=1; fi
echo "1..$n"; exit $bad
