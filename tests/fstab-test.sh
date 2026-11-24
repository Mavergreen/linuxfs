#!/bin/sh
# platform: host-agnostic
#   usage: fstab-test.sh
#          Builds tools/fstab.c with its test and runs it: linuxfs's /etc/fstab noauto entries (which specs and bundles
#          may be written, label escapes, edits that keep every other line, lookups). On Linux it builds with cc; on a
#          Mac with clang22 and the 10.9 SDK, so both builds are tested.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(uname -s)" = Linux ]; then
  D=$(mktemp -d "${TMPDIR:-/tmp}/fstab-test.XXXXXX") || exit 1; trap 'rm -rf "$D"' EXIT
  cc -std=c99 -O2 -Wall -Werror -o "$D/fstab-test" "$ROOT/tests/fstab-test.c" "$ROOT/tools/fstab.c" "$ROOT/tools/fsrules.c" || exit 1
else
  . "$ROOT/build/msc.sh"
  D=$HOME/Library/Caches/mm-build/linuxfs-fstab-test; rm -rf "$D"; mkdir -p "$D"
  CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
  SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
  "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -std=c99 -O2 -Wall -Werror -fuse-ld=lld \
    -o "$D/fstab-test" "$ROOT/tests/fstab-test.c" "$ROOT/tools/fstab.c" "$ROOT/tools/fsrules.c" || exit 1
fi
"$D/fstab-test"
