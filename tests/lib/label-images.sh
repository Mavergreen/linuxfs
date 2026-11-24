#!/bin/sh
# platform: host-agnostic
#   usage: label-images.sh DIR
#          Makes two small ext4 images whose labels DiskArbitration must not turn into a path: ext4-slash.img ("a/b") and
#          ext4-ctl.img (a control character inside). Linux only. Exits 0 without the image if mkfs.ext4 refuses the label.
set -u
[ "$(uname -s)" = Linux ] || { echo "label-images.sh: needs Linux's mkfs tools" >&2; exit 77; }
cd "$1" || exit 1
for c in slash:'a/b' ctl:"$(printf 'x\001y')"; do
  truncate -s 64M "ext4-${c%%:*}.img"
  mkfs.ext4 -q -F -L "${c#*:}" "ext4-${c%%:*}.img" > /dev/null 2>&1 || { echo "label-images.sh: no ext4-${c%%:*}.img: mkfs.ext4 refused the label" >&2; rm -f "ext4-${c%%:*}.img"; }
done
exit 0
