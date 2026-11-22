#!/bin/sh
# platform: macOS-only -- the Gate 0b bundle's entry point, on the 10.9 host with Mavergreen macFUSE
#   usage: sh run.sh            (from the bundle's own directory, as a normal user; no root)
#          Checks SHA256SUMS, then runs gate0b-darwin.sh twice, on image files and on /dev/rdiskN.
#          Writes results.txt (the TAP output of both runs) and leaves run-file/ and run-rdisk/ (logs and
#          image snapshots). Exits 0 only if both runs pass.
set -u
cd "$(dirname "$0")" || exit 1
shasum -a 256 -c SHA256SUMS > sha.log 2>&1 || { echo "run.sh: SHA256SUMS does not match; see sha.log" >&2; exit 1; }
rc=0
: > results.txt
for mode in file rdisk; do
  echo "# mode $mode, started $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> results.txt
  GATE0B_BUNDLE=$PWD GATE0_DEVICE=$mode sh gate0b-darwin.sh > "run-$mode.tap" 2>&1; r=$?
  cat "run-$mode.tap" >> results.txt
  echo "# mode $mode, exit $r, finished $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> results.txt
  [ "$r" -eq 0 ] || rc=1
done
echo "# ok: $(grep -c '^ok' results.txt), not ok: $(grep -c '^not ok' results.txt)" >> results.txt
cat results.txt
exit $rc
