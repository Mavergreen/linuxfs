#!/bin/sh
# platform: host-agnostic
#   usage: parity-test.sh
#          Tests tests/lib/parity.sh against two temporary directories standing in as volumes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/parity-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
OUT=$T/out; W=$T/w; export OUT W
mkdir -p "$OUT" "$W"

ok() { echo "ok - $*"; }
notok() { echo "not ok - $*"; }
# the smoke's bounded, verbatim in behaviour: tenths of a second, 124 and a "hung:" line
bounded() {
  t=$1; shift
  "$@" & bp=$!
  i=0; while kill -0 "$bp" 2>/dev/null; do
    i=$((i + 1)); test $i -le "$t" || { kill -9 "$bp" 2>/dev/null; echo "hung: $*"; return 124; }
    sleep 0.1
  done
  wait "$bp"
}
. "$here/lib/parity.sh"

fails=0
expect() { # NAME CONDITION-COMMAND...
  n=$1; shift
  if "$@"; then echo "ok - $n"; else echo "not ok - $n"; fails=$((fails + 1)); fi
}
has() { printf '%s\n' "$1" | grep -q -- "$2"; }
hasnt() { ! has "$1" "$2"; }
not() { ! "$@"; }

reset() { # makes two fresh volume directories a and b
  rm -rf "$T/a" "$T/b" "$OUT/parity"
  mkdir -p "$T/a" "$T/b"
}
pair() { parity_pair "${1:-disk2s1}" "$T/a" "${2:-CTL}" fsx "${3:-disk3s1}" "$T/b" "${4:-FSX}"; }

# same_output_ok
reset; touch "$T/a/f" "$T/b/f"; pair
PARITY_MODE_UNICODE=check; export PARITY_MODE_UNICODE
r=$(parity unicode.ls ls @MP@ 2>&1)
expect same_output_ok test "$r" = "ok - parity unicode.ls"

# differ_notok
touch "$T/b/extra"
r=$(parity unicode.ls ls @MP@ 2>&1)
expect differ_notok_verdict has "$r" "^not ok - parity unicode.ls"
expect differ_notok_diff has "$r" "^+extra"

# status_counts
reset; pair
touch "$T/b/flag"
r=$(parity unicode.st test -e @MP@/flag 2>&1)
expect status_counts_verdict has "$r" "^not ok - parity unicode.st"
expect status_counts_diff has "$r" "^[-+].*status"
unset PARITY_MODE_UNICODE

# literal_mp: MP and VOL are text, not patterns
reset; mkdir "$T/a/q" "$T/b/q"
mpa="$T/a/my data (1)"; mpb="$T/b/my data (1)"; mkdir "$mpa" "$mpb"
parity_pair disk2s1 "$mpa" a.b fsx disk3s1 "$mpb" a.b
PARITY_MODE_LIT=record; export PARITY_MODE_LIT
r=$(parity lit.echo echo "@MP@/f" "@VOL@" aXb 2>&1)
expect literal_mp_clean hasnt "$r" "not ok"
want=$(printf '%s\n' '== stdout' '<MP>/f <VOL> aXb' '== stderr' '== status 0')
expect literal_mp_hfs test "$(cat "$OUT/parity/lit.echo.hfs.txt")" = "$want"
expect literal_mp_fs test "$(cat "$OUT/parity/lit.echo.fsx.txt")" = "$want"
unset PARITY_MODE_LIT

# disk_ids
reset
parity_pair disk12s3 "$T/a" CTL fsx disk2s1 "$T/b" FSX
PARITY_MODE_DISK=check; export PARITY_MODE_DISK
r=$(parity disk.ids echo @DISK@ /dev/@DISK@ 2>&1)
expect disk_ids_ok test "$r" = "ok - parity disk.ids"
expect disk_ids_text test "$(echo "disk12s3 disk2s1 disk7 /dev/disk3s1: xdisk5 disk5x" | parity_norm /nowhere NONE)" = "<DISK> <DISK> <DISK> /dev/<DISK>: xdisk5 disk5x"
unset PARITY_MODE_DISK

# record_mode: differing trees, yet recording is not a failure
reset; touch "$T/b/extra"; pair
PARITY_MODE_UNICODE=record; export PARITY_MODE_UNICODE
r=$(parity unicode.ls ls @MP@ 2>&1)
expect record_mode_files test -f "$OUT/parity/unicode.ls.hfs.txt" -a -f "$OUT/parity/unicode.ls.fsx.txt"
expect record_mode_differ not cmp -s "$OUT/parity/unicode.ls.hfs.txt" "$OUT/parity/unicode.ls.fsx.txt"
expect record_mode_quiet test "$r" = "# recorded unicode.ls"
unset PARITY_MODE_UNICODE

# default_record: an item with no mode variable records
reset; pair
r=$(parity never.set ls @MP@ 2>&1)
expect default_record test "$r" = "# recorded never.set"

# timeout: a hung command is status 124 in the record, and check says not ok
reset; pair
PARITY_BOUND=3; PARITY_MODE_HANG=check; export PARITY_BOUND PARITY_MODE_HANG
touch "$T/b/slow"
r=$(parity hang.sleep sh -c 'test ! -e "$1/slow" || sleep 5' sh @MP@ 2>&1)
expect timeout_notok has "$r" "^not ok - parity hang.sleep"
expect timeout_status grep -q '^== status 124$' "$OUT/parity/hang.sleep.fsx.txt"
rm "$T/b/slow"
r=$(parity hang.both sleep 5 2>&1)
expect timeout_both_notok has "$r" "^not ok - parity hang.both"
expect timeout_both_message has "$r" "hang.both timed out"
unset PARITY_BOUND PARITY_MODE_HANG

# stdin: a command reading stdin gets end of file, not the caller's input
reset; pair
r=$(echo typed | parity stdin.cat cat 2>&1)
expect stdin_devnull test "$r" = "# recorded stdin.cat"
expect stdin_empty test "$(cat "$OUT/parity/stdin.cat.hfs.txt")" = "$(printf '%s\n' '== stdout' '== stderr' '== status 0')"

# arguments: an empty one and one with spaces survive the substitution, in order
reset; pair
parity args.printf printf '[%s]' @MP@ "" "a b" @VOL@ >/dev/null 2>&1
expect args_rotation test "$(cat "$OUT/parity/args.printf.hfs.txt")" = "$(printf '%s\n' '== stdout' '[<MP>][][a b][<VOL>]' '== stderr' '== status 0')"

# bad mode
reset; pair
PARITY_MODE_ODD=chekc; export PARITY_MODE_ODD
r=$(parity odd.ls ls @MP@ 2>&1)
expect badmode_notok has "$r" "^not ok - parity odd.ls"
expect badmode_message has "$r" "PARITY_MODE_ODD is 'chekc'"
unset PARITY_MODE_ODD

# WHAT prefix is mapped to a legal variable name
reset; pair
r=$(parity 'we-ird.x' ls @MP@ 2>&1)
expect weird_prefix test "$r" = "# recorded we-ird.x"

# parity_side and parity_shot
shots=$T/shots; : >"$shots"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$shots" >"$T/bin/guest-macosx-aqua"; chmod +x "$T/bin/guest-macosx-aqua"
PATH=$T/bin:$PATH
reset; pair
parity_shot one
parity_side fs
parity_shot two
expect shot_sides test "$(cat "$shots")" = "$(printf '%s\n' "screencapture -x $OUT/hfs-one.png" "screencapture -x $OUT/fsx-two.png")"

# parity_control: unknown kind; the exact steps; made once; a failed mkfile leaves nothing
r=$(parity_control zfs 2>&1); rc=$?
expect control_unknown test "$rc" -eq 2 -a "$r" = "parity_control: unknown kind zfs"
calls=$T/calls; : >"$calls"
mkfile() { echo "mkfile $*" >>"$calls"; test "${MKFILE_FAIL:-}" = 1 && { : >"$2"; return 1; }; : >"$2"; }
hdiutil() { echo "hdiutil $*" >>"$calls"; test "$1" = attach && echo "/dev/disk9          	GUID_partition_scheme"; return 0; }
diskutil() { echo "diskutil $*" >>"$calls"; }
r=$(parity_control hfsx); r2=$(parity_control hfsx)
expect control_path test "$r" = "$W/ctl/hfsx.img" -a "$r2" = "$r"
expect control_steps test "$(cat "$calls")" = "$(printf '%s\n' "mkfile 128m $W/ctl/hfsx.img" "hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage $W/ctl/hfsx.img" "diskutil eraseDisk JHFSX Control GPT disk9" "hdiutil detach disk9")"
MKFILE_FAIL=1; export MKFILE_FAIL
parity_control exfat >/dev/null 2>&1; rc=$?
expect control_mkfile_fails test "$rc" -ne 0 -a ! -e "$W/ctl/exfat.img"
unset MKFILE_FAIL
# a failed attach says why on stderr
hdiutil() { echo "hdiutil: attach failed: resource busy"; return 1; }
r=$(parity_control fat32 2>&1 >/dev/null); rc=$?
expect control_attach_fails test "$rc" -ne 0 -a ! -e "$W/ctl/fat32.img"
expect control_attach_message has "$r" "hdiutil attach of $W/ctl/fat32.img failed: .*resource busy"

test "$fails" -eq 0
