#!/bin/sh
# platform: host-agnostic
#   usage: fsrules-test.sh
#          Builds tools/fsrules.c with its test and runs it: the bundles' portable rules (program name to
#          filesystem, which probe answers are claimed, mount's arguments, volume names). On Linux it builds
#          with cc; on a Mac with clang22 and the 10.9 SDK, so both builds are tested.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(uname -s)" = Linux ]; then
  D=${FSRULES_TEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/fsrules-test.XXXXXX")}
  cc -std=c99 -O2 -Wall -Werror -o "$D/fsrules-test" "$ROOT/tests/fsrules-test.c" "$ROOT/tools/fsrules.c" || exit 1
else
  . "$ROOT/build/msc.sh"
  D=$HOME/Library/Caches/mm-build/linuxfs-fsrules-test; rm -rf "$D"; mkdir -p "$D"
  CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
  SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
  "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -std=c99 -O2 -Wall -Werror -fuse-ld=lld \
    -o "$D/fsrules-test" "$ROOT/tests/fsrules-test.c" "$ROOT/tools/fsrules.c" || exit 1
fi
"$D/fsrules-test"
