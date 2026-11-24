#!/bin/sh
# platform: host-agnostic
#   usage: probe-images.sh DIR
#          Makes the small images tests/probe-test.sh probes, with Linux's mkfs tools: one per filesystem, labelled
#          where the filesystem has a label linuxfs-probe reads, plus a short, a cut and an all-zero file. Linux only.
set -eu
[ "$(uname -s)" = Linux ] || { echo "probe-images.sh: needs Linux's mkfs tools" >&2; exit 77; }
cd "$1"
truncate -s 128M ext4.img; mkfs.ext4 -q -F -L "my data" ext4.img
truncate -s 128M btrfs.img; mkfs.btrfs -q -f -L backup btrfs.img >/dev/null
truncate -s 320M xfs.img; mkfs.xfs -q -f -L scratch xfs.img
truncate -s 64M ntfs.img; mkntfs -q -F -Q -L Windows ntfs.img >/dev/null
truncate -s 64M exfat.img; mkfs.exfat -L CARD exfat.img >/dev/null
truncate -s 64M vfat.img; mkfs.vfat -n STICK vfat.img >/dev/null
truncate -s 64M fat32.img; mkfs.vfat -F 32 -n BIG32 fat32.img >/dev/null
truncate -s 128M f2fs.img; mkfs.f2fs -q -l flash f2fs.img >/dev/null
truncate -s 64M apfs.img; mkapfs -L "Time Machine" apfs.img >/dev/null
# spec: tools/probe.c --
#       review M5: a label that is not UTF-8, and a non-ASCII NTFS label (UTF-16 on disk)
truncate -s 128M ext4-badlabel.img; mkfs.ext4 -q -F -L "$(printf 'ok\377x')" ext4-badlabel.img
truncate -s 64M ntfs-utf.img; mkntfs -q -F -Q -L "Données 😀" ntfs-utf.img >/dev/null
# spec: tools/probe.c --
#       an APFS Fusion container: main device (an SSD) and second device (an HDD); each says which it is, and of which
truncate -s 64M fusion-ssd.img; truncate -s 256M fusion-hdd.img; mkapfs -L Fused -F fusion-hdd.img fusion-ssd.img >/dev/null
# spec: tools/probe.c --
#       a dirty NTFS volume (ntfs3 will not write it): VOLUME_IS_DIRTY (1) set in $Volume's $VOLUME_INFORMATION flags, as
#       Windows leaves it, in the MFT and its mirror ($MFTMirr, which ntfs-3g compares); the record's update sequence
#       fixups are left alone (the flags never sit at a sector's end)
cp ntfs.img ntfs-dirty.img
python3 - ntfs-dirty.img <<'EOP'
import struct, sys
f = open(sys.argv[1], 'r+b'); b = f.read(512)
bps, spc = struct.unpack_from('<HB', b, 0x0b); cpr = struct.unpack_from('<b', b, 0x40)[0]
rs = 1 << -cpr if cpr < 0 else cpr * spc * bps
for lcn in struct.unpack_from('<QQ', b, 0x30):
    off = lcn * spc * bps + 3 * rs; f.seek(off); r = bytearray(f.read(rs))
    a = struct.unpack_from('<H', r, 0x14)[0]
    while struct.unpack_from('<I', r, a)[0] != 0x70: a += struct.unpack_from('<I', r, a + 4)[0]
    v = a + struct.unpack_from('<H', r, a + 0x14)[0] + 10
    assert v % bps < bps - 2
    f.seek(off + v); f.write(struct.pack('<H', struct.unpack_from('<H', r, v)[0] | 1))
EOP
ntfsinfo -f -m ntfs-dirty.img 2>/dev/null | grep -q 'Volume Flags: .* DIRTY' || { echo "probe-images.sh: ntfs-dirty.img is not dirty" >&2; exit 1; }
head -c 600 /dev/zero > short.img
head -c 1100 ext4.img > ext4-cut.img
head -c 1048576 /dev/zero > zero.img
# spec: tools/probe.c --
#       Not ext4, though the ext magic 0xEF53 sits at 1080 with a plausible superblock around it (review I5):
#       an HFS+ header ("H+" at 1024), an APFS container ("NXSB" at 32), and ext fields no filesystem has.
put() { printf "$2" | dd of="$1" bs=1 seek="$3" conv=notrunc 2>/dev/null; }
fake_ext() { head -c 1048576 /dev/zero > "$1"; put "$1" '\123\357' 1080; put "$1" '\001' 1064; put "$1" '\002' 1048; }
fake_ext hfs-magic.img; put hfs-magic.img 'H+' 1024
fake_ext apfs-magic.img; put apfs-magic.img 'NXSB' 32
fake_ext ext-bogus.img; put ext-bogus.img '\040' 1048
