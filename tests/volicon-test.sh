#!/bin/sh
# platform: macOS-only -- linuxfs-volicon draws with CoreGraphics and reads and writes .icns with ImageIO, and its base is
#           the Mac's own External.icns
#   usage: volicon-test.sh
#          Builds tools/volicon.c for 10.9 and checks linuxfs-volicon BASE.icns TUX.png OUT.icns (spec: item 6's
#          amendment, the volume icon): from this Mac's External.icns and art/tux.png, and from a base of only three
#          sizes, OUT has every representation BASE has (each size at each DPI, so @2x too), each BASE's own but for Tux
#          in its lower-right corner (tests/volicon-check.c), mode 0644, its read-back check matching the two sets one to
#          one in both directions (tests/volicon-reps.c); misuse is exit 2; any failure (no base, a base
#          that is not an .icns, a Tux that is not an image, a directory that is missing or not writable) exits non-zero
#          and writes nothing: OUT is neither made nor changed, and no temporary file is left.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
EXT=/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/External.icns
[ -f "$EXT" ] || { echo "volicon-test.sh: no $EXT on this Mac" >&2; exit 77; }
D=$HOME/Library/Caches/mm-build/linuxfs-volicon-test; chmod -R u+w "$D" 2>/dev/null; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
cc() { "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld "$@"; }
cc -o "$D/volicon" "$ROOT/tools/volicon.c" -framework ApplicationServices -framework CoreFoundation || exit 1
cc -o "$D/check" "$ROOT/tests/volicon-check.c" -framework ApplicationServices -framework CoreFoundation || exit 1
cc -o "$D/reps" "$ROOT/tests/volicon-reps.c" -framework ApplicationServices -framework CoreFoundation || exit 1
# spec: tools/volicon.c TUX_EDGE, TUX_INSET -- Tux's box is 45% of the icon's edge, 6% in from the right and the bottom
EDGE=0.45 INSET=0.06
TUX=$ROOT/art/tux.png
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
checked() { # BASE OUT WHAT: volicon-check's lines, numbered here
  "$D/check" "$1" "$2" $EDGE $INSET > "$D/check.out" 2>&1; rc=$?
  [ -s "$D/check.out" ] || echo "not ok - volicon-check said nothing (exit $rc)" > "$D/check.out"
  while IFS= read -r line; do
    case $line in "ok - "*) ok 0 "$3: ${line#ok - }" ;; "not ok - "*) ok 1 "$3: ${line#not ok - }" ;; *) ok 1 "$3: $line" ;; esac
  done < "$D/check.out"
}
leftovers() { ls -A "$1" | grep -v "^$2\$" | grep -c .; }

# the read-back check: BASE's representations, matched one to one both ways
"$D/reps" > "$D/reps.out" 2>&1
while IFS= read -r line; do
  case $line in "ok - "*) ok 0 "${line#ok - }" ;; "not ok - "*) ok 1 "${line#not ok - }" ;; *) ok 1 "volicon-reps: $line" ;; esac
done < "$D/reps.out"
"$D/volicon" > "$D/out" 2>&1; rc=$?
[ $rc -eq 2 ] && grep -q '^usage: linuxfs-volicon BASE.icns TUX.png OUT.icns' "$D/out"; ok $? "no arguments: usage, exit 2 (got $rc)"
"$D/volicon" "$EXT" "$TUX" > "$D/out" 2>&1; rc=$?
[ $rc -eq 2 ]; ok $? "two arguments: exit 2 (got $rc)"

mkdir "$D/w"
"$D/volicon" "$EXT" "$TUX" "$D/w/linuxfs.icns" > "$D/out" 2>&1; rc=$?
[ $rc -eq 0 ] && [ -f "$D/w/linuxfs.icns" ]; ok $? "External.icns and Tux make linuxfs.icns (got $rc: $(cat "$D/out"))"
[ "$(stat -f %Lp "$D/w/linuxfs.icns" 2>/dev/null)" = 644 ]; ok $? "it is 0644: readable by every lklfuse, writable by no one else (got $(stat -f %Lp "$D/w/linuxfs.icns" 2>/dev/null))"
[ "$(leftovers "$D/w" linuxfs.icns)" = 0 ]; ok $? "no temporary file is left beside it"
checked "$EXT" "$D/w/linuxfs.icns" External.icns
cp "$D/w/linuxfs.icns" "$D/first.icns"
"$D/volicon" "$EXT" "$TUX" "$D/w/linuxfs.icns" > "$D/out" 2>&1; rc=$?
[ $rc -eq 0 ] && cmp -s "$D/w/linuxfs.icns" "$D/first.icns"; ok $? "made again over the old one: replaced, the same bytes (got $rc)"

# a base with only three sizes, one of them @2x: the composite has those three, no more
mkdir "$D/three.iconset" "$D/all.iconset"
iconutil -c iconset -o "$D/all.iconset" "$EXT" || exit 1
for f in icon_16x16.png icon_32x32@2x.png icon_512x512.png; do cp "$D/all.iconset/$f" "$D/three.iconset/"; done
iconutil -c icns -o "$D/three.icns" "$D/three.iconset" 2>/dev/null || exit 1
"$D/volicon" "$D/three.icns" "$TUX" "$D/w/three-out.icns" > "$D/out" 2>&1; rc=$?
[ $rc -eq 0 ]; ok $? "a base of three sizes makes a composite (got $rc: $(cat "$D/out"))"
checked "$D/three.icns" "$D/w/three-out.icns" "three sizes"

# failures: non-zero, and nothing written
"$D/volicon" "$D/nonexistent.icns" "$TUX" "$D/w/none.icns" > "$D/out" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$D/w/none.icns" ]; ok $? "a missing base: non-zero, nothing written (got $rc)"
"$D/volicon" "$TUX" "$TUX" "$D/w/none.icns" > "$D/out" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$D/w/none.icns" ]; ok $? "a base that is a PNG, not an .icns: non-zero, nothing written (got $rc)"
printf 'not an image\n' > "$D/text.png"
"$D/volicon" "$EXT" "$D/text.png" "$D/w/linuxfs.icns" > "$D/out" 2>&1; rc=$?
[ $rc -ne 0 ] && cmp -s "$D/w/linuxfs.icns" "$D/first.icns"; ok $? "a Tux that is not an image: non-zero, the old icon untouched (got $rc)"
"$D/volicon" "$EXT" "$D/nonexistent.png" "$D/w/linuxfs.icns" > "$D/out" 2>&1; rc=$?
[ $rc -ne 0 ] && cmp -s "$D/w/linuxfs.icns" "$D/first.icns"; ok $? "a missing Tux: non-zero, the old icon untouched (got $rc)"
grep -q 'linuxfs-volicon: ' "$D/out"; ok $? "and it says why (got: $(cat "$D/out"))"
"$D/volicon" "$EXT" "$TUX" "$D/nodir/linuxfs.icns" > "$D/out" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$D/nodir" ]; ok $? "a missing directory: non-zero, nothing made (got $rc)"
mkdir "$D/ro"; cp "$D/first.icns" "$D/ro/linuxfs.icns"; chmod 555 "$D/ro"
"$D/volicon" "$EXT" "$TUX" "$D/ro/linuxfs.icns" > "$D/out" 2>&1; rc=$?
[ $rc -ne 0 ] && cmp -s "$D/ro/linuxfs.icns" "$D/first.icns" && [ "$(leftovers "$D/ro" linuxfs.icns)" = 0 ]
ok $? "a directory it cannot write: non-zero, the old icon untouched (got $rc)"
chmod 755 "$D/ro"
[ "$(leftovers "$D/w" 'linuxfs.icns\|three-out.icns')" = 0 ]; ok $? "after the failures, no temporary file is left ($(ls -A "$D/w" | tr '\n' ' '))"

echo "1..$n"
[ $bad -eq 0 ] && rm -rf "$D"
exit $bad
