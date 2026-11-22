#!/usr/bin/env python3
# platform: host-agnostic -- python3 only
#   usage: python3 -I gpt-wrap.py CONTAINER-IMAGE DISK-IMAGE
#          Writes DISK-IMAGE: a GPT disk (512-byte sectors) with one APFS partition holding CONTAINER-IMAGE, as an
#          external disk formatted by macOS is laid out (a bare container has no partition, so DiskArbitration
#          gives it no partition UUID, which the agent's keychain needs). The disk and partition GUIDs are fixed,
#          so the same container always makes the same disk.
import struct
import sys
import uuid
import zlib

APFS_TYPE = uuid.UUID("7C3457EF-0000-11AA-AA11-00306543ECAC")
DISK_GUID = uuid.UUID("6C696E75-7866-7364-6973-6B0000000001")   # "linuxfsdisk", fixed
PART_GUID = uuid.UUID("6C696E75-7866-7370-6172-740000000001")   # "linuxfspart", fixed
S = 512
FIRST = 40                      # 4 KiB-aligned, as diskutil places it
ENTRIES, ENTRY_SIZE = 128, 128  # the entry array: 32 sectors


def header(current, backup, entries_lba, last_usable, entries_crc):
    h = struct.pack("<8sIIIIQQQQ16sQIII", b"EFI PART", 0x10000, 92, 0, 0, current, backup, 34, last_usable,
                    DISK_GUID.bytes_le, entries_lba, ENTRIES, ENTRY_SIZE, entries_crc)
    h = h[:16] + struct.pack("<I", zlib.crc32(h)) + h[20:]
    return h + b"\0" * (S - len(h))


def main(src, dst):
    with open(src, "rb") as f:
        data = f.read()
    sectors = -(-len(data) // S)
    last = FIRST + sectors - 1
    total = last + 1 + 1 + 33                   # a free sector, then the backup entries and header
    name = "Secret".encode("utf-16-le")
    entry = struct.pack("<16s16sQQQ72s", APFS_TYPE.bytes_le, PART_GUID.bytes_le, FIRST, last, 0, name)
    entries = entry + b"\0" * (ENTRIES * ENTRY_SIZE - len(entry))
    crc = zlib.crc32(entries)
    last_usable = total - 34
    mbr = bytearray(S)
    mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1, min(total - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    with open(dst, "wb") as f:
        f.write(mbr)
        f.write(header(1, total - 1, 2, last_usable, crc))
        f.write(entries)
        f.seek(FIRST * S)
        f.write(data)
        f.seek((total - 33) * S)
        f.write(entries)
        f.write(header(total - 1, 1, total - 33, last_usable, crc))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: gpt-wrap.py CONTAINER-IMAGE DISK-IMAGE")
    main(sys.argv[1], sys.argv[2])
