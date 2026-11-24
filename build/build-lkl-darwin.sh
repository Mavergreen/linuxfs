#!/bin/sh
# platform: host-agnostic
#   usage: build-lkl-darwin.sh OUT
#          Builds LKL for x86_64 Mac OS X 10.9 on the Linux host: the kernel as ELF exactly as
#          build-lkl-linux.sh does (sharing its output, $GATE0_LINUX_OUT), converted to a Mach-O relocatable by
#          build/elf2macho.py, plus the host library and the boot/disk/gate0-rw programs
#          cross-compiled with clang22 against the pinned 10.9 SDK. Writes OUT/liblkl.a,
#          OUT/include/, OUT/tests/{boot,disk}, OUT/gate0-rw, OUT/linuxfs-{probe,open,helper,agent,fs} and OUT/lklfuse. lklfuse builds against
#          the libfuse 3 headers and links the libfuse3.4.dylib (install name /usr/local/lib/libfuse3.4.dylib) of the
#          Mavergreen macFUSE release components/macfuse/version pins, taken from its pkg by fetch_product_pkg.sh.
#          Linux only.
set -eu
[ "$#" -eq 1 ] || { echo "usage: build-lkl-darwin.sh OUT" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "build-lkl-darwin.sh: Linux host only" >&2; exit 77; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
OUT=$1
WORK=${GATE0_WORK:-/work/gate0-darwin}
LIN=${GATE0_LINUX_OUT:-/work/gate0-linux/out}
sh "$ROOT/build/build-lkl-linux.sh" "$LIN"
SRC=$LIN/src L=$LIN/src/tools/lkl
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22")
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")
O=$WORK/obj
rm -rf "$O" "$OUT"; mkdir -p "$O" "$OUT/tests"
python3 "$ROOT/build/elf2macho.py" "$LIN/build/lkl.o" "$O/lkl.o"
cp -R "$LIN/build/include" "$OUT/include"
# platform: LKL's Darwin host configuration is its POSIX host layer, with no networking back ends
printf '#define LKL_HOST_CONFIG_POSIX y\n' > "$OUT/include/lkl_autoconf.h"
cc() {
  "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -g -Wall \
    -Wno-unused-parameter -Wno-pointer-arith -Wno-sign-compare \
    -I"$OUT/include" -I"$L/include" -I"$L/lib" -D_FILE_OFFSET_BITS=64 "$@"
}
for f in fs iomem net jmp_buf posix-host utils virtio_blk virtio config; do
  cc -c -o "$O/$f.o" "$L/lib/$f.c"
done
rm -f "$OUT/liblkl.a"
"$CL/bin/llvm-ar" rcs "$OUT/liblkl.a" "$O"/*.o
link() { out=$1; shift; cc -g0 -fuse-ld=lld -o "$out" "$@" "$OUT/liblkl.a" -lpthread; }
for t in cla test; do cc -c -o "$O/t-$t.o" "$L/tests/$t.c"; done
for t in boot disk; do
  cc -c -o "$O/t-main-$t.o" "$L/tests/$t.c"
  link "$OUT/tests/$t" "$O/t-main-$t.o" "$O/t-cla.o" "$O/t-test.o"
done
cc -c -o "$O/gate0-rw.o" "$ROOT/tests/gate0-rw.c"
link "$OUT/gate0-rw" "$O/gate0-rw.o"
cc -g0 -fuse-ld=lld -o "$OUT/linuxfs-probe" "$ROOT/tools/probe.c"
cc -g0 -fuse-ld=lld -DLINUXFS_PROBE_NO_MAIN -o "$OUT/linuxfs-open" "$ROOT/tools/open.c" "$ROOT/tools/probe.c"
cc -g0 -fuse-ld=lld -DLINUXFS_PROBE_NO_MAIN -o "$OUT/linuxfs-helper" "$ROOT/tools/helper.c" "$ROOT/tools/probe.c" "$ROOT/tools/fstab.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/plist.c" -framework IOKit -framework CoreFoundation
cc -g0 -fuse-ld=lld -o "$OUT/linuxfs-agent" "$ROOT/tools/agent.c" "$ROOT/tools/fstab.c" "$ROOT/tools/fsrules.c" -framework DiskArbitration -framework CoreFoundation -framework Security
cc -g0 -fuse-ld=lld -DLINUXFS_PROBE_NO_MAIN -o "$OUT/linuxfs-fs" "$ROOT/tools/fs.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/plist.c" "$ROOT/tools/probe.c" -framework CoreFoundation -framework DiskArbitration
F=$WORK/macfuse
sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" macfuse "$(tr -d '[:space:]' < "$ROOT/components/macfuse/version")" "$F" >/dev/null
cc -I"$F/include" -c -o "$O/lklfuse.o" "$L/lklfuse.c"
link "$OUT/lklfuse" "$O/lklfuse.o" -L"$F/lib" -lfuse3
# platform: tests/lklfuse-ops-test.c calls lklfuse's callbacks without a mount, so libfuse is never called and stays unbound
cc -I"$F/include" -I"$L" -c -o "$O/lklfuse-ops.o" "$ROOT/tests/lklfuse-ops-test.c"
link "$OUT/tests/lklfuse-ops" "$O/lklfuse-ops.o" -Wl,-undefined,dynamic_lookup
for b in "$OUT/tests/boot" "$OUT/tests/disk" "$OUT/gate0-rw" "$OUT/lklfuse"; do
  sh "$ROOT/build/check-macho-layout.sh" "$CL/bin/llvm-otool" "$b"
done
