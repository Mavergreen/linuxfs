#!/bin/sh
# platform: macOS-only -- runs the 10.9 build of lklfuse, which only a Mac executes; Linux makes its image
#   usage: lklfuse-sigterm-darwin.sh
#          SIGTERM ends lklfuse within 3 s while it serves a /dev/fd/N mountpoint (a socketpair stands in for the
#          macFUSE device: no mount, no kext, no root), with the libfuse 3 of the macFUSE release pinned in
#          components/macfuse/version. lklfuse ends 0 then: libfuse's handler ends the loop, the exit status is
#          lklfuse's own (fuse_main's 8 is not involved). Also: nothing in lklfuse leaves SIGTERM blocked through
#          sigprocmask, which is how Darwin's longjmp restores a mask (patches/lkl/0011). Needs
#          build/build-lkl-darwin.sh's output in $GATE0_DARWIN_OUT.
set -u
case "$(uname -s)" in Darwin) ;; *) echo "lklfuse-sigterm-darwin.sh: runs on a Mac" >&2; exit 77 ;; esac
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] && { echo "lklfuse-sigterm-darwin.sh: x86_64 binary; Apple Silicon would need Rosetta" >&2; exit 77; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
C=${GATE0_CACHE:-$HOME/Library/Caches/mm-build/linuxfs-gate0}
OUT=${GATE0_DARWIN_OUT:-$C/darwin}
[ -x "$OUT/lklfuse" ] || { echo "not ok 1 - $OUT/lklfuse is built"; echo "1..1"; exit 1; }
W=$C/lklfuse-sigterm
rm -rf "$W"; mkdir -p "$W"
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22") || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh") || exit 1
F=$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" macfuse "$(tr -d '[:space:]' < "$ROOT/components/macfuse/version")" "$W/macfuse" | tail -1) || exit 1
cc() { "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -g -Wall -fuse-ld=lld "$@"; }
cc -o "$W/lklfuse-sigterm" "$ROOT/tests/lib/lklfuse-sigterm.c" && cc -dynamiclib -o "$W/sigmask-probe.dylib" "$ROOT/tests/lib/sigmask-probe.c"
ok $? "build the harness and the sigprocmask probe"
sh "$ROOT/build/linux-host.sh" sh -c 'truncate -s 64M "$1" && mkfs.ext4 -q -F "$1"' _ "$W/disk.img"
ok $? "an ext4 disk"
# spec: tests/smoke-mavericks.sh kill_lklfuse -- it allows 5 s after SIGTERM; 3 s is three of libfuse's 1 s slices. The 3 s settle
#       lets LKL boot and mount the image inside, so the signal arrives with the kernel's threads running
env DYLD_LIBRARY_PATH="$F/lib" DYLD_FRAMEWORK_PATH="$F/fs/Contents/Frameworks" DYLD_INSERT_LIBRARIES="$W/sigmask-probe.dylib" \
  "$W/lklfuse-sigterm" "$OUT/lklfuse" "$W/disk.img" 3 3000 > "$W/result" 2> "$W/stderr"
rc=$?
# platform: LKL's console log shares lklfuse's stdout; the harness's verdict is the last line
tail -1 "$W/result" > "$W/verdict"
echo "# lklfuse: $(cat "$W/verdict")"
ok $rc "SIGTERM ends lklfuse within 3 s while it serves /dev/fd/4"
grep -q '^exited [0-9]* status=0$' "$W/verdict"
ok $? "lklfuse ends with status 0 (the loop ended, LKL halted)"
! grep -q 'SIGTERM-BLOCKED' "$W/stderr"
ok $? "no sigprocmask in lklfuse leaves SIGTERM blocked"
echo "1..$n"
[ "$bad" = 0 ] || sed 's/^/# stderr: /' "$W/stderr" | grep -v '^# stderr: \[' | head -10
exit $bad
