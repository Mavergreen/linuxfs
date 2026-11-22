#!/bin/sh
# platform: macOS-only -- checks, with Linux via build/linux-host.sh, a Gate 0b bundle after its run
#   usage: gate0b-check-bundle.sh DIR
#          For every DIR/run-*/snapshots/N-FS-WHAT.img.gz the 10.9 run left, does the Linux check it
#          stands for: WHAT=clean means check-fs.sh must pass; needs-replay means the ext4 journal must
#          still need replaying. Prints TAP; exits 0 only if every snapshot shows what it should.
set -u
[ "$#" -eq 1 ] || { echo "usage: gate0b-check-bundle.sh DIR" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(cd "$1" && pwd)
ls "$D"/run-*/snapshots/*.img.gz > /dev/null 2>&1 || { echo "gate0b-check-bundle.sh: no snapshots in $D" >&2; exit 1; }
sh "$ROOT/build/linux-host.sh" sh -c '
  n=0 bad=0
  for z in "$2"/run-*/snapshots/*.img.gz; do
    n=$((n + 1))
    mode=$(basename "$(dirname "$(dirname "$z")")"); base=$(basename "$z" .img.gz)
    fs=$(echo "$base" | cut -d- -f2); what=$(echo "$base" | cut -d- -f3-)
    img=/work/tmp/check-$$.img
    gunzip -c "$z" > "$img"
    case $what in
    clean) sh "$1/tests/lib/check-fs.sh" "$fs" "$img" > "$z.check.log" 2>&1 ;;
    needs-replay) dumpe2fs -h "$img" 2>/dev/null | grep -q needs_recovery ;;
    *) false ;;
    esac
    if [ $? -eq 0 ]; then echo "ok $n - $mode: $base"; else echo "not ok $n - $mode: $base"; bad=1; fi
    rm -f "$img"
  done
  echo "1..$n"
  exit $bad
' _ "$ROOT" "$D"
