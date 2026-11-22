#!/bin/sh
# platform: host-agnostic
#   usage: graft-apfs.sh APFS-SRC KERNEL-SRC TAG [EXTRA-DIR]
#          Builds linux-apfs-rw (an out-of-tree module) into a kernel tree as fs/apfs: copies APFS-SRC's sources,
#          writes a Kconfig (APFS_FS, selecting crc32c, zlib and NLS, which the driver uses) and a built-in Makefile
#          from upstream's object list, hooks fs/Kconfig and fs/Makefile, writes version.h for TAG (upstream's
#          genver.sh needs git), and sets CONFIG_APFS_FS=y in LKL's defconfig. Running it again changes nothing.
#          The driver mounts read-only unless given `readwrite`.
#          EXTRA-DIR holds linuxfs's additions (components/linux-apfs): src/*.[ch], copied in and built too, and
#          patches/*.patch, applied to the result in name order (-p1, no fuzz); one that does not apply stops it.
set -eu
{ [ "$#" -eq 3 ] || [ "$#" -eq 4 ]; } || { echo "usage: graft-apfs.sh APFS-SRC KERNEL-SRC TAG [EXTRA-DIR]" >&2; exit 2; }
A=$1 K=$2 TAG=$3 X=${4:-}
D=$K/fs/apfs
rm -rf "$D"; mkdir -p "$D"
(cd "$A" && find . -name '*.[ch]' | while read -r f; do mkdir -p "$D/$(dirname "$f")"; cp "$f" "$D/$f"; done)
objs=$(sed -n '/^apfs-y/,/[^\\]$/p' "$A/Makefile" | sed 's/^apfs-y[[:space:]]*:=//; s/\\$//' | tr -s ' \t\n' ' ')
[ -n "$objs" ] || { echo "graft-apfs.sh: no apfs-y object list in $A/Makefile" >&2; exit 1; }
if [ -n "$X" ]; then
  for f in "$X"/src/*.[ch]; do
    [ -f "$f" ] || continue
    cp "$f" "$D/"
    case $f in *.c) objs="$objs $(basename "$f" .c).o" ;; esac
  done
  for p in "$X"/patches/*.patch; do
    [ -f "$p" ] || continue
    patch -s -p1 -F0 -N -d "$D" < "$p" || { echo "graft-apfs.sh: $(basename "$p") does not apply" >&2; exit 1; }
  done
  find "$D" -name '*.orig' -exec rm -f {} +
fi
{ echo '# SPDX-License-Identifier: GPL-2.0-only'
  echo '# linux-apfs-rw, built in by linuxfs (build/graft-apfs.sh)'
  echo 'obj-$(CONFIG_APFS_FS) += apfs.o'
  echo "apfs-y := $objs"; } > "$D/Makefile"
cat > "$D/Kconfig" <<'K'
# SPDX-License-Identifier: GPL-2.0-only
config APFS_FS
	tristate "Apple File System (linux-apfs-rw; read-only unless mounted readwrite)"
	depends on BLOCK
	select LIBCRC32C
	select ZLIB_INFLATE
	select NLS
	select BUFFER_HEAD
	select CRYPTO_LIB_AES
	select CRYPTO_LIB_SHA256
	help
	  Apple's APFS, from https://github.com/linux-apfs/linux-apfs-rw. linuxfs mounts it read-only.
K
printf '#define GIT_COMMIT "%s"\n' "$TAG" > "$D/version.h"
if ! grep -q 'source "fs/apfs/Kconfig"' "$K/fs/Kconfig"; then
  awk '{ l[NR] = $0 } END { for (i = 1; i <= NR; i++) { if (l[i] == "endmenu" && i == NR) print "source \"fs/apfs/Kconfig\""; print l[i] } }' \
    "$K/fs/Kconfig" > "$K/fs/Kconfig.new"
  mv "$K/fs/Kconfig.new" "$K/fs/Kconfig"
fi
grep -q 'CONFIG_APFS_FS' "$K/fs/Makefile" || printf 'obj-$(CONFIG_APFS_FS)\t\t+= apfs/\n' >> "$K/fs/Makefile"
grep -qx 'CONFIG_APFS_FS=y' "$K/arch/lkl/configs/defconfig" || echo 'CONFIG_APFS_FS=y' >> "$K/arch/lkl/configs/defconfig"
grep -q 'source "fs/apfs/Kconfig"' "$K/fs/Kconfig" || { echo "graft-apfs.sh: fs/Kconfig does not end in endmenu; cannot hook fs/apfs" >&2; exit 1; }
