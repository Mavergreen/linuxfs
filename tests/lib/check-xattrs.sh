#!/bin/sh
# platform: host-agnostic -- Linux only (debugfs); exits 77 elsewhere
#   usage: check-xattrs.sh DIR [TAG]
#          DIR holds tests/lib/xattr-images.sh's four images (ext4-xa-ours.img, -netatalk, -fruit, -mixed) after a Mac
#          has written them through linuxfs: the smoke (Task 19) sets a Finder label and the tag TAG (default Parity)
#          on each image's f, on the mixed image's o and s too, and on a file new it makes on the mixed image. Checks,
#          reading the images with debugfs, that each landed in that file's own scheme (spec: item 7; patch 0013):
#            ours      f, mixed o:  user.com.apple.FinderInfo, and the tag in user.com.apple.metadata:_kMDItemUserTags
#            netatalk  f, mixed f:  the Finder Info in the blob user.org.netatalk.Metadata (still 402 bytes, still
#                                   netatalk's header, the Finder Info at 122), the tag in user.com.apple.metadata:...
#            fruit     f, mixed s:  the Finder Info in user.DosStream.AFP_AfpInfo:$DATA (still 60 bytes and the 0 byte,
#                                   still AFP's signature, the Finder Info at 16), the tag in the stream
#                                   user.DosStream.com.apple.metadata U+F022 _kMDItemUserTags:$DATA, ending in 0
#            mixed new:             the volume's scheme, netatalk's (its blob wins at mount)
#          and in every case: a label set (frFlags' colour bits, byte 9 & 0x0E), the planted type and creator (TEXT,
#          ttxt) kept where xattr-images.sh planted them (so the Finder Info was changed in place, not replaced), and no
#          other scheme's Finder Info made beside it. One "ok -" or "not ok -" line per check; exits 1 if any is not ok.
set -u
test "$(uname -s)" = Linux || { echo "check-xattrs.sh: needs Linux's debugfs" >&2; exit 77; }
test "$#" -ge 1 || { echo "usage: check-xattrs.sh DIR [TAG]" >&2; exit 2; }
d=$1 tag=${2:-Parity} rc=0
t=$(mktemp -d "${TMPDIR:-/tmp}/check-xattrs.XXXXXX") || exit 1
trap 'rm -rf "$t"' EXIT
colon=$(printf '\357\200\242')
FI=user.com.apple.FinderInfo META=user.org.netatalk.Metadata AFPI='user.DosStream.AFP_AfpInfo:$DATA'
TAGS=user.com.apple.metadata:_kMDItemUserTags TAGS_STREAM="user.DosStream.com.apple.metadata${colon}_kMDItemUserTags:\$DATA"

ok() { echo "ok - $*"; }
nok() { echo "not ok - $*"; rc=1; }
# get IMG FILE NAME: the xattr's value into $t/v; false when FILE has no such xattr (debugfs then leaves an empty
#   file; no value checked here is ever empty)
get() {
  rm -f "$t/v"
  debugfs -R "ea_get -f $t/v /$2 $3" "$1" > /dev/null 2>&1
  test -s "$t/v"
}
hex() { od -An -tx1 -v -j "$1" -N "$2" "$t/v" | tr -d ' \n'; }
size() { wc -c < "$t/v" | tr -d ' '; }

# finderinfo WHAT OFF PLANTED: the Finder Info at OFF in $t/v has a label, and type and creator kept when PLANTED is 1
finderinfo() {
  b9=$(hex $(($2 + 9)) 1)
  if test $((0x$b9 & 14)) -ne 0; then ok "$1: a label is set (frFlags 0x$(hex $(($2 + 8)) 2))"
  else nok "$1: no label in its Finder Info ($(hex "$2" 32))"; fi
  if test "$3" = 1; then
    if test "$(hex "$2" 8)" = 5445585474747874; then ok "$1: type and creator kept (TEXT ttxt): changed in place"
    else nok "$1: type and creator are $(hex "$2" 8), not TEXT ttxt: replaced, not changed in place"; fi
  fi
}

# check IMG FILE SCHEME PLANTED
check() {
  img=$d/$1 w="$1 /$2 ($3)"
  case $3 in
    ours)
      if get "$img" "$2" "$FI" && test "$(size)" = 32; then ok "$w: Finder Info in $FI"; finderinfo "$w" 0 "$4"
      else nok "$w: no 32-byte $FI"; fi
      tname=$TAGS strip=0 others="$META $AFPI" ;;
    netatalk)
      if get "$img" "$2" "$META" && test "$(size)" = 402 && test "$(hex 0 8)" = 0005160700020000 &&
         test "$(hex 24 2)" = 0008 && test "$(hex 50 12)" = 000000090000007a00000020; then
        ok "$w: Finder Info in the netatalk blob, still 402 bytes in netatalk's layout"; finderinfo "$w" 122 "$4"
      else nok "$w: no netatalk blob of 402 bytes with Finder Info at 122"; fi
      tname=$TAGS strip=0 others="$FI $AFPI" ;;
    fruit)
      if get "$img" "$2" "$AFPI" && test "$(size)" = 61 && test "$(hex 0 8)" = 4146500000000100 && test "$(hex 60 1)" = 00; then
        ok "$w: Finder Info in AFP_AfpInfo, still 60 bytes and the 0 byte"; finderinfo "$w" 16 "$4"
      else nok "$w: no AFP_AfpInfo stream of 60 bytes and a 0 byte"; fi
      tname=$TAGS_STREAM strip=1 others="$FI $META" ;;
  esac
  if get "$img" "$2" "$tname" && grep -q -a -F "$tag" "$t/v"; then
    if test "$strip" = 0 || test "$(hex $(($(size) - 1)) 1)" = 00; then ok "$w: the tag $tag is in its scheme's place"
    else nok "$w: the tag's stream does not end in streams_xattr's 0 byte"; fi
  else nok "$w: no tag $tag where its scheme keeps it"; fi
  for o in $others; do
    if get "$img" "$2" "$o"; then nok "$w: another scheme's carrier $o was made beside it"; fi
  done
}

for i in ours netatalk fruit mixed; do
  test -f "$d/ext4-xa-$i.img" || { nok "ext4-xa-$i.img: not in $d (the guest returned no such image)"; continue; }
  case $i in
    mixed) check ext4-xa-mixed.img f netatalk 1; check ext4-xa-mixed.img o ours 1; check ext4-xa-mixed.img s fruit 1
           check ext4-xa-mixed.img new netatalk 0 ;;
    *) check "ext4-xa-$i.img" f "$i" 1 ;;
  esac
done
exit $rc
