#!/bin/sh
# platform: macOS-only -- runs the 10.9 build of tests/lklfuse-ops-test.c; Linux makes its image
#   usage: lklfuse-ops-darwin.sh
#          lklfuse's callbacks on 10.9 without a FUSE mount: what macFUSE would be told (Darwin errno
#          values, Darwin xattr and rename flags translated), and its Unicode names (patch 0012: stored NFC, shown as
#          HFS+ shows them, found in any form, both scanning and with macFUSE's name pass-through, which it takes
#          from the installed macFUSE's version; CoreFoundation's, so checked here only), and its FUSE destroy (patch
#          0015: the disk and the lock let go of before macFUSE's unmount returns), and the volume icon (patch 0017: volicon=,
#          a read-only /.VolumeIcon.icns and the root's custom-icon flag while the volume has no icon of its own), and Mac
#          xattrs (patch 0013: user.N, and netatalk's and Samba's schemes, on tests/lib/xattr-images.sh's four images,
#          which Linux makes too, and reads back after lklfuse has written them: tests/lib/check-xattrs.sh; and on a blank
#          NTFS image, the bare com.apple.* names linuxfs stored there before 0013), and what its init asks of macFUSE
#          (patch 0014: case-sensitive, unless -o nocase), and an image file's exclusive lock (patch 0019: an image
#          hdiutil attached, here -nomount, is refused; a file system that cannot flock is not), and no
#          com.apple.ResourceFork listed (patch 0020: libfuse never serves it). Needs
#          build/build-lkl-darwin.sh's output.
set -u
case "$(uname -s)" in Darwin) ;; *) echo "lklfuse-ops-darwin.sh: runs on a Mac" >&2; exit 77 ;; esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C=$HOME/Library/Caches/mm-build/linuxfs-gate0
OUT=${GATE0_DARWIN_OUT:-$C/darwin}
img=$C/lklfuse-ops.img xa=$C/lklfuse-ops-xa
rm -rf "$img" "$xa"
sh "$ROOT/build/linux-host.sh" sh -c 'truncate -s 64M "$1" && mkfs.ext4 -q -F "$1" && sh "$3" "$2" && truncate -s 16M "$2/ntfs-xa.img" && mkntfs -q -F -Q "$2/ntfs-xa.img" >/dev/null' _ "$img" "$xa" "$ROOT/tests/lib/xattr-images.sh" || exit 1
# patch 0019: an image hdiutil has attached (read-write, nothing mounted) is one lklfuse refuses
att=$C/lklfuse-ops-attached.img; rm -f "$att"; dd if=/dev/zero of="$att" bs=1048576 count=1 2> /dev/null
attd=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$att" | awk 'NR == 1 { print $1 }')
LKLFUSE_OPS_ATTACHED=$att "$OUT/tests/lklfuse-ops" "$img" "$xa" > "$img.log" 2>&1; rc=$?
test -z "$attd" || hdiutil detach -quiet -force "$attd"; rm -f "$att"
grep -E '^(ok|not ok|1\.\.)' "$img.log"
# what lklfuse wrote to the xattr images, read back by Linux (debugfs), as the fsck job reads the smoke's
sh "$ROOT/build/linux-host.sh" sh "$ROOT/tests/lib/check-xattrs.sh" "$xa" > "$img.log" 2>&1 || { rc=1; echo "not ok - check-xattrs.sh on the images lklfuse wrote:"; }
sed 's/^/# check-xattrs: /' "$img.log"
rm -rf "$img" "$img.log" "$xa"
exit $rc
