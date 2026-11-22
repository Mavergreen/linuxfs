#!/bin/sh
# platform: macOS-only -- checks, with Linux via build/linux-host.sh, the images a P3 bundle run left
#   usage: p3-check-bundle.sh DIR [BUNDLE]
#          DIR is the run's results (out/ in it); BUNDLE, the bundle it ran, whose images/ the read-only images are
#          compared with (default DIR, when it is the bundle itself). For every DIR/out/PART-FS[-WHAT].img.gz tests/p3-darwin.sh left, runs Linux's own checker
#          (tests/lib/check-fs.sh) read-only: each must be clean, the yanked one included (the journal
#          may need replaying there, which Linux would do; it must not be corrupt). Prints TAP.
set -u
[ "$#" -eq 1 ] || [ "$#" -eq 2 ] || { echo "usage: p3-check-bundle.sh DIR [BUNDLE]" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(cd "$1" && pwd)
I=$(cd "${2:-$1}" && pwd)/images
[ -f "$I/apfs.img.gz" ] && [ -f "$I/enc.img.gz" ] || { echo "p3-check-bundle.sh: no bundle images in $I (name the bundle: p3-check-bundle.sh DIR BUNDLE)" >&2; exit 2; }
ls "$D"/out/*.img.gz > /dev/null 2>&1 || { echo "p3-check-bundle.sh: no images in $D/out" >&2; exit 1; }
sh "$ROOT/build/linux-host.sh" sh -c '
  n=0 bad=0
  for z in "$2"/out/*.img.gz; do
    n=$((n + 1)); base=$(basename "$z" .img.gz); fs=$(echo "$base" | cut -d- -f2)
    img=/work/tmp/p3-$$.img; mkdir -p /work/tmp; gunzip -c "$z" > "$img"
    case $base in
    *-yanked) e2fsck -fn "$img" > "$z.check.log" 2>&1 ;;
    a-apfsrw) sh "$1/tests/lib/check-fs.sh" apfs "$img" > "$z.check.log" 2>&1 ;;
    a-enc) gunzip -c "$3/enc.img.gz" | cmp - "$img" > "$z.check.log" 2>&1 ;;  # read-only, and Linux has no checker for encrypted APFS: not one byte changed
    a-apfs) { gunzip -c "$3/apfs.img.gz" | cmp - "$img" && sh "$1/tests/lib/check-fs.sh" apfs "$img"; } > "$z.check.log" 2>&1 ;;  # read-only: not one byte changed
    *) sh "$1/tests/lib/check-fs.sh" "$fs" "$img" > "$z.check.log" 2>&1 ;;
    esac
    if [ $? -eq 0 ]; then echo "ok $n - $base"; else echo "not ok $n - $base (see $z.check.log)"; bad=1; fi
    rm -f "$img"
  done
  echo "1..$n"; exit $bad
' _ "$ROOT" "$D" "$I"
