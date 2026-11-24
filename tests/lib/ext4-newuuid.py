# ext4-newuuid.py IMAGE [UUID] -- give an ext4 image (no partition map) a new filesystem UUID, in place.
# Only for images with metadata_csum_seed (INCOMPAT 0x2000): their metadata checksums are seeded from
# s_checksum_seed, not the UUID, so only the primary superblock's s_uuid and s_checksum change (what
# tune2fs -U does for such a filesystem, minus the backup superblocks, which the kernel never reads).
# Prints the new UUID (uppercase). Runs under the system python of Mac OS X 10.9 (2.7) and python 3.
import struct, sys, uuid

def crc32c_table():
    t = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
        t.append(c)
    return t

def crc32c(data, crc=0xFFFFFFFF):
    # ext4's ext4_chksum: crc32c_le with seed ~0 and no final inversion
    t = crc32c_table()
    for b in bytearray(data):
        crc = t[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc

def main():
    if len(sys.argv) not in (2, 3):
        sys.stderr.write("usage: ext4-newuuid.py IMAGE [UUID]\n")
        return 2
    new = uuid.UUID(sys.argv[2]) if len(sys.argv) == 3 else uuid.uuid4()
    f = open(sys.argv[1], "r+b")
    f.seek(1024)
    sb = bytearray(f.read(1024))
    if struct.unpack_from("<H", sb, 0x38)[0] != 0xEF53:
        sys.stderr.write("not ext2/3/4 at offset 1024\n")
        return 1
    incompat = struct.unpack_from("<I", sb, 0x60)[0]
    ro_compat = struct.unpack_from("<I", sb, 0x64)[0]
    if not incompat & 0x2000:
        sys.stderr.write("no metadata_csum_seed: changing the UUID would need every checksum rewritten\n")
        return 1
    if ro_compat & 0x400:
        old = struct.unpack_from("<I", sb, 0x3FC)[0]
        if crc32c(bytes(sb[:0x3FC])) != old:
            sys.stderr.write("the superblock checksum does not verify before the change\n")
            return 1
    sb[0x68:0x78] = new.bytes
    if ro_compat & 0x400:
        struct.pack_into("<I", sb, 0x3FC, crc32c(bytes(sb[:0x3FC])))
    f.seek(1024)
    f.write(bytes(sb))
    f.close()
    print(str(new).upper())
    return 0

sys.exit(main())
