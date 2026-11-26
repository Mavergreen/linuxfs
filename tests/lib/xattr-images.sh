#!/bin/sh
# platform: host-agnostic -- Linux only (mkfs.ext4 -d, debugfs, python3); exits 77 elsewhere
#   usage: xattr-images.sh DIR
#          Makes four ext4 images in DIR, each with a file f whose Finder Info and Finder tag are stored in one Mac-xattr
#          scheme (spec: item 7; item-7-findings.md "Step 0" has the encodings, from netatalk's and Samba's sources):
#            ext4-xa-ours.img      linuxfs's own: f has user.com.apple.FinderInfo and user.com.apple.metadata:_kMDItemUserTags
#            ext4-xa-netatalk.img  netatalk's (and Samba vfs_fruit's fruit:metadata=netatalk): f's Finder Info is in the
#                                  AppleDouble blob user.org.netatalk.Metadata (402 bytes, Finder Info at 122), its tag in
#                                  user.com.apple.metadata:_kMDItemUserTags
#            ext4-xa-fruit.img     Samba vfs_fruit's fruit:metadata=stream over streams_xattr: f's Finder Info is in the
#                                  AFP_AfpInfo stream (user.DosStream.AFP_AfpInfo:$DATA, 60 bytes and streams_xattr's 0
#                                  byte, Finder Info at 16), its tag in the stream user.DosStream.com.apple.metadata
#                                  U+F022 _kMDItemUserTags:$DATA (the Mac's SMB client sends ':' as U+F022)
#            ext4-xa-mixed.img     f as on the netatalk image, o as on the ours image, s as on the fruit image
#          The Finder Info planted is type TEXT, creator ttxt and no label; the tag planted is the bplist ["Planted"]. So
#          a label or tag set later from the Mac shows as a change, and type and creator kept show it changed in place
#          (tests/lib/check-xattrs.sh). The xattrs are written with debugfs, so nothing is mounted.
set -u
[ "$(uname -s)" = Linux ] || { echo "xattr-images.sh: needs Linux's mkfs.ext4 and debugfs" >&2; exit 77; }
[ "$#" -eq 1 ] || { echo "usage: xattr-images.sh DIR" >&2; exit 2; }
mkdir -p "$1" && cd "$1" || exit 1
t=$(mktemp -d "${TMPDIR:-/tmp}/xattr-images.XXXXXX") || exit 1
trap 'rm -rf "$t"' EXIT
# the values: fi (32 bytes), blob (netatalk's 402), afp (AfpInfo, 60 + 1), tag (bplist), tag0 (bplist + 1)
python3 -I - "$t" <<'EOF' || exit 1
import plistlib, struct, sys
d = sys.argv[1]
fi = b"TEXTttxt" + bytes(24)
# netatalk's AD_VERSION_EA metadata blob as ad_rebuild_adouble_header_ea writes it: magic, version 2, a zero filler,
# 8 entries in entry-id order, then the data: Finder Info 122/32, comment 154/200, dates 354/16, AFP file info 370/4,
# and the private dev/ino/syn/id 374/8, 382/8, 390/8, 398/4
ents = [(4, 154, 200), (8, 354, 16), (9, 122, 32), (14, 370, 4),
        (0x80444556, 374, 8), (0x80494E4F, 382, 8), (0x8053594E, 390, 8), (0x8053567E, 398, 4)]
blob = bytearray(402)
struct.pack_into(">II16xH", blob, 0, 0x00051607, 0x00020000, len(ents))
for i, e in enumerate(ents):
    struct.pack_into(">III", blob, 26 + 12 * i, *e)
blob[122:154] = fi
# dates (seconds since 2000, big-endian): create, modify, backup (never: 0x80000000), access
struct.pack_into(">IIII", blob, 354, 0x2e000000, 0x2e000000, 0x80000000, 0x2e000000)
afp = bytearray(60)
struct.pack_into(">II4xI", afp, 0, 0x41465000, 0x00000100, 0x80000000)
afp[16:48] = fi
tag = plistlib.dumps(["Planted"], fmt=plistlib.FMT_BINARY)
for name, v in (("fi", fi), ("blob", bytes(blob)), ("afp", bytes(afp) + b"\0"), ("tag", tag), ("tag0", tag + b"\0")):
    open(d + "/" + name, "wb").write(v)
EOF
colon=$(printf '\357\200\242')
ours() { printf '%s\n' "ea_set -f $t/fi /$1 user.com.apple.FinderInfo" "ea_set -f $t/tag /$1 user.com.apple.metadata:_kMDItemUserTags"; }
netatalk() { printf '%s\n' "ea_set -f $t/blob /$1 user.org.netatalk.Metadata" "ea_set -f $t/tag /$1 user.com.apple.metadata:_kMDItemUserTags"; }
fruit() { printf '%s\n' "ea_set -f $t/afp /$1 user.DosStream.AFP_AfpInfo:\$DATA" "ea_set -f $t/tag0 /$1 user.DosStream.com.apple.metadata${colon}_kMDItemUserTags:\$DATA"; }
for s in ours netatalk fruit mixed; do
  img=ext4-xa-$s.img
  rm -rf "$t/root" && mkdir "$t/root" || exit 1
  case $s in
    mixed) files="f o s"; { netatalk f; ours o; fruit s; } > "$t/cmd" ;;
    *) files=f; $s f > "$t/cmd" ;;
  esac
  for f in $files; do printf '%s\n' "$f" > "$t/root/$f" || exit 1; done
  rm -f "$img"
  truncate -s 16M "$img" && mkfs.ext4 -q -F -L "xa-$s" -d "$t/root" "$img" > /dev/null || { rm -f "$img"; exit 1; }
  debugfs -w -f "$t/cmd" "$img" > "$t/out" 2>&1 || { cat "$t/out" >&2; rm -f "$img"; exit 1; }
  # debugfs says a failed ea_set but still exits 0
  if grep -q -i 'error\|invalid\|not found\|usage' "$t/out"; then cat "$t/out" >&2; rm -f "$img"; exit 1; fi
done
