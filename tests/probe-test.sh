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
else
  . "$ROOT/build/msc.sh"
  D=$HOME/Library/Caches/mm-build/linuxfs-probe-test; rm -rf "$D"; mkdir -p "$D"
  CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
  SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
  "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld \
    -o "$D/probe" "$ROOT/tools/probe.c" || exit 1
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
echo "1..$n"; exit $bad
