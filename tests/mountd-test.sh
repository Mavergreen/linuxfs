#!/bin/sh
# platform: macOS-only -- tools/mountd.c links the helper's media rule (tools/helper.c), which needs IOKit and CoreFoundation
#   usage: mountd-test.sh
#          Builds the root mount daemon's judging functions (tools/mountd.c, LINUXFS_MOUNTD_NO_MAIN) for 10.9 with their
#          test and runs it: the request line, the peer, whose disk it is and the rest of the verdict, the mount point's
#          facts before and after adoption, the status and the reply line. Nothing is attached, opened or run as root.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
D=$HOME/Library/Caches/mm-build/linuxfs-mountd-test; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld \
  -DLINUXFS_MOUNTD_NO_MAIN -DLINUXFS_HELPER_NO_MAIN -DLINUXFS_PROBE_NO_MAIN -o "$D/policy" "$ROOT/tests/mountd-policy-test.c" \
  "$ROOT/tools/mountd.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/helper.c" "$ROOT/tools/probe.c" "$ROOT/tools/plist.c" \
  "$ROOT/tools/fstab.c" -framework IOKit -framework CoreFoundation || exit 1
"$D/policy"
