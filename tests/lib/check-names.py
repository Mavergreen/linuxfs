#!/usr/bin/env python3
# platform: Linux -- python3 only (the fsck job, after the guest)
#   usage: python3 -I check-names.py fat IMAGE [DIR]
#          Prints, one per line in directory order, each name in DIR (a /-separated path from the root; default the
#          root) of IMAGE's FAT32 partition as the hex of its UTF-8 bytes, decoded from the long-name entries (UTF-16);
#          a name with no long-name entry is its 8.3 short name. The partition is the GPT entry of the Microsoft basic
#          data type, not "partition 1", in case diskutil eraseDisk adds an EFI partition (also FAT) before it. Exits 1
#          when there is no such partition or DIR.
import binascii
import struct
import sys
import uuid

BASIC_DATA = uuid.UUID("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")
S = 512


def fat_partition(f):
    f.seek(S)
    hdr = f.read(92)
    if hdr[:8] != b"EFI PART":
        sys.exit("check-names.py: no GPT header")
    entries_lba, count, size = struct.unpack_from("<QII", hdr, 72)
    f.seek(entries_lba * S)
    table = f.read(count * size)
    for i in range(count):
        e = table[i * size:(i + 1) * size]
        if uuid.UUID(bytes_le=e[:16]) == BASIC_DATA:
            return struct.unpack_from("<Q", e, 32)[0] * S
    sys.exit("check-names.py: no partition of the basic data type %s" % BASIC_DATA)


def geometry(f, base):
    f.seek(base)
    bs = f.read(512)
    bps, spc, rsv, nfats = struct.unpack_from("<HBHB", bs, 11)
    fatsz, = struct.unpack_from("<I", bs, 36)
    root, = struct.unpack_from("<I", bs, 44)
    fat = base + rsv * bps
    return fat, fat + nfats * fatsz * bps, spc * bps, root


def entries(f, geo, cluster):
    """The directory at CLUSTER: (name as UTF-8 bytes, attributes, first cluster) per entry, in order."""
    fat, data, csize, _ = geo
    out, parts, seen = [], {}, set()
    while 2 <= cluster < 0x0FFFFFF8 and cluster not in seen:
        seen.add(cluster)
        f.seek(data + (cluster - 2) * csize)
        block = f.read(csize)
        for off in range(0, csize, 32):
            e = block[off:off + 32]
            first, attr = e[0:1], e[11]
            if first == b"\0":
                return out
            if first == b"\xe5":
                parts = {}
                continue
            if attr & 0x3F == 0x0F:
                parts[e[0] & 0x1F] = e[1:11] + e[14:26] + e[28:32]
                continue
            if attr & 0x08:                         # the volume label
                parts = {}
                continue
            if parts:
                text = b"".join(parts[k] for k in sorted(parts)).decode("utf-16-le")
                name = text.split(u"\0", 1)[0].encode("utf-8")
            else:
                base8, ext = e[0:8].rstrip(b" "), e[8:11].rstrip(b" ")
                name = base8 + (b"." + ext if ext else b"")
            parts = {}
            hi, lo = struct.unpack_from("<H", e, 20)[0], struct.unpack_from("<H", e, 26)[0]
            if name not in (b".", b".."):
                out.append((name, attr, (hi << 16) | lo))
        f.seek(fat + cluster * 4)
        cluster = struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF
    return out


def names(f, base, path):
    geo = geometry(f, base)
    cluster = geo[3]
    for part in [p for p in path.split("/") if p]:
        want = part.encode("utf-8")
        found = [c for n, a, c in entries(f, geo, cluster) if n == want and a & 0x10]
        if not found:
            sys.exit("check-names.py: no directory %s" % path)
        cluster = found[0]
    return [n for n, _, _ in entries(f, geo, cluster)]


def main(argv):
    if len(argv) not in (3, 4) or argv[1] != "fat":
        sys.stderr.write("usage: check-names.py fat IMAGE [DIR]\n")
        return 2
    with open(argv[2], "rb") as f:
        for name in names(f, fat_partition(f), argv[3] if len(argv) == 4 else ""):
            print(binascii.hexlify(name).decode())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
