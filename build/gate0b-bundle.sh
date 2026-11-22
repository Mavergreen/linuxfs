#!/bin/sh
# platform: macOS-only -- packages the 10.9 build for a 10.9 host without Linux (Linux, via Docker, makes the images)
#   usage: gate0b-bundle.sh DEST
#          Makes DEST, a self-contained Gate 0b run for a 10.9 machine that has Mavergreen macFUSE but
#          no Linux host beside it:
#          - bin/lklfuse and bin/lklfuse-ops, from build/build-lkl-darwin.sh's output;
#          - gate0b-darwin.sh and run.sh;
#          - images/*.img.gz, made by Linux;
#          - README and SHA256SUMS.
#          After the run, tests/gate0b-check-bundle.sh DEST does the Linux checks.
set -eu
[ "$#" -eq 1 ] || { echo "usage: gate0b-bundle.sh DEST" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${GATE0_DARWIN_OUT:-$HOME/Library/Caches/mm-build/linuxfs-gate0/darwin}
D=$1
[ ! -e "$D" ] || { echo "gate0b-bundle.sh: $D exists; pick a new name" >&2; exit 1; }
mkdir -p "$D/bin" "$D/images"
cp "$OUT/lklfuse" "$OUT/tests/lklfuse-ops" "$D/bin/"
cp "$ROOT/tests/gate0b-darwin.sh" "$ROOT/tests/gate0b-run-bundle.sh" "$D/"
mv "$D/gate0b-run-bundle.sh" "$D/run.sh"
cp "$ROOT/tests/gate0b-bundle-README" "$D/README"
sh "$ROOT/build/linux-host.sh" sh -c '
  set -e
  sh "$1/tests/lib/mkimages.sh" --small "$2"
  truncate -s 64M "$2/ops.img" && mkfs.ext4 -q -F "$2/ops.img"
  rm -f "$2/manifest"
  for f in "$2"/*.img; do gzip -9 "$f"; done
' _ "$ROOT" "$D/images"
(cd "$D" && shasum -a 256 bin/* images/* gate0b-darwin.sh run.sh README > SHA256SUMS)
du -sh "$D"
