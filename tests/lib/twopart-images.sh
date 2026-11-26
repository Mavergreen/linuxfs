#!/bin/sh
# platform: host-agnostic
#   usage: twopart-images.sh DIR
#          Makes gpt2-ext4.img: one GPT disk with two Linux-data partitions, ext4 "part one" (s1) and ext4 "part two" (s2),
#          each its own filesystem UUID, for the smoke's sibling-partition check (final review C1: both mount at once).
#          Linux only (mkfs.ext4); tests/lib/gpt-wrap.py lays out the disk.
set -u
test "$(uname -s)" = Linux || { echo "twopart-images.sh: needs Linux's mkfs tools" >&2; exit 77; }
here=$(cd "$(dirname "$0")" && pwd)
cd "$1" || exit 1
linux=0FC63DAF-8483-4772-8E79-3D69D8477DE4
for p in one two; do
  truncate -s 64M "ext4-part-$p.img" && mkfs.ext4 -q -F -L "part $p" "ext4-part-$p.img" || exit 1
done
python3 -I "$here/gpt-wrap.py" ext4-part-one.img gpt2-ext4.img "$linux" ext4-part-two.img "$linux" || exit 1
rm -f ext4-part-one.img ext4-part-two.img
