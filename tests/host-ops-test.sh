#!/bin/sh
# platform: macOS-only -- runs LKL's host layer as a 10.9 Mach-O, which only a Mac executes
#   usage: host-ops-test.sh
#          Builds LKL's host layer (patched posix-host.c) with tests/host-ops-test.c, no kernel, for
#          x86_64 10.9 with clang22, and runs it. Needs the generated LKL headers that
#          build/build-lkl-darwin.sh leaves in $GATE0_DARWIN_OUT/include.
set -eu
case "$(uname -s)" in Darwin) ;; *) echo "host-ops-test.sh: runs on a Mac" >&2; exit 77 ;; esac
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] && { echo "host-ops-test.sh: x86_64 binary; Apple Silicon would need Rosetta" >&2; exit 77; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
C=${GATE0_CACHE:-$HOME/Library/Caches/mm-build/linuxfs-gate0}
GEN=${GATE0_DARWIN_OUT:-$C/darwin}/include
[ -d "$GEN/lkl" ] || { echo "host-ops-test.sh: no generated LKL headers in $GEN (run build/build-lkl-darwin.sh)" >&2; exit 1; }
W=$C/host-ops
rm -rf "$W"; mkdir -p "$W/inc"
sh "$ROOT/build/fetch-lkl.sh" "$W/src" >/dev/null
printf "#define LKL_HOST_CONFIG_POSIX y\n" > "$W/inc/lkl_autoconf.h"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22")
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")
L=$W/src/tools/lkl
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -fuse-ld=lld -O2 -g \
  -I"$W/inc" -I"$GEN" -I"$L/include" -I"$L/lib" \
  -o "$W/host-ops-test" "$ROOT/tests/host-ops-test.c" "$L/lib/posix-host.c" "$L/lib/utils.c" \
  "$L/lib/jmp_buf.c" "$L/lib/iomem.c" "$L/lib/virtio.c" -lpthread \
  -Wl,-undefined,dynamic_lookup  # no kernel (lkl.o) here: its entry points stay unbound and unreached
sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$W/host-ops-test"
"$W/host-ops-test"
