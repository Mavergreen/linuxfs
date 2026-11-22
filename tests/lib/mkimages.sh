#!/bin/sh
# platform: host-agnostic
#   usage: mkimages.sh [--small] DIR
#          Makes fresh ext4, btrfs, xfs and NTFS images (512 MiB) and an 8 GiB sparse ext4 image,
#          plus a 5 GiB unformatted raw.img and ntfs-killed.img (a second NTFS image, for the kill test),
#          in DIR with Linux's mkfs tools, and records their SHA-256s in DIR/manifest. With --small,
#          only the four 512 MiB images: a 10.9 host's HFS+ has no sparse files, so the big ones
#          would be written out in full. Linux only.
set -eu
small=0
[ "${1:-}" = --small ] && { small=1; shift; }
[ "$#" -eq 1 ] || { echo "usage: mkimages.sh [--small] DIR" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "mkimages.sh: needs Linux's mkfs tools" >&2; exit 77; }
d=$1
mkdir -p "$d"
rm -f "$d"/*.img "$d/manifest"
for fs in ext4 btrfs xfs ntfs; do truncate -s 512M "$d/$fs.img"; done
mkfs.ext4 -q -F "$d/ext4.img"
mkfs.btrfs -q -f "$d/btrfs.img" >/dev/null
mkfs.xfs -q -f "$d/xfs.img"
mkntfs -q -F -Q "$d/ntfs.img" >/dev/null
if [ "$small" -eq 0 ]; then
  truncate -s 8G "$d/ext4-8g.img"
  truncate -s 5G "$d/raw.img"   # unformatted: for the raw-device write past 4 GiB
  mkfs.ext4 -q -F "$d/ext4-8g.img"
  cp "$d/ntfs.img" "$d/ntfs-killed.img"
fi
(cd "$d" && sha256sum *.img > manifest)
