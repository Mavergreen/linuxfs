#!/bin/sh
# platform: macOS-only -- hdiutil, CoreFoundation
#   usage: fs-test.sh
#          Builds tools/fs.c (linuxfs-fs) for 10.9 and copies it under the names the bundles use. Ext4, btrfs and NTFS
#          images made by build/linux-host.sh are attached with hdiutil -nomount (nothing is mounted or installed; the
#          user owns the device nodes, so the util runs unprivileged, with the prefs plists named by LINUXFS_PREFS_USER
#          and LINUXFS_PREFS_MACHINE). Tests the util's probe (-p) and UUID (-k) and fsck's quick check (-q).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
D=$HOME/Library/Caches/mm-build/linuxfs-fs-test; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld -DLINUXFS_PROBE_NO_MAIN \
  -o "$D/linuxfs-fs" "$ROOT/tools/fs.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/probe.c" \
  -framework CoreFoundation -framework DiskArbitration || exit 1
for n in linuxfs_ext4.util linuxfs_ntfs.util linuxfs_btrfs.util fsck_linuxfs_ext4 mount_linuxfs_ext4 bogus.util; do cp "$D/linuxfs-fs" "$D/$n"; done
sh "$ROOT/build/linux-host.sh" sh -c "cd '$D' && sh '$ROOT/tests/lib/probe-images.sh' '$D' && blkid -s UUID -o value ext4.img > ext4.uuid && blkid -s UUID -o value btrfs.img > btrfs.uuid" || exit 1
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
att() { hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/$1" | awk 'NR == 1 { print $1 }'; }
devs=
trap 'for d in $devs; do hdiutil detach -quiet -force "$d" 2>/dev/null; done' EXIT
e=$(att ext4.img); b=$(att btrfs.img); t=$(att ntfs.img); devs="$e $b $t"
echo "# attached $e $b $t"
E=${e#/dev/}; B=${b#/dev/}; T=${t#/dev/}
# prefs: user plist and machine plist, as the CLI writes them
plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$2" > "$1"; }
plist "$D/empty.plist" ""
plist "$D/take.plist" "<key>NTFSTakeover</key><true/>"
plist "$D/takestr.plist" "<key>NTFSTakeover</key><string>YES</string>"
plist "$D/takeoff.plist" "<key>NTFSTakeover</key><true/><key>Automount</key><false/>"
printf 'this is not a plist' > "$D/corrupt.plist"
u() { # BIN ARGS... : the util with the test prefs (USERP, MACHP)
  x=$1; shift; LINUXFS_PREFS_USER=${USERP:-$D/none.plist} LINUXFS_PREFS_MACHINE=${MACHP:-$D/none2.plist} "$D/$x" "$@"; }
out=$(u linuxfs_ext4.util -p "$E" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = "my data" ]; ok $? "ext4 util -p on the ext4 disk prints the label and exits 255 (rc $rc, '$out')"
out=$(u linuxfs_ext4.util -p "$E" fixed readonly); rc=$?
[ $rc = 255 ] && [ "$out" = "my data" ]; ok $? "ext4 is claimed fixed and readonly too (rc $rc)"
out=$(u linuxfs_btrfs.util -p "$E" removable writable); rc=$?
[ $rc = 254 ] && [ -z "$out" ]; ok $? "btrfs util on the ext4 disk exits 254 and prints nothing (rc $rc)"
out=$(u linuxfs_btrfs.util -p "$B" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = backup ]; ok $? "btrfs util on the btrfs disk exits 255 (rc $rc, '$out')"
out=$(u linuxfs_ext4.util -k "$E"); rc=$?
want=$(tr a-f A-F < "$D/ext4.uuid")
[ $rc = 255 ] && [ "$out" = "$want" ]; ok $? "-k prints the UUID blkid gave (rc $rc, '$out', want '$want')"
out=$(u linuxfs_btrfs.util -k "$B"); rc=$?
[ $rc = 255 ] && [ "$out" = "$(tr a-f A-F < "$D/btrfs.uuid")" ]; ok $? "-k on btrfs prints its UUID too"
out=$(u linuxfs_btrfs.util -k "$E"); rc=$?
[ $rc = 254 ] && [ -z "$out" ]; ok $? "-k for another filesystem's disk exits 254"
out=$(u linuxfs_ntfs.util -k "$T"); rc=$?
[ $rc = 254 ]; ok $? "-k on NTFS (no UUID) exits 254 (rc $rc)"
u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFS util with no prefs exits 254 (rc $rc)"
USERP=$D/empty.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFS util with a plist lacking NTFSTakeover exits 254 (rc $rc)"
out=$(USERP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = Windows ]; ok $? "NTFSTakeover=true: NTFS removable exits 255, prints the label (rc $rc, '$out')"
USERP=$D/takestr.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "NTFSTakeover as the string YES counts (rc $rc)"
USERP=$D/take.plist u linuxfs_ntfs.util -p "$T" fixed writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFSTakeover=true but fixed: exits 254 (rc $rc)"
USERP=$D/takeoff.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFSTakeover=true with Automount=false: exits 254 (rc $rc)"
USERP=$D/corrupt.plist MACHP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "a corrupt user plist counts as absent: the machine's NTFSTakeover=true holds (rc $rc)"
USERP=$D/empty.plist MACHP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "prefs fall back key by key: a user plist lacking the key leaves the machine's NTFSTakeover=true (rc $rc)"
USERP=$D/takeoff.plist MACHP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "and the user's Automount=false beats the machine's (rc $rc)"
USERP=$D/missing.plist MACHP=$D/missing2.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "missing plists use the defaults: ext4 still claimed (rc $rc)"
ln -sf "$D/take.plist" "$D/link.plist"
USERP=$D/link.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "a symlinked user plist is refused, as absent (rc $rc)"
plist "$D/ign.plist" "<key>Ignore:my data</key><true/>"
USERP=$D/ign.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "Ignore:<LABEL> true makes the util decline that disk (rc $rc)"
plist "$D/unign.plist" "<key>Ignore:my data</key><false/>"
USERP=$D/unign.plist MACHP=$D/ign.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "a user Ignore false overrides a machine Ignore true (rc $rc)"
USERP=$D/empty.plist MACHP=$D/ign.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "the machine's Ignore holds when the user's plist lacks the key (rc $rc)"
for bad_args in "-p diskX removable writable" "-p ../disk2 removable writable" "-p ${E}s removable writable" "-p $E sometimes writable" "-p $E" "-z" ""; do
  # shellcheck disable=SC2086
  u linuxfs_ext4.util $bad_args >/dev/null 2>&1; rc=$?
  [ $rc = 254 ]; ok $? "bad arguments '$bad_args' exit 254 (rc $rc)"
done
u linuxfs_ext4.util -p disk99999 removable writable >/dev/null 2>&1; rc=$?
[ $rc = 254 ]; ok $? "a disk that does not exist exits 254 (rc $rc)"
u bogus.util -p "$E" removable writable >/dev/null 2>&1; rc=$?
[ $rc = 254 ]; ok $? "an unknown program name exits 254 (rc $rc)"
u fsck_linuxfs_ext4 -q "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 0 ]; ok $? "fsck -q exits 0 (rc $rc)"
out=$(u fsck_linuxfs_ext4 -n "/dev/r$E" 2>&1); rc=$?
[ $rc = 8 ] && [ "$out" = "Verify and Repair for ext4 come with its tools" ]; ok $? "fsck -n exits 8 and says why (rc $rc, '$out')"
u fsck_linuxfs_ext4 -y "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck -y exits 8 (rc $rc)"
u fsck_linuxfs_ext4 >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck with no flag exits 8 (rc $rc)"
out=$(u fsck_linuxfs_ext4 -z "/dev/r$E" 2>&1 >/dev/null); rc=$?
[ $rc = 8 ] && case $out in usage:*) true ;; *) false ;; esac; ok $? "fsck with an unknown flag exits 8 with a usage line on stderr (rc $rc, '$out')"
u fsck_linuxfs_ext4 -qn "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck flags are parsed exactly: -qn is not -q (rc $rc)"
u mount_linuxfs_ext4 -o owners "/dev/$E" /tmp/nowhere >/dev/null 2>&1; rc=$?
[ $rc = 1 ]; ok $? "the mount role is not yet implemented: exits 1 (rc $rc)"
echo "1..$n"; exit $bad
