#!/bin/sh
# platform: host-agnostic
#   usage: unicode-images.sh DIR
#          Makes DIR/ext4-names.img, an ext4 image (mkfs.ext4 -d) of names made on Linux, for census_unicode to open from
#          the Mac by both forms: caf\xc3\xa9 (NFC), nai\xcc\x88ve (NFD), and pair/ holding caf\xc3\xa9 and cafe\xcc\x81
#          (both forms of one name). Each file holds its own name. Linux only (exits 77 elsewhere).
set -u
[ "$(uname -s)" = Linux ] || { echo "unicode-images.sh: needs Linux's mkfs.ext4" >&2; exit 77; }
mkdir -p "$1" && cd "$1" || exit 1
# platform: the tree is staged under TMPDIR, never the shared tree: on a Mac host that is HFS+, which would fold the pair into one
t=$(mktemp -d "${TMPDIR:-/tmp}/unicode-images.XXXXXX") || exit 1
trap 'rm -rf "$t"' EXIT
mkdir "$t/pair" || exit 1
for f in "$(printf 'caf\303\251')" "$(printf 'nai\314\210ve')" "pair/$(printf 'caf\303\251')" "pair/$(printf 'cafe\314\201')"; do
  printf '%s' "${f#pair/}" > "$t/$f" || exit 1
done
rm -f ext4-names.img
truncate -s 64M ext4-names.img && mkfs.ext4 -q -F -L names -d "$t" ext4-names.img > /dev/null || { rm -f ext4-names.img; exit 1; }
