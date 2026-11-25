#!/usr/bin/env python3
# platform: Linux -- python3 only (the fsck job, after the guest)
#   usage: python3 -I check-names.py fat IMAGE [DIR]
#          Prints, one per line in directory order, each name in DIR (a /-separated path from the root; default the
#          root) of IMAGE's FAT32 partition as the hex of its UTF-8 bytes, decoded from the long-name entries (UTF-16);
#          a name with no long-name entry is its 8.3 short name. The partition is the GPT entry of the Microsoft basic
#          data type, not "partition 1", in case diskutil eraseDisk adds an EFI partition (also FAT) before it. Exits 1
#          when there is no such partition or DIR.
#          python3 -I check-names.py fat IMAGE --nfc PATH...
#          python3 -I check-names.py ext4 IMAGE [--kept PATH]... PATH...
#          Asserts names on disk, one TAP line ("ok - ..." or "not ok - ...") per PATH; exits 1 when any is not ok.
#          Each PATH is the hex of its UTF-8 bytes ("/" is 2f), as the smoke wrote it (either form). Its directories are
#          found by their exact bytes; its last component must be on disk as exactly one entry of that name in any
#          form (compared by NFC), and that entry's bytes must be the name's NFC. --kept PATH instead asserts that an
#          entry of exactly PATH's bytes is still there (a Linux-made name in some other form, left as it was). ext4's
#          names are read with debugfs -R 'ls -p DIR' (Linux's e2fsprogs; the build container has it), FAT32's as
#          above. NFC is Python's unicodedata, which for these names is the same as lklfuse's (patch 0012).
import binascii
import struct
import subprocess
import sys
import unicodedata
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


def fat_lister(image):
    def ls(d):
        with open(image, "rb") as f:
            base = fat_partition(f)
            geo = geometry(f, base)
            cluster = geo[3]
            for part in [p for p in d.split(b"/") if p]:
                found = [c for n, a, c in entries(f, geo, cluster) if n == part and a & 0x10]
                if not found:
                    return None
                cluster = found[0]
            return [n for n, _, _ in entries(f, geo, cluster)]
    return ls


def ext4_lister(image):
    def ls(d):
        r = subprocess.run(["debugfs", "-R", b"ls -p /" + d, image], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # one line per entry, raw bytes: /inode/mode/uid/gid/name/size/ (a name holds no "/"); a missing directory
        # gives none (not even "." and ".."), and says so on stderr
        rows = [f for f in (line.split(b"/") for line in r.stdout.split(b"\n")) if len(f) == 8 and f[0] == f[7] == b""]
        if r.returncode != 0 or not rows:
            return None
        return [f[5] for f in rows if f[5] not in (b".", b"..")]
    return ls


def nfc(b):
    return unicodedata.normalize("NFC", b.decode("utf-8")).encode("utf-8")


def show(b):
    return "%s (%s)" % (b.decode("utf-8", "replace"), binascii.hexlify(b).decode())


def verdict(ls, path, kept):
    d, _, leaf = path.rpartition(b"/")
    there = ls(d)
    if there is None:
        return False, "%s: no directory /%s" % (show(path), d.decode("utf-8", "replace"))
    if kept:
        if leaf in there:
            return True, "%s is on disk as it was" % show(path)
        return False, "%s is not on disk in that form" % show(path)
    try:
        want = nfc(leaf)
        same = [n for n in there if nfc(n) == want]
    except UnicodeDecodeError:
        return False, "%s is not UTF-8" % show(path)
    if not same:
        return False, "%s: no entry of that name, in any form (a name that was written, but is not on disk)" % show(path)
    if same != [want]:
        return False, "%s is on disk as %s, not as its NFC %s only" % (
            show(path), ", ".join(binascii.hexlify(n).decode() for n in same), binascii.hexlify(want).decode())
    return True, "%s is on disk as its NFC %s" % (show(path), binascii.hexlify(want).decode())


def check(ls, args):
    bad, kept = 0, False
    for a in args:
        if a == "--kept":
            kept = True
            continue
        ok, what = verdict(ls, binascii.unhexlify(a), kept)
        kept = False
        print("%s - %s" % ("ok" if ok else "not ok", what))
        bad += not ok
    return 1 if bad else 0


USAGE = "usage: check-names.py fat IMAGE [DIR]\n" \
        "       check-names.py fat IMAGE --nfc PATH...\n" \
        "       check-names.py ext4 IMAGE [--kept PATH]... PATH...\n"


def main(argv):
    if len(argv) >= 5 and argv[1] == "fat" and argv[3] == "--nfc" and "--kept" not in argv[4:]:
        return check(fat_lister(argv[2]), argv[4:])
    if len(argv) >= 4 and argv[1] == "ext4" and argv[-1] != "--kept":
        return check(ext4_lister(argv[2]), argv[3:])
    if len(argv) not in (3, 4) or argv[1] != "fat":
        sys.stderr.write(USAGE)
        return 2
    d = argv[3] if len(argv) == 4 else ""
    found = fat_lister(argv[2])(d.encode("utf-8"))
    if found is None:
        sys.exit("check-names.py: no directory %s" % d)
    for name in found:
        print(binascii.hexlify(name).decode())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
