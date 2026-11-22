#!/bin/sh
# platform: host-agnostic
#   usage: derive-upstream-version-test.sh
#          build/derive-upstream-version.sh --source DIR turns an LKL tree into <kernel version>.<commit date>.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(mktemp -d "${TMPDIR:-/tmp}/derive.XXXXXX"); trap 'rm -rf "$D"' EXIT
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
mk() { mkdir -p "$D/$1"; printf '# SPDX\nVERSION = 6\nPATCHLEVEL = 12\n%s\nEXTRAVERSION =\n' "$2" > "$D/$1/Makefile"; TZ=UTC touch -t 202609282144.38 "$D/$1/Makefile"; }
mk good 'SUBLEVEL = 0'
out=$(sh "$ROOT/build/derive-upstream-version.sh" --source "$D/good" 2>&1)
[ "$out" = 6.12.0.20260928 ]; ok $? "kernel version and commit date (got '$out')"
mk late 'SUBLEVEL = 3'
TZ=UTC touch -t 202609282359.59 "$D/late/Makefile"
out=$(sh "$ROOT/build/derive-upstream-version.sh" --source "$D/late" 2>&1)
[ "$out" = 6.12.3.20260928 ]; ok $? "the date is UTC, not local (got '$out')"
mk nosub ''
out=$(sh "$ROOT/build/derive-upstream-version.sh" --source "$D/nosub" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q SUBLEVEL; ok $? "a Makefile without SUBLEVEL is refused, naming it"
out=$(sh "$ROOT/build/derive-upstream-version.sh" --source "$D/missing" 2>&1); rc=$?
[ $rc -ne 0 ]; ok $? "a missing tree is refused"
v=$(cat "$ROOT/UPSTREAM_VERSION" 2>/dev/null)
case $v in [0-9]*.[0-9]*.[0-9]*.20[0-9][0-9][01][0-9][0-3][0-9]) r=0 ;; *) r=1 ;; esac
ok $r "the committed UPSTREAM_VERSION has the derived shape (got '$v')"
echo "1..$n"; exit $bad
