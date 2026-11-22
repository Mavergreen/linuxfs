#!/bin/sh
# platform: macOS-only -- runs the 10.9 Mach-O build of LKL, which only a Mac executes
#   usage: boot-darwin.sh
#          Runs upstream's LKL boot test (TAP) from the Darwin build that build/build-lkl-darwin.sh
#          left in $GATE0_DARWIN_OUT. Passes only if every case passes.
set -u
case "$(uname -s)" in Darwin) ;; *) echo "boot-darwin.sh: runs on a Mac" >&2; exit 77 ;; esac
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] && { echo "boot-darwin.sh: x86_64 binary; Apple Silicon would need Rosetta" >&2; exit 77; }
OUT=${GATE0_DARWIN_OUT:-$HOME/Library/Caches/mm-build/linuxfs-gate0/darwin}
[ -x "$OUT/tests/boot" ] || { echo "not ok 1 - $OUT/tests/boot is built"; echo "1..1"; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$OUT/tests/boot" "$OUT/tests/disk" "$OUT/gate0-rw" >&2 || exit 1
log=$OUT/boot.log
"$OUT/tests/boot" > "$log" 2>&1; rc=$?
grep -E '^(ok|not ok|1\.\.)' "$log"
grep -q '^not ok' "$log" && rc=1
grep -q '^ok' "$log" || { echo "boot-darwin.sh: no TAP output (exit $rc); see $log" >&2; rc=1; }
exit $rc
