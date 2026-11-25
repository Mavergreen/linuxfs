#!/bin/sh
# platform: macOS-only -- runs the 10.9 build of tests/lklfuse-ops-test.c; Linux makes its image
#   usage: lklfuse-ops-darwin.sh
#          lklfuse's callbacks on 10.9 without a FUSE mount: what macFUSE would be told (Darwin errno
#          values, Darwin xattr and rename flags translated), and its Unicode names (patch 0012: stored NFC, shown as
#          HFS+ shows them, found in any form, both scanning and with macFUSE's name pass-through, which it takes
#          from the installed macFUSE's version; CoreFoundation's, so checked here only). Needs
#          build/build-lkl-darwin.sh's output.
set -u
case "$(uname -s)" in Darwin) ;; *) echo "lklfuse-ops-darwin.sh: runs on a Mac" >&2; exit 77 ;; esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C=$HOME/Library/Caches/mm-build/linuxfs-gate0
OUT=${GATE0_DARWIN_OUT:-$C/darwin}
img=$C/lklfuse-ops.img
rm -f "$img"
sh "$ROOT/build/linux-host.sh" sh -c 'truncate -s 64M "$1" && mkfs.ext4 -q -F "$1"' _ "$img" || exit 1
"$OUT/tests/lklfuse-ops" "$img" > "$img.log" 2>&1; rc=$?
grep -E '^(ok|not ok|1\.\.)' "$img.log"
rm -f "$img" "$img.log"
exit $rc
