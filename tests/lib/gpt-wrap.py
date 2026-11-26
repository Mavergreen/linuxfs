#!/usr/bin/env python3
# platform: host-agnostic -- python3 only
#   usage: python3 -I gpt-wrap.py CONTAINER-IMAGE DISK-IMAGE [PARTITION-TYPE-GUID [CONTAINER-IMAGE PARTITION-TYPE-GUID]...]
#          The partition type is APFS's unless given (DiskArbitration matches a bundle's media types before it probes).
#          Writes DISK-IMAGE: a GPT disk (512-byte sectors) with one partition of that type holding CONTAINER-IMAGE, as an
#          external disk formatted by macOS is laid out (a bare container has no partition, so DiskArbitration
#          gives it no partition UUID, which the agent's keychain needs). Each further pair adds a partition after it
#          (4 KiB-aligned): s2, s3 and so on, for a disk of several volumes (final review r0 C1). The disk and partition
#          GUIDs are fixed (the first partition's always ...0001, the Nth's ...000N), so the same containers always make the
#          same disk.
import struct
import sys
import uuid
import zlib

APFS_TYPE = uuid.UUID("7C3457EF-0000-11AA-AA11-00306543ECAC")
DISK_GUID = uuid.UUID("6C696E75-7866-7364-6973-6B0000000001")   # "linuxfsdisk", fixed
PART_GUID = uuid.UUID("6C696E75-7866-7370-6172-740000000001")   # "linuxfspart", fixed: the first partition's
S = 512
FIRST = 40                      # 4 KiB-aligned, as diskutil places it
ENTRIES, ENTRY_SIZE = 128, 128  # the entry array: 32 sectors


def header(current, backup, entries_lba, last_usable, entries_crc):
    h = struct.pack("<8sIIIIQQQQ16sQIII", b"EFI PART", 0x10000, 92, 0, 0, current, backup, 34, last_usable,
                    DISK_GUID.bytes_le, entries_lba, ENTRIES, ENTRY_SIZE, entries_crc)
    h = h[:16] + struct.pack("<I", zlib.crc32(h)) + h[20:]
    return h + b"\0" * (S - len(h))


def main(parts, dst):
    datas, entries, lba = [], b"", FIRST
    for k, (src, ptype) in enumerate(parts):
        with open(src, "rb") as f:
            data = f.read()
        lba = -(-lba // 8) * 8                    # 4 KiB-aligned
        last = lba + -(-len(data) // S) - 1
        guid = uuid.UUID(int=PART_GUID.int - 1 + (k + 1))
        name = ("Secret" if k == 0 else "Part %d" % (k + 1)).encode("utf-16-le")
        entries += struct.pack("<16s16sQQQ72s", ptype.bytes_le, guid.bytes_le, lba, last, 0, name)
        datas.append((lba, data))
        lba = last + 1
    total = lba + 1 + 33                        # a free sector, then the backup entries and header
    entries += b"\0" * (ENTRIES * ENTRY_SIZE - len(entries))
    crc = zlib.crc32(entries)
    last_usable = total - 34
    mbr = bytearray(S)
    mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1, min(total - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    with open(dst, "wb") as f:
        f.write(mbr)
        f.write(header(1, total - 1, 2, last_usable, crc))
        f.write(entries)
        for at, data in datas:
            f.seek(at * S)
            f.write(data)
        f.seek((total - 33) * S)
        f.write(entries)
        f.write(header(total - 1, 1, total - 33, last_usable, crc))


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) < 2 or (len(a) > 3 and len(a) % 2 == 0):
        sys.exit("usage: gpt-wrap.py CONTAINER-IMAGE DISK-IMAGE [PARTITION-TYPE-GUID [CONTAINER-IMAGE PARTITION-TYPE-GUID]...]")
    parts = [(a[0], uuid.UUID(a[2]) if len(a) > 2 else APFS_TYPE)] + [(a[i], uuid.UUID(a[i + 1])) for i in range(3, len(a), 2)]
    main(parts, a[1])
