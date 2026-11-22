#!/bin/sh
# platform: host-agnostic
#   usage: derive-upstream-version.sh [--source DIR]
#          linuxfs's upstream version, <VERSION>.<PATCHLEVEL>.<SUBLEVEL>.<YYYYMMDD>: the kernel version in the
#          pinned LKL tree's Makefile and the commit's UTC date. LKL has no release tags, so the version is
#          derived from the pin (components/lkl/version), never typed. With --source, prints the value for
#          that unpacked tree; without, fetches the pinned tarball (unpatched) and writes UPSTREAM_VERSION.
#          Runs before anything else in a build reads the version.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "derive-upstream-version.sh: $*" >&2; exit 1; }
derive() {
  mk=$1/Makefile
  [ -f "$mk" ] || die "no Makefile in $1"
  v=
  for k in VERSION PATCHLEVEL SUBLEVEL; do
    x=$(sed -n "s/^$k[ 	]*=[ 	]*\([0-9][0-9]*\)[ 	]*$/\1/p" "$mk" | head -n 1)
    [ -n "$x" ] || die "$mk has no numeric $k"
    v=$v$x.
  done
  # platform: GitHub's commit tarballs stamp every file with the commit time; BSD stat/date (10.9) and GNU differ.
  # platform: GNU's stat first: BSD's refuses -c, but GNU's takes -f (filesystem status) and prints that instead of failing
  e=$(stat -c %Y "$mk" 2>/dev/null || stat -f %m "$mk")
  d=$(date -u -r "$e" +%Y%m%d 2>/dev/null || date -u -d "@$e" +%Y%m%d)
  echo "$v$d"
}
if [ "${1:-}" = --source ]; then
  [ $# -eq 2 ] || { echo "usage: derive-upstream-version.sh [--source DIR]" >&2; exit 2; }
  derive "$2"; exit 0
fi
[ $# -eq 0 ] || { echo "usage: derive-upstream-version.sh [--source DIR]" >&2; exit 2; }
. "$ROOT/build/msc.sh"
pin=$ROOT/components/lkl/version
val() { sed -n "s/^$1=//p" "$pin"; }
W=$(mktemp -d "${TMPDIR:-/tmp}/lkl-version.XXXXXX"); trap 'rm -rf "$W"' EXIT
sh "$SHIPYARD_SCRIPTS/fetch_pinned_source.sh" "$(val REPO)" "$(val DIGEST)" "$(val TARBALL_SHA256)" "$W/src" >&2
v=$(derive "$W/src")
echo "$v" > "$ROOT/UPSTREAM_VERSION"
echo "derived UPSTREAM_VERSION=$v from LKL $(val DIGEST)" >&2
