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
  cc -O2 -Wall -Werror -o "$D/probe" "$ROOT/tools/probe.c" "$ROOT/tools/fsrules.c" || exit 1
  cc -O2 -Wall -Werror -DLINUXFS_PROBE_NO_MAIN -o "$D/probe-uuid" "$ROOT/tests/probe-uuid.c" "$ROOT/tools/probe.c" || exit 1
else
  . "$ROOT/build/msc.sh"
  D=$HOME/Library/Caches/mm-build/linuxfs-probe-test; rm -rf "$D"; mkdir -p "$D"
  CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
  SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
  "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld \
    -o "$D/probe" "$ROOT/tools/probe.c" "$ROOT/tools/fsrules.c" || exit 1
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
# spec: tools/probe.c -- the fourth field: a dirty NTFS volume, an encrypted APFS volume (macOS made it: volume 0 encrypted)
want ntfs-dirty.img "ntfs3${T}Windows${T}${T}dirty" 0
gunzip -c "$ROOT/tests/fixtures/apfs/enc.img.gz" > "$D/enc.img"
n=$((n + 1)); got=$("$D/probe" "$D/enc.img"); rc=$?
case $got in "apfs${T}"*"${T}${T}encrypted") [ $rc -eq 0 ] ;; *) false ;; esac
if [ $? -eq 0 ]; then echo "ok $n - enc.img: an encrypted APFS volume says so ($got)"; else echo "not ok $n - enc.img: got '$got' ($rc)"; bad=1; fi
want short.img unknown 1
want ext4-cut.img unknown 1
want zero.img unknown 1
want hfs-magic.img unknown 1
want apfs-magic.img "apfs${T}" 0
want ext-bogus.img unknown 1
n=$((n + 1)); "$D/probe" "$D/missing" > /dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then echo "ok $n - an unreadable path exits 2"; else echo "not ok $n - missing file exit $rc, want 2"; bad=1; fi
# spec: tools/probe.c linuxfs_probe_uuid -- filesystem UUIDs (-k): equal to blkid's, case-insensitively; none for ntfs, vfat, exfat
#       (item 6: f2fs reports its own, as every other filesystem a bundle claims does, so DiskArbitration knows it by one)
uuid() { # IMAGE: the expected UUID, from blkid on Linux
  if [ "$(uname -s)" = Linux ]; then blkid -s UUID -o value "$D/$1"; else sh "$ROOT/build/linux-host.sh" blkid -s UUID -o value "$D/$1"; fi
}
for i in ext4 btrfs xfs apfs f2fs; do
  n=$((n + 1)); want_u=$(uuid $i.img | tr a-f A-F); got=$("$D/probe-uuid" "$D/$i.img"); rc=$?
  if [ -n "$want_u" ] && [ "$got" = "$want_u" ] && [ $rc -eq 0 ]; then echo "ok $n - $i.img: UUID $got"
  else echo "not ok $n - $i.img: UUID got '$got' ($rc), want '$want_u'"; bad=1; fi
  # spec: tools/probe.c main -- linuxfs-probe --uuid PATH prints the same (the CLI's linuxfs ignore writes it as UUID=)
  n=$((n + 1)); got=$("$D/probe" --uuid "$D/$i.img"); rc=$?
  if [ "$got" = "$want_u" ] && [ $rc -eq 0 ]; then echo "ok $n - linuxfs-probe --uuid $i.img: $got"
  else echo "not ok $n - linuxfs-probe --uuid $i.img: got '$got' ($rc), want '$want_u'"; bad=1; fi
done
for i in ntfs zero; do
  n=$((n + 1)); got=$("$D/probe" --uuid "$D/$i.img" 2>/dev/null); rc=$?
  if [ -z "$got" ] && [ $rc -eq 1 ]; then echo "ok $n - linuxfs-probe --uuid $i.img: none, exit 1"
  else echo "not ok $n - linuxfs-probe --uuid $i.img: got '$got' ($rc), want none (1)"; bad=1; fi
done
n=$((n + 1)); "$D/probe" --uuid "$D/missing" > /dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then echo "ok $n - linuxfs-probe --uuid of an unreadable path exits 2"; else echo "not ok $n - --uuid missing exit $rc, want 2"; bad=1; fi
for i in ntfs vfat exfat fat32; do
  n=$((n + 1)); got=$("$D/probe-uuid" "$D/$i.img"); rc=$?
  if [ -z "$got" ] && [ $rc -eq 1 ]; then echo "ok $n - $i.img: no UUID"
  else echo "not ok $n - $i.img: UUID got '$got' ($rc), want none (1)"; bad=1; fi
done
# spec: tools/probe.c linuxfs_probe_uuid -- a zeroed UUID is none (as blkid); the Fusion main device has the container's, its tier2 none; edge cases in one process
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
# spec: tools/fsrules.h fsrules_access -- linuxfs-probe --access TYPE FUSION FLAGS [WORD...]: the CLI's way to the same rule
acc() { # WANT ARGS...
  n=$((n + 1)); w=$1; shift; got=$("$D/probe" --access "$@" 2>/dev/null); rc=$?
  if [ "$got" = "$w" ] && [ $rc -eq 0 ]; then echo "ok $n - --access $*: $w"
  else echo "not ok $n - --access $*: got '$got' ($rc), want '$w'"; bad=1; fi
}
acc rw ext4 "" ""
acc "ro asked" ext4 "" "" ro
acc "ro ReadOnly" ext4 "" "" readonly
acc "ro apfs" apfs "" ""
acc rw apfs "" "" apfs-write
acc "ro fusion" apfs "fusion-main 0011" "" apfs-write
acc "ro encrypted" apfs "" "encrypted" apfs-write
acc "refuse encrypted" apfs "" "encrypted" before-login
acc "ro dirty" ntfs3 "" "dirty"
n=$((n + 1)); "$D/probe" --access ext4 "" "" bogus > /dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then echo "ok $n - --access with an unknown word is misuse (2)"; else echo "not ok $n - --access bogus: exit $rc, want 2"; bad=1; fi
n=$((n + 1)); "$D/probe" --access ext4 "" > /dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then echo "ok $n - --access without FLAGS is misuse (2)"; else echo "not ok $n - --access short: exit $rc, want 2"; bad=1; fi
# spec: tools/probe.c main -- linuxfs-probe --groups: the process's own groups (the kernel's getgroups), decimal, on one line; the CLI's
#       share_opt reads them, never id -G, which asks the directory (push-d-debug.md)
n=$((n + 1)); got=$("$D/probe" --groups 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" = 1 ] && printf '%s\n' "$got" | grep -qE '^[0-9]+( [0-9]+)*$' &&
   case " $got " in *" $(id -g) "*) true ;; *) false ;; esac; then echo "ok $n - groups_format: --groups prints one line of decimal ids, with $(id -g) ($got)"
else echo "not ok $n - groups_format: --groups got '$got' ($rc), want one line of decimal ids holding $(id -g)"; bad=1; fi
if [ "$(uname -s)" = Darwin ]; then
  # spec: tools/probe.c -- the kernel's getgroups (_getgroups), never getgroups$DARWIN_EXTSN, which asks the directory as id -G does
  n=$((n + 1)); u=$("$CL/bin/llvm-nm" -u "$D/probe" 2>&1)
  if printf '%s\n' "$u" | grep -qx '_getgroups' && ! printf '%s\n' "$u" | grep -qF 'getgroups$DARWIN_EXTSN'; then echo "ok $n - groups_kernel: linuxfs-probe imports _getgroups, not _getgroups\$DARWIN_EXTSN"
  else echo "not ok $n - groups_kernel: nm -u: $(printf '%s\n' "$u" | grep getgroups | tr '\n' ' ')"; bad=1; fi
fi
echo "1..$n"; exit $bad
