#!/bin/sh
# platform: host-agnostic
#   usage: build-lkl-linux.sh OUT
#          Builds LKL as ELF for this Linux host from the pinned, patched source, plus gate0-rw, into
#          OUT: liblkl.a, include/, tests/{boot,disk}, gate0-rw, lklfuse, kernel.config. Linux only.
set -eu
[ "$#" -eq 1 ] || { echo "usage: build-lkl-linux.sh OUT" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "build-lkl-linux.sh: Linux host only" >&2; exit 77; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$1
SRC=$OUT/src BLD=$OUT/build
mkdir -p "$OUT"
# spec: patches/lkl/ and build/graft-apfs.sh --
#       what linuxfs adds to the pinned sources: LKL patches, and linux-apfs-rw sources and patches
ours() { cat "$ROOT"/patches/lkl/*.patch "$ROOT"/components/linux-apfs/src/* "$ROOT"/components/linux-apfs/patches/*.patch 2>/dev/null | sha256sum; }
if [ ! -f "$SRC/.mavergreen-source" ] || [ "$(cat "$ROOT/components/lkl/version" "$ROOT/components/linux-apfs/version")" != "$(cat "$OUT/pin" 2>/dev/null)" ] \
   || [ "$(ours)" != "$(cat "$OUT/patches.sum" 2>/dev/null)" ]; then
  rm -rf "$BLD"
  sh "$ROOT/build/fetch-lkl.sh" "$SRC"
  cat "$ROOT/components/lkl/version" "$ROOT/components/linux-apfs/version" > "$OUT/pin"
  ours > "$OUT/patches.sum"
fi
mkdir -p "$BLD"
make -C "$SRC/tools/lkl" OUTPUT="$BLD/" -j"$(nproc)" "$BLD/liblkl.a" "$BLD/tests/boot" "$BLD/tests/disk"
L=$BLD
cc -O2 -g -Wall -I"$L/include" -I"$SRC/tools/lkl/include" -o "$OUT/gate0-rw" \
  "$ROOT/tests/gate0-rw.c" "$L/liblkl.a" -lpthread -lrt
cc -O2 -g -Wall -I"$L/include" -I"$SRC/tools/lkl/include" $(pkg-config --cflags fuse3) -o "$OUT/lklfuse" \
  "$SRC/tools/lkl/lklfuse.c" "$L/liblkl.a" $(pkg-config --libs fuse3) -lpthread -lrt
mkdir -p "$OUT/tests"
cc -O2 -g -Wall -I"$L/include" -I"$SRC/tools/lkl/include" -I"$SRC/tools/lkl" $(pkg-config --cflags fuse3) \
  -o "$OUT/tests/lklfuse-ops" "$ROOT/tests/lklfuse-ops-test.c" "$L/liblkl.a" $(pkg-config --libs fuse3) -lpthread -lrt
cp "$L/liblkl.a" "$OUT/"
cp "$L/tests/boot" "$L/tests/disk" "$OUT/tests/"
cp "$BLD/.config" "$OUT/kernel.config"
grep -q '^CONFIG_NTFS3_FS=y' "$OUT/kernel.config" || { echo "build-lkl-linux.sh: ntfs3 not in the kernel config" >&2; exit 1; }
grep -q "^CONFIG_APFS_FS=y" "$OUT/kernel.config" || { echo "build-lkl-linux.sh: apfs not in the kernel config" >&2; exit 1; }
grep -q "^CONFIG_F2FS_FS=y" "$OUT/kernel.config" || { echo "build-lkl-linux.sh: f2fs not in the kernel config" >&2; exit 1; }
