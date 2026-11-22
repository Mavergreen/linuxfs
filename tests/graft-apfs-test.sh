#!/bin/sh
# platform: host-agnostic
#   usage: graft-apfs-test.sh
#          build/graft-apfs.sh puts linux-apfs-rw's sources into a kernel tree as fs/apfs, built in: its own Kconfig
#          (APFS_FS, selecting what the driver uses) and Makefile, fs/Kconfig and fs/Makefile hooked, version.h
#          written (genver.sh needs git), CONFIG_APFS_FS=y in LKL's defconfig; a second run changes nothing.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/graft-apfs-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
K=$T/kernel A=$T/apfs
mkdir -p "$K/fs/btrfs" "$K/arch/lkl/configs" "$A/lzfse"
printf 'menu "File systems"\nsource "fs/btrfs/Kconfig"\nendmenu\n' > "$K/fs/Kconfig"
printf 'obj-$(CONFIG_BTRFS_FS)\t\t+= btrfs/\n' > "$K/fs/Makefile"
printf 'CONFIG_BTRFS_FS=y\n' > "$K/arch/lkl/configs/defconfig"
for f in super.c btree.c lzfse/lzfse_decode.c apfs.h; do echo "/* $f */" > "$A/$f"; done
printf 'obj-m = apfs.o\napfs-y := btree.o super.o \\\n\t  lzfse/lzfse_decode.o\n' > "$A/Makefile"
sh "$ROOT/build/graft-apfs.sh" "$A" "$K" v0.3.9; ok $? "graft runs"
[ -f "$K/fs/apfs/super.c" ] && [ -f "$K/fs/apfs/lzfse/lzfse_decode.c" ]; ok $? "the sources are in fs/apfs"
grep -q '^config APFS_FS$' "$K/fs/apfs/Kconfig" && grep -q 'select LIBCRC32C' "$K/fs/apfs/Kconfig" && grep -q 'select ZLIB_INFLATE' "$K/fs/apfs/Kconfig"
ok $? "fs/apfs/Kconfig declares APFS_FS and selects crc32c and zlib"
grep -q '^obj-$(CONFIG_APFS_FS) += apfs.o$' "$K/fs/apfs/Makefile" && grep -q 'lzfse/lzfse_decode.o' "$K/fs/apfs/Makefile" && ! grep -q 'obj-m' "$K/fs/apfs/Makefile"
ok $? "fs/apfs/Makefile builds it in, with upstream's object list"
grep -q 'source "fs/apfs/Kconfig"' "$K/fs/Kconfig" && [ "$(tail -n 1 "$K/fs/Kconfig")" = endmenu ]; ok $? "fs/Kconfig sources it inside the menu"
grep -q 'apfs/' "$K/fs/Makefile"; ok $? "fs/Makefile descends into it"
grep -q 'v0.3.9' "$K/fs/apfs/version.h"; ok $? "version.h names the pinned tag"
grep -qx 'CONFIG_APFS_FS=y' "$K/arch/lkl/configs/defconfig"; ok $? "LKL's defconfig turns it on"
sum() { find "$K" -type f | sort | xargs cat | cksum; }
s1=$(sum); sh "$ROOT/build/graft-apfs.sh" "$A" "$K" v0.3.9; [ "$(sum)" = "$s1" ]; ok $? "a second graft changes nothing"
# spec: build/graft-apfs.sh --
#       linuxfs's additions (EXTRA-DIR): its own sources, built in too, and patches to upstream's
X=$T/extra; mkdir -p "$X/src" "$X/patches"
echo '/* unlock.c */' > "$X/src/unlock.c"; echo '/* unlock.h */' > "$X/src/unlock.h"
printf -- '--- a/super.c\n+++ b/super.c\n@@ -1 +1,2 @@\n /* super.c */\n+/* unlocks encrypted volumes */\n' > "$X/patches/0001-encryption.patch"
sh "$ROOT/build/graft-apfs.sh" "$A" "$K" v0.3.9 "$X"; ok $? "graft runs with linuxfs's additions"
[ -f "$K/fs/apfs/unlock.c" ] && [ -f "$K/fs/apfs/unlock.h" ] && grep -q 'apfs-y := .* unlock\.o' "$K/fs/apfs/Makefile"; ok $? "their sources are in fs/apfs and built"
grep -q 'unlocks encrypted volumes' "$K/fs/apfs/super.c"; ok $? "their patches are applied"
grep -q 'select CRYPTO_LIB_AES' "$K/fs/apfs/Kconfig" && grep -q 'select CRYPTO_LIB_SHA256' "$K/fs/apfs/Kconfig"; ok $? "Kconfig selects the AES and SHA-256 libraries they use"
s1=$(sum); sh "$ROOT/build/graft-apfs.sh" "$A" "$K" v0.3.9 "$X"; [ "$(sum)" = "$s1" ]; ok $? "a second graft with them changes nothing"
printf -- '--- a/super.c\n+++ b/super.c\n@@ -1 +1,2 @@\n /* not there */\n+x\n' > "$X/patches/0002-stale.patch"
sh "$ROOT/build/graft-apfs.sh" "$A" "$K" v0.3.9 "$X" 2>/dev/null; [ $? -ne 0 ]; ok $? "a patch that does not apply stops the graft"
echo "1..$n"; exit $bad
