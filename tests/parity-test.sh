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
# the same, kept under its own name: the census_dry section below swaps bounded for a stand-in that only marks what it runs, and
#   the cases that need a real bound (a wait that must time out) put this one back in a subshell
bounded_real() {
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
has() { printf '%s\n' "$1" | grep -- "$2" >/dev/null; }
hasnt() { ! has "$1" "$2"; }
not() { ! "$@"; }
ascending() { # N...: every N given, each less than the next
  _ap=
  for _an; do test -n "$_an" || return 1; test -z "$_ap" || test "$_ap" -lt "$_an" || return 1; _ap=$_an; done
}

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

# expect_ok: equal failures on both sides are parity (error parity), but not for a step that must work on HFS+
#   (parity_ok): there the control's failing is not ok, said, whatever the other side did
reset; pair
PARITY_MODE_EOK=check; export PARITY_MODE_EOK
r=$(parity eok.plain sh -c 'echo no; exit 3' 2>&1)
expect error_parity_ok test "$r" = "ok - parity eok.plain"
r=$(parity_ok eok.fails sh -c 'echo no; exit 3' 2>&1)
expect expect_ok_status_notok has "$r" "^not ok - parity eok.fails"
expect expect_ok_status_said has "$r" "^parity: eok.fails failed on the HFS+ control (status 3), so it proves nothing$"
r=$(parity_ok eok.errno sh -c 'echo 636166c3a9 errno 2; echo 6e61 ok 6e61' 2>&1)
expect expect_ok_errno_notok has "$r" "^parity: eok.errno failed on the HFS+ control (1 names failed), so it proves nothing$"
r=$(parity_ok eok.fine sh -c 'echo 636166c3a9 ok 63' 2>&1)
expect expect_ok_fine test "$r" = "ok - parity eok.fine"
r=$(parity eok.after sh -c 'exit 3' 2>&1)
expect expect_ok_resets test "$r" = "ok - parity eok.after"
unset PARITY_MODE_EOK

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

# aqua_default: with no AQUA, parity.sh calls the helper by the guest's absolute path (it is not on the ssh PATH)
r=$(unset AQUA; . "$here/lib/parity.sh"; echo "$AQUA")
expect aqua_default test "$r" = /usr/local/bin/guest-macosx-aqua
# aqua_never_bare: no code line of parity.sh calls guest-macosx-aqua by its bare name
r=$(grep -n 'guest-macosx-aqua' "$here/lib/parity.sh" | grep -v '^[0-9]*: *#' | grep -v '/usr/local/bin/guest-macosx-aqua')
expect aqua_never_bare test -z "$r"
test -z "$r" || printf '%s\n' "$r" | sed 's/^/# /'

# parity_side and parity_shot (the aqua helper off PATH, as in the guest's ssh session: by $AQUA alone)
shots=$T/shots; : >"$shots"
mkdir -p "$T/bin" "$T/aqua"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$shots" >"$T/aqua/guest-macosx-aqua"; chmod +x "$T/aqua/guest-macosx-aqua"
AQUA=$T/aqua/guest-macosx-aqua
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
# control_names: each kind's volume name is one diskutil takes (FAT32: upper case, at most 11 characters)
for k in hfs fat32 exfat; do rm -f "$W/ctl/$k.img"; parity_control "$k" >/dev/null 2>&1; done
for k in JHFS+ JHFSX ExFAT; do expect "control_name_$k" grep -q "^diskutil eraseDisk $k Control GPT disk9$" "$calls"; done
expect control_name_FAT32 grep -Eq '^diskutil eraseDisk FAT32 [A-Z0-9_]{1,11} GPT disk9$' "$calls"
rm -f "$W/ctl/hfs.img" "$W/ctl/fat32.img" "$W/ctl/exfat.img"
MKFILE_FAIL=1; export MKFILE_FAIL
parity_control exfat >/dev/null 2>&1; rc=$?
expect control_mkfile_fails test "$rc" -ne 0 -a ! -e "$W/ctl/exfat.img"
unset MKFILE_FAIL
# a warning on stderr ahead of the /dev line does not fail the attach
hdiutil() { echo "$1: warning: something odd" >&2; test "$1" = attach && echo "/dev/disk9          	GUID_partition_scheme"; return 0; }
: >"$calls"
r=$(parity_control fat32 2>/dev/null)
expect control_warning_first test "$r" = "$W/ctl/fat32.img"
rm -f "$W/ctl/fat32.img"
# a failed attach says why on stderr
hdiutil() { echo "hdiutil: attach failed: resource busy"; return 1; }
r=$(parity_control fat32 2>&1 >/dev/null); rc=$?
expect control_attach_fails test "$rc" -ne 0 -a ! -e "$W/ctl/fat32.img"
expect control_attach_message has "$r" "hdiutil attach of $W/ctl/fat32.img failed: .*resource busy"

# fisher_values: fisher.py's two-sided p to 4 places, under every Python found (2.7 in the guest, 3 on Linux)
pys=
for py in /usr/bin/python python3; do command -v "$py" > /dev/null 2>&1 && pys="$pys $py"; done
test -n "$pys" || echo "ok - fisher_values # SKIP no python here"
for py in $pys; do
  r=$(for t in "12 38 12 38" "13 37 4 46" "5 45 0 50" "10 40 0 50"; do "$py" "$here/lib/fisher.py" $t; done 2>&1)
  expect "fisher_values ($py)" test "$r" = "$(printf '%s\n' 1.0000 0.0310 0.0563 0.0012)"
  r=$("$py" "$here/lib/fisher.py" 1 2 3 2>&1); rc=$?
  expect "fisher_usage ($py)" test "$rc" -eq 2 -a -n "$r"
done

# probe_times: from DiskArbitration's debug log, each attached disk's first probe success per node, seconds after "created disk"
cat > "$T/dalog" <<'EOF'
23:59:58   created disk, id = /dev/disk3.
23:59:58   created disk, id = /dev/disk3s1.
23:59:59   probed disk, id = /dev/disk3s1, with macfuse_apfs, ongoing.
23:59:59   probed disk, id = /dev/disk3s1, with macfuse_apfs, failure.
00:00:01   probed disk, id = /dev/disk3s1, with hfs, success.
00:00:02   probed disk, id = /dev/disk3s1, with hfs, success.
00:00:02   created disk, id = /Volumes/Control?owner=501.
00:00:05   created disk, id = /dev/disk4.
00:00:05   probed disk, id = /dev/disk4, with macfuse_ext4, failure.
00:00:09   created disk, id = /dev/disk5.
EOF
r=$(census_probe_times < "$T/dalog")
expect probe_times test "$r" = "$(printf '%s\n' 'disk3s1 hfs 3s' 'disk4 none' 'disk5 none')"

# fat_names: check-names.py fat reads FAT32 long names (UTF-16) from the FAT partition, found by its type GUID: the root's, and
#   those in a named subdirectory (census_unicode writes in uni-fat32)
if test "$(uname -s)" = Linux && command -v mkfs.vfat > /dev/null 2>&1 && command -v python3 > /dev/null 2>&1; then
  truncate -s 64M "$T/fat.img" && mkfs.vfat -F 32 -S 512 -s 1 "$T/fat.img" > /dev/null
  python3 -I - "$T/fat.img" <<'EOF'
import struct, sys
def lfn_pair(longname, short, attr, cluster):
    s = 0
    for c in bytearray(short):
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    name = longname.encode("utf-16-le") + b"\0\0"
    name += b"\xff" * (26 - len(name))
    lfn = struct.pack("<B10sBBB12sH4s", 0x41, name[:10], 0x0F, 0, s, name[10:22], 0, name[22:26])
    return lfn + struct.pack("<11sBBBHHHHHHHI", short, attr, 0, 0, 0, 0, 0, 0, 0, 0, cluster, 0)
with open(sys.argv[1], "r+b") as f:
    bs = f.read(512)
    bps, spc, rsv, nfats = struct.unpack_from("<HBHB", bs, 11)
    fatsz, = struct.unpack_from("<I", bs, 36)
    rootc, = struct.unpack_from("<I", bs, 44)
    data = (rsv + nfats * fatsz) * bps
    for i in range(nfats):                  # cluster 3, the subdirectory, ends its chain
        f.seek((rsv + i * fatsz) * bps + 3 * 4)
        f.write(struct.pack("<I", 0x0FFFFFFF))
    f.seek(data + (rootc - 2) * spc * bps)
    f.write(lfn_pair(u"uni-fat32", b"UNI-FA~1   ", 0x10, 3))
    f.seek(data + (3 - 2) * spc * bps)
    f.write(lfn_pair(u"cafe\u0301", b"CAFE~1  TXT", 0x20, 0))
    f.write(lfn_pair(u"na\u00efve", b"NAVE~1  TXT", 0x20, 0))
EOF
  python3 -I "$here/lib/gpt-wrap.py" "$T/fat.img" "$T/gpt-fat.img" EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" 2>&1)
  expect fat_names_root test "$r" = 756e692d6661743332
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" uni-fat32 2>&1)
  expect fat_names test "$r" = "$(printf '%s\n' 63616665cc81 6e61c3af7665)"
  # fat --nfc: what the smoke wrote (either form) is on the FAT32 control as its NFC, or a clear not ok
  uf=756e692d6661743332
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" --nfc "${uf}2f6e6169cc887665" 2>&1); rc=$?
  expect fat_nfc_ok test "$rc" -eq 0 -a "$(printf '%s\n' "$r" | grep -c '^ok - ')" -eq 1
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" --nfc "${uf}2f636166c3a9" 2>&1); rc=$?
  expect fat_nfc_nfd_notok test "$rc" -eq 1
  expect fat_nfc_nfd_says has "$r" "^not ok - .* is on disk as 63616665cc81, not as its NFC 636166c3a9"
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" --nfc "${uf}2f78" 2>&1); rc=$?
  expect fat_nfc_missing test "$rc" -eq 1 -a -n "$(printf '%s\n' "$r" | grep '^not ok - .*no entry')"
  # an image check-names cannot read (no GPT) fails with no "is on disk as" line, which the fsck job blames on msdosfs
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/fat.img" --nfc "${uf}2f636166c3a9" 2>&1); rc=$?
  expect fat_nfc_unreadable test "$rc" -ne 0 -a -z "$(printf '%s\n' "$r" | grep 'is on disk as')"
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" nowhere 2>&1); rc=$?
  expect fat_names_no_dir test "$rc" -ne 0 -a -n "$r"
  python3 -I "$here/lib/gpt-wrap.py" "$T/fat.img" "$T/gpt-linux.img" 0FC63DAF-8483-4772-8E79-3D69D8477DE4
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-linux.img" 2>&1); rc=$?
  expect fat_names_by_type test "$rc" -ne 0 -a -n "$r"
  rm -f "$T/fat.img" "$T/gpt-fat.img" "$T/gpt-linux.img"
else echo "ok - fat_names # SKIP needs Linux, mkfs.vfat and python3"; fi

# unicode_image: unicode-images.sh's ext4-names.img holds both byte forms of one name in /pair, each file holding its name
if test "$(uname -s)" = Linux && command -v mkfs.ext4 > /dev/null 2>&1 && command -v debugfs > /dev/null 2>&1 && command -v python3 > /dev/null 2>&1; then
  sh "$here/lib/unicode-images.sh" "$T/uni" > /dev/null 2>&1
  r=$(debugfs -R 'ls -p /pair' "$T/uni/ext4-names.img" 2> /dev/null)
  expect unicode_image_nfc has "$r" "/$(printf 'caf\303\251')/"
  expect unicode_image_nfd has "$r" "/$(printf 'cafe\314\201')/"
  r=$(debugfs -R 'ls -p /' "$T/uni/ext4-names.img" 2> /dev/null)
  expect unicode_image_root has "$r" "/$(printf 'nai\314\210ve')/"
  r=$(debugfs -R "cat /pair/$(printf 'cafe\314\201')" "$T/uni/ext4-names.img" 2> /dev/null)
  expect unicode_image_content test "$r" = "$(printf 'cafe\314\201')"
  # check-names.py ext4: a name the smoke wrote, in either form, is on disk as its NFC, and only so; --kept: exactly these
  #   bytes are still there (the Linux-made NFD name, and pair/'s two forms)
  i=$T/uni/ext4-names.img
  r=$(python3 -I "$here/lib/check-names.py" ext4 "$i" 636166c3a9 63616665cc81 2>&1); rc=$?
  expect check_names_ext4_nfc test "$rc" -eq 0 -a "$(printf '%s\n' "$r" | grep -c '^ok - .* is on disk as its NFC 636166c3a9$')" -eq 2
  r=$(python3 -I "$here/lib/check-names.py" ext4 "$i" 6e6169cc887665 2>&1); rc=$?
  expect check_names_ext4_nfd_notok test "$rc" -eq 1
  expect check_names_ext4_nfd_says has "$r" "^not ok - .* is on disk as 6e6169cc887665, not as its NFC 6e61c3af7665 only"
  r=$(python3 -I "$here/lib/check-names.py" ext4 "$i" 706169722f636166c3a9 2>&1); rc=$?
  expect check_names_ext4_both_forms_notok test "$rc" -eq 1
  r=$(python3 -I "$here/lib/check-names.py" ext4 "$i" --kept 6e6169cc887665 --kept 706169722f636166c3a9 --kept 706169722f63616665cc81 636166c3a9 2>&1); rc=$?
  expect check_names_ext4_kept test "$rc" -eq 0 -a "$(printf '%s\n' "$r" | grep -c '^ok - ')" -eq 4
  r=$(python3 -I "$here/lib/check-names.py" ext4 "$i" --kept 6e61c3af7665 2>&1); rc=$?
  expect check_names_ext4_kept_notok test "$rc" -eq 1
  r=$(python3 -I "$here/lib/check-names.py" ext4 "$i" 6e6f77686572652f78 2>&1); rc=$?
  expect check_names_ext4_no_dir test "$rc" -eq 1 -a -n "$(printf '%s\n' "$r" | grep '^not ok - .*no directory /nowhere')"
  r=$(python3 -I "$here/lib/check-names.py" ext4 "$i" 78 2>&1); rc=$?
  expect check_names_ext4_missing test "$rc" -eq 1 -a -n "$(printf '%s\n' "$r" | grep '^not ok - .*no entry')"
  rm -rf "$T/uni"
else echo "ok - unicode_image # SKIP needs Linux, mkfs.ext4, debugfs and python3"; fi

# census_dry: each census function against stub diskutil, hdiutil, osascript, guest-macosx-aqua, sudo, sysctl and linuxfs,
#   with directories for volumes. The stub bounded marks what runs under it, and a stub sleep outside it is a failure.
unset -f mkfile hdiutil diskutil
S=$T/stub; mkdir -p "$S/nodes" "$T/vols" "$T/in"
PARITY_FSTAB=$S/fstab PARITY_DALOG=$S/dalog PARITY_DAPL=$S/da.plist STUB=$S PARITY_POLLS=3
PARITY_SYSLOG=$S/syslog PARITY_ICNS=$S/icon.icns PARITY_SPOT_SECS=3
PARITY_VOLICON_OF=$S/volicon.icns   # census_busy's linuxfs.icns (the smoke names each bundle's, %s for the fs; here one for all)
# Task 16l: root's records and _linuxfs's lklfuse logs (its home's), which the stand-in sudo serves (its cat and sh)
PARITY_ROOT_STATE=$S/rootstate PARITY_ROOT_LKLOGS=$S/rootlogs
# census_da_root runs the smoke's own checks of a DiskArbitration mount, which the smoke defines before the census (Task 16l)
for f in info mounted_by_root log_since da_mount_true no_mount_failed da_root_mount no_owner_pseudo; do
  eval "$(awk -v n="$f() " 'index($0, n) == 1 { p = 1; print; if ($0 !~ /[{] *(#.*)?$/) exit; next } p { print } p && /^}/ { exit }' "$here/smoke-mavericks.sh")"
done
export PARITY_FSTAB PARITY_DALOG PARITY_SYSLOG STUB
: > "$PARITY_FSTAB"; : > "$PARITY_DALOG"; : > "$PARITY_DAPL"; : > "$S/calls"; : > "$PARITY_SYSLOG"; echo icns > "$PARITY_ICNS"
echo "linuxfs icns" > "$PARITY_VOLICON_OF"
for py in python3 /usr/bin/python; do command -v "$py" > /dev/null 2>&1 && PARITY_PYTHON=$py; done
cat > "$T/bin/stub" <<'EOF'
#!/bin/sh
# census_dry's stub of the Mac's disk tools: a node file per attached disk node (img, vol, mp, uuid, disk), .m when mounted
me=${0##*/}
# ps -ax: the host's processes, less any lklfuse (or a "not ok" in some other run's command line), and one fixed
#   lklfuse line (it fails with $STUB/ps-fail); the rest (ps -p) as it is
if test "$me" = ps; then
  case "$*" in
  *-ax*) test ! -f "$STUB/ps-fail" || exit 1
    /bin/ps "$@" | grep -v 'lklfuse\|not ok'; echo "stubuser 4242 1 Mon Nov 25 10:00:00 2026 /stub/lklfuse -f stub-lklfuse-line"
    # an lklfuse for each disk in $STUB/lklfuse-holds, its raw device open (as one outliving its unmount would be)
    test ! -f "$STUB/lklfuse-holds" || while read -r h; do echo "stubuser 4243 1 Mon Nov 25 10:00:00 2026 /stub/lklfuse -f -o fsname=/dev/$h /dev/r$h"; done < "$STUB/lklfuse-holds" ;;
  *) exec /bin/ps "$@" ;;
  esac
  exit 0
fi
printf '%s\n' "$me $*" | tee -a "$STUB/calls.all" >> "$STUB/calls"
N=$STUB/nodes
field() { sed -n "s/^$2=//p" "$N/$1" 2> /dev/null; }
node_of() { # a disk node, or a mount point: its node
  for f in "$N"/*; do
    case $f in *.m | *.u) continue ;; esac
    test -f "$f" || continue
    nd=${f##*/}
    if test "$nd" = "${1#/dev/}"; then echo "$nd"; return; fi
    if test -f "$f.m" && test "$(field "$nd" mp)" = "$1"; then echo "$nd"; return; fi
  done
}
log() { echo "$(date +%H:%M:%S)   $*" >> "$PARITY_DALOG"; }
# a linuxfs node's fs: the bundle's, from its volume's name (unicode-btrfs, finder-xfs-1, ...); ext4 when it names none
fs_of() { f=ext4; for b in btrfs xfs f2fs ntfs apfs; do case -$(field "$1" vol)- in *-$b-*) f=$b ;; esac; done; echo "$f"; }
# a linuxfs node's mount, root's since Task 16l (the mount daemon's): lklfuse's own log, $STUB/rootlogs/rNODE.log (_linuxfs's
#   ~/Library/Logs/linuxfs/<basename of the raw device>.log, written afresh by each mount), with its names line: exact, or
#   scanning with $STUB/names-scanning; and the mount program's lines in system.log (root's mount_macfuse -o, mounted by root).
#   With $STUB/da-macfuse-failed, macFUSE's refusal follows; with $STUB/da-owner-pseudo, DiskArbitration's ?owner= entry
names_log() {
  # every mount feeds the stub fs_usage Finder's open of the volume's .VolumeIcon.icns
  printf '%s\n' "$(date +%H:%M:%S).000002  open  F=5  (R_____)  $(field "$1" mp)/.VolumeIcon.icns  0.000120   Finder.79271" >> "$STUB/fsu-feed"
  test "$(field "$1" disk)" = "$1" || return 0
  mkdir -p "$STUB/rootlogs"
  if test -f "$STUB/names-scanning"; then m=scanning; else m=exact; fi
  printf '%s\n' "lklfuse: mounting" "lklfuse: names: $m (stub)" > "$STUB/rootlogs/r$1.log"
  f=$(fs_of "$1") mp=$(field "$1" mp)
  { echo "Nov 25 10:00:00 stubhost linuxfs-mount[9]: mount_$f: $1 on $mp: mount_macfuse -o allow_other,nosuid,nodev,local,volname=$(field "$1" vol),fsname=/dev/$1,noappledouble,fstypename=$f (pid 99)"
    test ! -f "$STUB/da-macfuse-failed" || echo "Nov 25 10:00:00 stubhost mount_macfuse[99]: mount_macfuse: failed to mount $mp@/dev/macfuse0: Operation not permitted"
    test ! -f "$STUB/da-owner-pseudo" || echo "Nov 25 10:00:00 stubhost diskarbitrationd[8]: created disk, id = $mp?owner=0"
    echo "Nov 25 10:00:00 stubhost linuxfs-mount[9]: mount_$f: $1 mounted on $mp by root, served by _linuxfs"; } >> "$PARITY_SYSLOG"
}
# with $STUB/da-forgets, DiskArbitration as push A saw it (item 4), when a linuxfs volume's mount was named linuxfs@rdiskN: a
#   mount or an unmount of any other volume leaves its disk untied (.u): DiskArbitration says it is not mounted, its eject
#   unmounts nothing and fails busy under the lklfuse still serving it; diskutil unmount of its mount point still works
untie_others() {
  test -f "$STUB/da-forgets" || return 0
  for f in "$N"/*.m; do
    test -f "$f" || continue
    o=${f##*/}; o=${o%.m}
    test "$o" != "$1" && test "$(field "$o" disk)" = "$o" && : > "$N/$o.u"
  done
  return 0
}
case $me in
hdiutil)
  case $1 in
  attach)
    nomount= verbose= img=
    for a; do case $a in -nomount) nomount=1 ;; -verbose) verbose=1 ;; *.img) img=$a ;; esac; done
    b=${img##*/}; b=${b%.img}
    # a plain attach of a retry-once image stalls the first time; of a retry-always image, every time
    case $b in *retry-once* | *retry-always*)
      if test -z "$nomount"; then
        case $b in *retry-once*) test ! -f "$STUB/retried-$b" || b=${b}-ok ;; esac
        case $b in *-ok) ;; *) : > "$STUB/retried-$b"; echo "hdiutil: attach failed - no mountable file systems" >&2; exit 1 ;; esac
      fi ;;
    esac
    case $b in *stall-ext4*)
      if test -n "$verbose"; then
        k=$(($(cat "$STUB/stallcount" 2> /dev/null || echo 0) + 1)); echo $k > "$STUB/stallcount"
        if test $((k % 2)) -eq 0; then echo "hdiutil: attach failed - no mountable file systems" >&2; exit 1; fi
      fi ;;
    esac
    k=$(($(cat "$STUB/disks" 2> /dev/null || echo 1) + 1)); echo $k > "$STUB/disks"
    d=disk$k
    case $b in *hfs*|*fat32*|*exfat*) nd=${d}s1; echo "/dev/$d          	GUID_partition_scheme" ;; *) nd=$d; echo "$d" >> "$STUB/fsdisks" ;; esac
    mp=$STUB/../vols/$b; mkdir -p "$mp"
    # fseventsd makes .fseventsd on every volume, a linuxfs one too now that SHARE_OPT lets root's fseventsd in (Task 14);
    #   with $STUB/fsevents-refused, as in pushes A and C, a linuxfs volume has none and draws a refusal from root's
    #   fseventsd (pid 1 stands in), naming its mount point
    if test "$nd" = "$d" && test -f "$STUB/fsevents-refused"; then
      rm -rf "$mp/.fseventsd"; echo "Nov 25 10:00:00 stubhost fseventsd[1]: could not open $mp/.fseventsd (Operation not permitted)" >> "$PARITY_SYSLOG"
    else mkdir -p "$mp/.fseventsd"; fi
    printf 'img=%s\nvol=%s\nmp=%s\nuuid=UUID-%s\ndisk=%s\n' "$img" "$b" "$mp" "$b" "$d" > "$N/$nd"
    log "created disk, id = /dev/$d."
    log "probed disk, id = /dev/$nd, with stub, success."
    case $b in *nouuid*) sed -i.x '/^uuid=/d' "$N/$nd"; rm -f "$N/$nd.x" ;; esac
    # flaky (a linuxfs image): only its first attach mounts; after its first eject, ejects and detaches fail
    case $b in *hfs*) ;; *flaky*) if test -f "$STUB/flaky-attached"; then b=nevermount-$b; else : > "$STUB/flaky-attached"; fi ;; esac
    case $b in *names*) test ! -f "$STUB/names-nomount" || b=nevermount-$b ;; *hfs*) ;; *nomnt*) b=nevermount-$b ;; esac
    case $b:$nomount in *nevermount*:) echo "/dev/$nd          	Stub" ;; *swept*:1 | *:) : > "$N/$nd.m"; names_log "$nd"; untie_others "$nd"; echo "/dev/$nd          	Stub	$mp" ;;
    *) echo "/dev/$nd          	Stub" ;; esac ;;
  detach)
    for a; do case $a in disk*|/dev/disk*) d=${a#/dev/}; case $(field "$d" vol) in *hfs*) ;; *flaky*) test ! -f "$STUB/flaky-ejected" || exit 1 ;; esac; rm -f "$N/$d" "$N/$d.m" "$N/$d.u" "$N/${d}s1" "$N/${d}s1.m" ;; esac; done ;;
  info)
    test ! -f "$STUB/info-fail" || { echo "hdiutil: info failed - stub"; exit 1; }
    echo "framework       : stub"; echo "driver          : stub"
    for f in "$N"/*; do case $f in *.m | *.u) continue ;; esac; test -f "$f" || continue
      echo "image-path      : $(field "${f##*/}" img)"; echo "/dev/$(field "${f##*/}" disk)	GUID_partition_scheme"; done ;;
  esac ;;
diskutil)
  case $1 in
  info)
    nd=$(node_of "$2")
    if test -z "$nd"; then
      if test -f "$N/${2#/dev/}s1"; then echo "   Mounted:                  No"; exit 0; fi
      echo "Could not find disk: $2"; exit 1
    fi
    echo "   Volume Name:              $(field "$nd" vol)"
    if test -f "$N/$nd.m" && test ! -f "$N/$nd.u"; then echo "   Mounted:                  Yes"; echo "   Mount Point:              $(field "$nd" mp)"
    else echo "   Mounted:                  No"; fi
    test -z "$(field "$nd" uuid)" || echo "   Volume UUID:              $(field "$nd" uuid)"
    printf '%s\n' "   Protocol:                 Disk Image" "   Read-Only Media:          No" "   Ejectable:                Yes" "   Internal:                 No" ;;
  mount)
    nd=$(node_of "$2"); test -n "$nd" || exit 1; : > "$N/$nd.m"; rm -f "$N/$nd.u"; names_log "$nd"; untie_others "$nd"; echo "Volume $(field "$nd" vol) on $nd mounted" ;;
  unmount)
    t=$2; test "$t" != force || t=$3
    nd=$(node_of "$t"); test -n "$nd" || { echo "Unmount failed for $t"; exit 1; }
    case $(field "$nd" vol) in *busy-ext4*)
      if test ! -f "$STUB/busy-once"; then : > "$STUB/busy-once"; echo "Unmount failed for $t"; exit 1; fi ;;
    esac
    rm -f "$N/$nd.m" "$N/$nd.u"; untie_others "$nd"; echo "Volume $(field "$nd" vol) on $nd unmounted" ;;
  eject)
    d=${2#/dev/}
    case $(field "$d" vol) in *stuck*) echo "Disk $d couldn't be ejected (stub stuck)"; exit 1 ;; esac
    # with $STUB/stall-stuck, the stall's ext4 copy never ejects
    case $(field "$d" vol) in *stall-ext4*) test ! -f "$STUB/stall-stuck" || { echo "Disk $d couldn't be ejected (stub stall-stuck)"; exit 1; } ;; esac
    # an HFS+ image the sweep's tests name sweep-stuck-hfs-* never ejects either (its volume is the disk's s1)
    case $(field "${d}s1" vol) in sweep-stuck-hfs-*) echo "Disk $d couldn't be ejected (stub stuck)"; exit 1 ;; esac
    case $(field "$d" vol) in *hfs*) ;; *flaky*)
      if test -f "$STUB/flaky-ejected"; then echo "Disk $d couldn't be ejected (stub flaky)"; exit 1; fi; : > "$STUB/flaky-ejected" ;;
    esac
    case $(field "$d" vol) in busy-ext4)
      if test ! -f "$STUB/eject-once"; then : > "$STUB/eject-once"; echo "Disk $d couldn't be ejected (stub busy)"; exit 1; fi ;;
    esac
    if test -f "$N/$d.u" && test -f "$N/$d.m"; then echo "Volume failed to eject"; exit 1; fi
    if test -f "$N/$d.m" || test -f "$N/${d}s1.m"; then untie_others "$d"; fi
    rm -f "$N/$d" "$N/$d.m" "$N/$d.u" "$N/${d}s1" "$N/${d}s1.m"; echo "Disk $d ejected" ;;
  esac ;;
mount)
  # a linuxfs volume is root's mount (no "mounted by"), of its fs's type, nodev and nosuid; with $STUB/da-user-mount the user's own
  #   (a fallback), with $STUB/da-no-nodev no nodev, and with $STUB/da-phantom not there at all (DiskArbitration's Mounted: Yes stays)
  test ! -f "$STUB/mount-fail" || exit 1
  echo "/dev/disk0s2 on / (hfs, local, journaled)"
  for f in "$N"/*.m; do
    test -f "$f" || continue
    nd=${f##*/}; nd=${nd%.m}
    if test "$(field "$nd" disk)" = "$nd"; then
      test ! -f "$STUB/da-phantom" || continue
      o="local, nodev, nosuid, synchronous"; test ! -f "$STUB/da-no-nodev" || o="local, nosuid, synchronous"
      test ! -f "$STUB/da-user-mount" || o="$o, mounted by vagrant"
      echo "/dev/$nd on $(field "$nd" mp) (macfuse_$(fs_of "$nd"), $o)"
    else echo "/dev/$nd on $(field "$nd" mp) (hfs, local, nodev, nosuid, journaled, noowners, mounted by stub)"; fi
  done ;;
linuxfs)
  case $1 in
  ignore) test ! -f "$STUB/ignore-fails" || exit 1; d=${2#/dev/}; echo "UUID=$(field "$d" uuid) none macfuse_ext4 rw,noauto # linuxfs" >> "$PARITY_FSTAB" ;;
  unignore) d=${2#/dev/}; grep -v "^UUID=$(field "$d" uuid) " "$PARITY_FSTAB" > "$PARITY_FSTAB.t"; cat "$PARITY_FSTAB.t" > "$PARITY_FSTAB"; rm -f "$PARITY_FSTAB.t" ;;
  esac ;;
sudo)
  test "$1" != -n || shift
  # census_fsu_start's root shell (sh -c '... exec fs_usage ...' _ PIDFILE): the stub fs_usage writes PIDFILE itself, once its
  #   handlers are in (the real one's few ms between its pid and its handlers are a stub's Python start-up)
  case "$*" in "sh -c "*"exec fs_usage "*) STUB_FSU_PIDFILE=$5 exec fs_usage -w -f pathname ;; esac
  case $1 in
  sh|tail|cat|wc|mdutil|tmutil) exec "$@" ;;
  # with $STUB/sudo-kill-refused, sudoers lets no kill through
  kill) test ! -f "$STUB/sudo-kill-refused" || { echo "sudo: a password is required" >&2; exit 1; }; shift; kill "$@"; exit $? ;;
  lsof)
    case "$*" in
    # the whole table (+c0, no path): a header, a line elsewhere, and Finder holding each mounted volume's .VolumeIcon.icns
    *+c0*) echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"; echo "launchd 1 root 3r REG 1,2 0 1 /private/var/stub-elsewhere"
      for f in "$N"/*.m; do test -f "$f" || continue; nd=${f##*/}; nd=${nd%.m}; echo "Finder 79271 stubuser 12r REG 1,2 0 1 $(field "$nd" mp)/.VolumeIcon.icns"; done ;;
    *) echo "COMMAND PID USER (stub lsof $*)" ;;
    esac ;;
  esac ;;
mkfile) : > "$2" ;;
sysctl) echo "$1.version.number: stub" ;;
mdutil)
  eval "echo \"\${$#}:\""
  if test "$1" = -s && test -f "$STUB/mdutil-unknown"; then echo "	Error: unknown indexing state."
  elif test "$1" = -s; then echo "	Indexing enabled."
  elif test "$1:$2" = -i:on && test -f "$STUB/mdutil-400"; then echo "Error: unable to perform operation.  (-400)"; echo "	Error: unknown indexing state."
  else echo "	Indexing disabled."; fi ;;
mdfind) test ! -e "$2/$4" || echo "$2/$4" ;;
tmutil)
  case $1 in
  isexcluded) echo "[Excluded]    $2" ;;
  esac ;;
defaults)
  case $1:$3 in
  write:NTFSTakeover) if test "$5" = true; then echo 1; else echo 0; fi > "$STUB/takeover" ;;
  delete:NTFSTakeover) rm -f "$STUB/takeover" ;;
  read:NTFSTakeover) cat "$STUB/takeover" 2> /dev/null || exit 1 ;;
  esac ;;
df)
  # $STUB/df-free, when there: its first line is the free KiB df -P -k gives, the line dropped while others follow
  if test -f "$STUB/df-free"; then
    v=$(sed -n 1p "$STUB/df-free"); test "$(wc -l < "$STUB/df-free")" -le 1 || sed -i.x 1d "$STUB/df-free"; rm -f "$STUB/df-free.x"
    echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "stub 99999999999 0 $v 0% /"
  else exec /bin/df "$@"; fi ;;
xattr)
  # -wx keeps the value per path; -px gives it back, else a mounted linuxfs volume's root serves kHasCustomIcon (patch 0017's
  #   volicon), else a short record with no flag
  case $1 in
  -l) echo "com.apple.FinderInfo: stub" ;;
  -wx) mkdir -p "$STUB/xattrs"; echo "$3" > "$STUB/xattrs/$(printf '%s' "$4" | tr / _).$2" ;;
  -px)
    k=$STUB/xattrs/$(printf '%s' "$3" | tr / _).$2; nd=$(node_of "$3")
    if test -f "$k"; then sed 's/../& /g; s/ $//' "$k"
    elif test -n "$nd" && test "$(field "$nd" disk)" = "$nd" && test "$(field "$nd" mp)" = "$3"; then
      echo "00 00 00 00 00 00 00 00 04 00 00 00 00 00 00 00"; echo "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
    else echo "00 00 04 00"; fi ;;
  esac ;;
guest-macosx-aqua)
  case $1 in
  screencapture) if test -f "$STUB/same-shots"; then echo same > "$3"; else echo "$3" > "$3"; fi ;;
  defaults) test "$2" != read || exit 1 ;;
  osascript)
    case "$*" in
    # census_finder_dialogs: with $STUB/no-ui, System Events refuses (no assistive access); with $STUB/dialog-force, a
    #   dialog with neither Cancel nor OK is left up
    *AXDialog*"click button"*)
      if test -f "$STUB/no-ui"; then echo "System Events got an error: osascript is not allowed assistive access. (-1719)"; exit 1; fi
      if test -f "$STUB/dialog-force"; then echo "left up (Force Eject…): The disk stub wasn't ejected."; else echo "OK: The disk “stub” was ejected."; fi ;;
    # census_await's conditions: true, but for a dialog with $STUB/no-ui and a window with $STUB/no-window
    *AXDialog*) test -f "$STUB/no-ui" && { echo "System Events got an error: not allowed assistive access. (-1719)"; exit 1; }; echo true ;;
    *"target of front Finder window"* | *"is information window"*) if test -f "$STUB/no-window"; then echo false; else echo true; fi ;;
    *"current pane"*) echo true ;;
    *ejectable*) echo "true|true|false|1.34217728E+8|1.0E+8|Mac OS Extended format" ;;
    *"count items"*) echo 1 ;;
    *"with properties"*) test ! -f "$STUB/finder-fails" || { echo "Finder got an error: stub"; exit 1; } ;;
    *"get warns before emptying"*) echo true ;;
    esac ;;
  esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/stub"
# fs_usage: says it ran and its pid; on INT or TERM (handled as the real one does: it sets its own handlers, so a background
#   job's ignored INT reaches it), prints a line elsewhere and what the mounts fed it since it began (the real one prints as
#   it goes, and flushes at its exit), then exits. In Python: a sh in a background job cannot trap the INT it inherits ignored
printf '#!%s\n' "$(command -v "$PARITY_PYTHON")" > "$T/bin/fs_usage"
cat >> "$T/bin/fs_usage" <<'EOF'
import os, signal, sys, time
stub = os.environ["STUB"]
open(stub + "/calls", "a").write("fs_usage " + " ".join(sys.argv[1:]) + "\n")
open(stub + "/fsu-pids", "a").write("%d\n" % os.getpid())
feed = stub + "/fsu-feed"
try:
    off = os.path.getsize(feed)
except OSError:
    off = 0
def leave(n, f):
    sys.stdout.write(time.strftime("%H:%M:%S") + ".000001  open  F=4  (R_____)  /private/var/stub-elsewhere  0.000010   launchd.1\n")
    try:
        fh = open(feed)
        fh.seek(off)
        sys.stdout.write(fh.read())
    except IOError:
        pass
    sys.stdout.flush()
    os._exit(0)
signal.signal(signal.SIGINT, leave)
signal.signal(signal.SIGTERM, leave)
if os.environ.get("STUB_FSU_PIDFILE"):
    open(os.environ["STUB_FSU_PIDFILE"], "w").write("%d\n" % os.getpid())
for i in range(600):
    time.sleep(0.1)
EOF
chmod +x "$T/bin/fs_usage"
for c in hdiutil diskutil osascript sudo sysctl mkfile linuxfs mdutil mdfind tmutil defaults xattr df ps mount; do ln -sf stub "$T/bin/$c"; done
rm -f "$T/aqua/guest-macosx-aqua"; ln -sf ../bin/stub "$T/aqua/guest-macosx-aqua"
expect census_aqua_off_path not command -v guest-macosx-aqua
L=$T/bin/linuxfs; IN=$T/in
rm -rf "$W/ctl" "$OUT/parity"; mkdir -p "$W/img"
for f in ext4 btrfs xfs ntfs apfs; do echo "$f image" > "$W/img/$f.img"; done
echo names | gzip -c > "$IN/ext4-names.img.gz"
unbounded=$T/unbounded; : > "$unbounded"
PARITY_XATTR_SIZES="131072 131073 262144"; PARITY_FREE_FLOOR_KB=1 PARITY_START_FLOOR_KB=1
PARITY_LKLOGS=$S/lklogs PARITY_AWAIT_SECS=0

# census_xattr_sizes: by default the probe climbs past 10.9's XATTR_MAXSIZE-free HFS+ to a size no 128 MiB control holds
r=$(unset PARITY_XATTR_SIZES; . "$here/lib/parity.sh"; echo "$PARITY_XATTR_SIZES")
expect census_xattr_sizes_default test "$r" = "131072 131073 262144 1048576 4194304 16777216 67108864 67108865 134217728"
# census_py_xattr, against a fake xattr module on PYTHONPATH (not the host's filesystem or xattr module: the CI runner's
#   differ): it logs its calls, raises KeyError on a remove (as 10.9's module does when there is none), and refuses a
#   value of PYX_REFUSE_AT bytes or more with errno PYX_ERRNO. Each case prints what it got when it fails.
mkdir -p "$T/pyx"; : > "$T/pyx-file"
cat > "$T/pyx/xattr.py" <<'EOF'
import os
def _log(s):
    f = open(os.environ["PYX_LOG"], "a"); f.write(s + "\n"); f.close()
def setxattr(p, n, v, options=0):
    _log("set %d" % len(v))
    if len(v) >= int(os.environ["PYX_REFUSE_AT"]):
        e = int(os.environ["PYX_ERRNO"]); raise OSError(e, os.strerror(e))
def removexattr(p, n, options=0):
    _log("remove")
    raise KeyError(n)
EOF
pyx() { # REFUSE-AT ERRNO SIZE...: census_py_xattr on the fake module; its output, the calls in $T/pyx.log
  : > "$T/pyx.log"
  _r=$1 _e=$2; shift 2
  PYX_LOG=$T/pyx.log PYX_REFUSE_AT=$_r PYX_ERRNO=$_e PYTHONPATH=$T/pyx "$PARITY_PYTHON" -c "$census_py_xattr" "$T/pyx-file" "$@" 2>&1
}
said() { # NAME GOT WANT: expect GOT = WANT, and when not, both shown
  if test "$2" = "$3"; then echo "ok - $1"; else echo "not ok - $1"; fails=$((fails + 1)); echo "# got:"; printf '%s\n' "$2" | sed 's/^/#   /'; echo "# want:"; printf '%s\n' "$3" | sed 's/^/#   /'; fi
}
# the sizes in order, stopping at the first refusal (ENOENT here), which is said; no larger size is tried
r=$(pyx 131072 2 131072 262144)
said census_py_xattr_stops "$(printf '%s\n' "$r" | sed 's/ (.*//')" "$(printf '%s\n' '131072 bytes: errno 2' 'stopped at the first refusal')"
said census_py_xattr_stops_untried "$(tr '\n' ' ' < "$T/pyx.log")" "remove set 131072 remove "
# each size is written on its own space: the attribute is removed before each write, and ENOSPC stops the climb
r=$(pyx 3 28 1 2 3 4)
said census_py_xattr_each_alone "$(tr '\n' ' ' < "$T/pyx.log")" "remove set 1 remove set 2 remove set 3 remove "
said census_py_xattr_enospc_stops "$(printf '%s\n' "$r" | sed 's/ (.*//')" "$(printf '%s\n' '1 bytes: ok' '2 bytes: ok' '3 bytes: errno 28' 'stopped at the first refusal')"
rm -rf "$T/pyx" "$T/pyx.log" "$T/pyx-file"

# census_py_create: a name that cannot be made says its errno, and the next name is still tried
mkdir -p "$T/uc"; : > "$T/uc/file"
r=$("$PARITY_PYTHON" -c "$census_py_create" "$T/uc" 66696c652f78 79 2>&1)
expect census_py_create_goes_on test "$(printf '%s\n' "$r" | sed 's/errno [0-9]*$/errno N/')" = "$(printf '%s\n' '66696c652f78 errno N' '79 created')"
rm -rf "$T/uc"
bounded() { ( PARITY_TEST_BOUNDED=1; shift; "$@" ); }
sleep() { test -n "${PARITY_TEST_BOUNDED:-}" || { echo "sleep $* outside bounded" >> "$unbounded"; return 1; }; echo "sleep $*" >> "$T/sleeps"; }
attached() { ls "$S/nodes" | grep -v '\.[mu]$' | tr '\n' ' '; }

# platform: the stub volumes are plain directories, and only a Mac's (HFS+) finds a name by its other form, which the
#   checked steps need on the HFS+ side; elsewhere the census's Python gets that lookup (both sides alike) from a
#   sitecustomize: a missing name under $T/vols opens the entry of the same NFD, as HFS+ (and lklfuse) would
if test "$(uname -s)" != Darwin; then
  mkdir -p "$T/hfsfold"
  cat > "$T/hfsfold/sitecustomize.py" <<'EOF2'
import builtins, os, unicodedata
_root, _open = os.environ.get("PARITY_TEST_VOLS", "").encode(), builtins.open
def _fold(p):
    if not _root or not isinstance(p, bytes) or not os.path.normpath(p).startswith(_root) or os.path.lexists(p):
        return p
    d, n = os.path.split(p)
    try:
        want = unicodedata.normalize("NFD", n.decode())
        for e in os.listdir(d):
            if unicodedata.normalize("NFD", e.decode()) == want:
                return os.path.join(d, e)
    except (OSError, UnicodeDecodeError):
        pass
    return p
builtins.open = lambda p, *a, **k: _open(_fold(p), *a, **k)
EOF2
  PYTHONPATH=$T/hfsfold PARITY_TEST_VOLS=$T/vols; export PYTHONPATH PARITY_TEST_VOLS
fi
# census_unicode: item 1 is checked (PARITY_MODE_UNICODE defaults to check): the shell's and Finder's names on the
#   pair, created then opened by both forms; ext4's on its da-ext4 image (returned by the smoke), whose names it lists
#   for the fsck job; the Linux-made names image, attached as da-ext4-names.img, its root's names opened by both forms
#   (checked) and pair/ recorded (HFS+ cannot hold both forms); the FAT32 control once, recorded
r=$(unset PARITY_MODE_UNICODE; . "$here/lib/parity.sh"; echo "$PARITY_MODE_UNICODE")
expect census_unicode_checked test "$r" = check
PARITY_MODE_UNICODE=check
echo "da-ext4 image" > "$W/img/da-ext4.img"
mkdir -p "$T/vols/da-ext4-names"   # the stub's volume: the Linux-made names, as the census makes them on HFS+
"$PARITY_PYTHON" -c "$census_py_create" "$T/vols/da-ext4-names" 636166c3a9 6e6169cc887665 > /dev/null 2>&1
r=$(census_unicode ext4 2>&1)
P=$OUT/parity
for s in shell-create shell-listdir shell-open-both finder-newfolder finder-rename finder-listdir; do
  expect "census_unicode_$s" test -s "$P/unicode.ext4.$s.hfs.txt" -a -s "$P/unicode.ext4.$s.ext4.txt"
  expect "census_unicode_${s}_ok" has "$r" "^ok - parity unicode.ext4.$s\$"
  expect "census_unicode_fat32_$s" test -s "$P/unicode-ctl.fat32.$s.hfs.txt" -a -s "$P/unicode-ctl.fat32.$s.fat32.txt"
  expect "census_unicode_fat32_${s}_recorded" has "$r" "^# recorded unicode-ctl.fat32.$s\$"
done
expect census_unicode_names_open_both has "$r" "^ok - parity unicode.names.open-both\$"
expect census_unicode_names_open_both_root test "$(grep -c '^[0-9a-f]* \(ok\|errno\)' "$P/unicode.names.open-both.ext4.txt")" -eq 4
for s in listdir open-both; do expect "census_unicode_pair_$s" has "$r" "^# recorded unicode-pair.names.$s\$"; done
expect census_unicode_listdir_bytes test "$(grep -c '^[0-9a-f][0-9a-f]*$' "$P/unicode.ext4.shell-listdir.ext4.txt")" -eq 2
for h in 636166c3a9 63616665cc81 6e6169cc887665 6e61c3af7665; do
  expect "census_unicode_open_both_$h" grep -Eq "^$h (ok [0-9a-f]+|errno 2)\$" "$P/unicode.ext4.shell-open-both.ext4.txt"
done
expect census_unicode_on_da_ext4 grep -q '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/img/da-ext4.img$' "$S/calls"
expect census_unicode_names_da grep -q '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/img/da-ext4-names.img$' "$S/calls"
expect census_unicode_names_returned test -s "$W/img/da-ext4-names.img"
uni=756e692d65787434
expect census_unicode_da_list test "$(cat "$OUT/da-ext4.names")" = "$(printf '%s\n' "${uni}2f636166c3a9" "${uni}2f6e6169cc887665" "${uni}2f636166c3a92d66696e646572" "${uni}2f6e61c3af76652d66696e646572")"
expect census_unicode_names_list test "$(cat "$OUT/da-ext4-names.names")" = "$(printf '%s\n' 636166c3a9 '--kept 6e6169cc887665' '--kept 706169722f636166c3a9' '--kept 706169722f63616665cc81')"
expect census_unicode_finder grep -q 'character id 233' "$S/calls"
expect census_unicode_shots test "$(grep -c 'screencapture -x .*-names.png' "$S/calls")" -eq 2
expect census_unicode_fat32_out test -s "$OUT/ctl-fat32.img.gz"
expect census_unicode_fat32_copy grep -q '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/census/ctl-fat32.img$' "$S/calls"
expect census_unicode_fat32_control_kept not grep -q '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/ctl/fat32.img$' "$S/calls"
expect census_unicode_sysctl grep -q 'vfs.generic.macfuse' "$P/unicode-ext4.sysctl.txt"
expect census_unicode_quiet hasnt "$r" "not ok"
expect census_unicode_detached test -z "$(attached)"
: > "$S/calls"
r=$(census_unicode btrfs 2>&1)
expect census_unicode_btrfs_ok has "$r" "^ok - parity unicode.btrfs.shell-open-both\$"
expect census_unicode_btrfs_copy grep -q '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/census/unicode-btrfs.img$' "$S/calls"
expect census_unicode_fat32_once not grep -q 'fat32' "$S/calls"
expect census_unicode_names_ext4_only not grep -q 'names' "$S/calls"
# item 1 (Task 13b): lklfuse's names mode for every linuxfs census mount, read from lklfuse's own log (as the smoke's CLI
#   loop reads it) right after the mount, into names-mode.txt; an HFS+ or FAT32 mount has no line
expect census_names_recorded grep -q '^disk[0-9]* .*/vols/unicode-btrfs: exact (stub)$' "$P/names-mode.txt"
expect census_names_only_linuxfs not grep -q 'hfs\|fat32' "$P/names-mode.txt"
# Finder failing on both sides: equal records, but the HFS+ control failed, so not ok; the fsck job is not given the
#   Finder names (the smoke's not ok says why)
: > "$S/finder-fails"
r=$(census_unicode ext4 2>&1)
expect census_unicode_finder_fails_notok has "$r" "^not ok - parity unicode.ext4.finder-newfolder$"
expect census_unicode_finder_fails_said has "$r" "^parity: unicode.ext4.finder-newfolder failed on the HFS+ control (status 1), so it proves nothing$"
expect census_unicode_finder_fails_list test "$(cat "$OUT/da-ext4.names")" = "$(printf '%s\n' "${uni}2f636166c3a9" "${uni}2f6e6169cc887665" "${uni}2f6e61c3af76652d66696e646572")"
rm -f "$S/finder-fails"
# the names image not mounted: not ok, and no da-ext4-names.names (an untouched image must not pass the fsck job)
: > "$S/names-nomount"
r=$(census_unicode ext4 2>&1)
expect census_unicode_names_nomount_notok has "$r" "^not ok - parity unicode.names: not run (da-ext4-names.img not attached and mounted)$"
expect census_unicode_names_nomount_list test ! -e "$OUT/da-ext4-names.names"
expect census_unicode_names_nomount_detached test -z "$(attached)"
rm -f "$S/names-nomount"
# no ext4-names.img.gz: not ok
mv "$IN/ext4-names.img.gz" "$T/names.gz"
r=$(census_unicode ext4 2>&1)
expect census_unicode_names_none_notok has "$r" "^not ok - parity unicode.names: not run (no .*/ext4-names.img.gz"
mv "$T/names.gz" "$IN/ext4-names.img.gz"
# no da-ext4 image (the DiskArbitration section made none): not ok, and no ext4 names are listed for the fsck job
rm -f "$W/img/da-ext4.img"
r=$(census_unicode ext4 2>&1)
expect census_unicode_no_da_said has "$r" "^not ok - parity unicode.ext4: not run (no .*/img/da-ext4.img"
expect census_unicode_no_da_list test ! -e "$OUT/da-ext4.names"
expect census_unicode_no_da_detached test -z "$(attached)"
rm -f "$W/img/da-ext4-names.img"
# a filesystem whose image is not mounted (its HFS+ control is): not ok, naming why
echo "nomnt image" > "$W/img/nomnt.img"
r=$(census_unicode nomnt 2>&1)
expect census_unicode_nomount_notok has "$r" "^not ok - parity unicode.nomnt: not run (unicode-nomnt.img not attached and mounted)$"
expect census_unicode_nomount_detached test -z "$(attached)"
rm -f "$W/img/nomnt.img"
# census_on's skips (time, room, no image) of census_unicode are not ok; of a recording census, only said
r=$(CA_T0=$(($(date +%s) - 120)); PARITY_CENSUS_MIN=1; census_on btrfs census_unicode btrfs 2>&1)
expect census_on_unicode_time_notok has "$r" "^not ok - parity unicode.btrfs: not run (out of time (1 min))$"
# skipped for its worst case (10 min gone, 13 at worst, the end at 11 + 11): that reason, not "out of time"
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=11; census_on btrfs census_unicode btrfs 2>&1)
expect census_on_unicode_worst_notok has "$r" "^not ok - parity unicode.btrfs: not run (census_unicode may take 17 min, past the census's end (22 min))$"
r=$(PARITY_START_FLOOR_KB=999999999999; census_on btrfs census_unicode btrfs 2>&1)
expect census_on_unicode_room_notok has "$r" "^not ok - parity unicode.btrfs: not run (no room on "
r=$(census_on nosuchfs census_unicode nosuchfs 2>&1)
expect census_on_unicode_noimg_notok has "$r" "^not ok - parity unicode.nosuchfs: not run (no nosuchfs.img)$"
r=$(CA_T0=$(($(date +%s) - 120)); PARITY_CENSUS_MIN=1; census_on btrfs census_finder btrfs 2>&1)
expect census_on_other_time_quiet hasnt "$r" "not ok"
# recorded (item 1 not checked), a skip is only said
r=$(PARITY_MODE_UNICODE=record; CA_T0=$(($(date +%s) - 120)); PARITY_CENSUS_MIN=1; census_on btrfs census_unicode btrfs 2>&1)
expect census_on_unicode_record_said has "$r" "^# census: census_unicode btrfs not run: out of time (1 min)$"
expect census_on_unicode_record_quiet hasnt "$r" "not ok"
# census_left_attached names census_unicode's own $W/img images when one is left attached
r=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage "$W/img/da-ext4.img" 2>&1)
census_left_attached > /dev/null 2>&1
expect census_left_da_ext4 grep -q "^/dev/disk[0-9]* $W/img/da-ext4.img\$" "$P/census-left-attached.txt"
for f in "$S"/nodes/*; do case $f in *.m | *.u) ;; *) test -f "$f" || continue; case $(sed -n 's/^vol=//p' "$f") in da-ext4) rm -f "$f" "$f.m" "$f.u" ;; esac ;; esac; done

# census_stall: not run at 0; at 2, both loops on both volumes, counted, with probe times and Fisher's p
: > "$S/calls"
r=$(PARITY_STALL_N=0 census_stall 2>&1)
expect census_stall_zero test ! -e "$P/stall.txt" -a ! -s "$S/calls"
r=$(unset PARITY_STALL_N; census_stall 2 2>&1)
expect census_stall_variable_only test ! -e "$P/stall.txt" -a ! -s "$S/calls"
r=$(PARITY_STALL_N=2 census_stall 2>&1)
expect census_stall_lines test "$(grep -c '^[a-z0-9]*-loop[12]-[12]: ' "$P/stall.txt")" -eq 8
expect census_stall_hfs_line grep -q '^hfs-loop1-1: automounted in [0-9]* s .*probe disk[0-9]*s1 stub [0-9]*s' "$P/stall.txt"
expect census_stall_stalled grep -q '^ext4-loop1-2: stalled after [0-9]* s: hdiutil exit 1: hdiutil: attach failed - no mountable file systems' "$P/stall.txt"
expect census_stall_counts test "$(grep -c '^[a-z0-9]* loop [12]: ' "$P/stall-summary.txt")" -eq 4
expect census_stall_ext4_1 grep -q '^ext4 loop 1: 1 stalls, 1 automounts, 0 setup failures of 2' "$P/stall-summary.txt"
expect census_stall_ext4_2 grep -q '^ext4 loop 2: 2 stalls, 0 automounts, 0 setup failures of 2' "$P/stall-summary.txt"
expect census_stall_p1 grep -q '^loop 1 .*Fisher p = 1.0000 ' "$P/stall-summary.txt"
expect census_stall_p2 grep -q '^loop 2 .*Fisher p = 0.3333 ' "$P/stall-summary.txt"
expect census_stall_hfs_fstab grep -q '^sudo -n sh -c .* UUID=UUID-stall-hfs none hfs rw,noauto$' "$S/calls"
expect census_stall_ext4_ignore grep -q '^linuxfs ignore /dev/disk' "$S/calls"
expect census_stall_fstab_clean test ! -s "$PARITY_FSTAB"
expect census_stall_debug_da grep -q 'launchctl' "$S/calls"
expect census_stall_dalog test -s "$P/stall-ext4-loop1-2.dalog"
expect census_stall_recorded has "$r" "^# recorded stall loop 2: hfs 0/2, ext4 2/2, Fisher p = 0.3333"
expect census_stall_quiet hasnt "$r" "not ok"
expect census_stall_sysctl test -s "$P/stall.sysctl.txt"
expect census_stall_detached test -z "$(attached)"
expect census_names_stall grep -q '/vols/stall-ext4: exact (stub)$' "$P/names-mode.txt"
expect census_names_stall_not_hfs not grep -q '/vols/stall-hfs' "$P/names-mode.txt"
# past the deadline, no further iteration begins, and the counts say how many ran
r=$(CA_T0=$(($(date +%s) - 120)); PARITY_CENSUS_MIN=1; PARITY_STALL_N=2; census_stall 2>&1)
expect census_stall_cut grep -q '^hfs loop 1: 0 stalls, 0 automounts, 0 setup failures of 0 (stopped early, out of time: 2 asked)$' "$P/stall-summary.txt"
expect census_stall_cut_said grep -q '^# census: out of time (1 min), skipped: stall hfs loop 1 from iteration 1 of 2$' "$P/stall-summary.txt"
expect census_stall_cut_none test "$(grep -c '^[a-z0-9]*-loop' "$P/stall.txt")" -eq 0
expect census_stall_cut_recorded has "$r" "^# recorded stall loop 1: hfs 0/0, ext4 0/0"
expect census_stall_cut_stdout has "$r" "^# census: out of time (1 min), skipped: stall hfs loop 1 from iteration 1 of 2"
expect census_stall_cut_detached test -z "$(attached)"
# (fix round 3) a stall disk left attached (a linuxfs one is never detached by force) ends its volume's loops: each later
#   attach of the same image would measure the leftover, and count it a stall. The iteration whose setup left it is a
#   setup failure, not a stall; it is said, and Fisher's p is not computed for a loop it cut short (or kept from running)
: > "$S/stall-stuck"; : > "$S/calls"
r=$(PARITY_STALL_N=3 census_stall 2>&1)
rm -f "$S/stall-stuck"
expect census_stall_left_said grep -q '^ext4 stopped: stall-ext4.img left attached at iteration 1 of loop 1; the rest not measured$' "$P/stall-summary.txt"
expect census_stall_left_one_attach test "$(grep -c '^hdiutil attach .*stall-ext4.img$' "$S/calls")" -eq 1
expect census_stall_left_setup grep -q '^ext4-loop1-1: setup failed: stall-ext4.img left attached$' "$P/stall.txt"
expect census_stall_left_loop1 grep -q '^ext4 loop 1: 0 stalls, 0 automounts, 1 setup failures of 1 (stopped: stall-ext4.img left attached)$' "$P/stall-summary.txt"
expect census_stall_left_loop2 grep -q '^ext4 loop 2: 0 stalls, 0 automounts, 0 setup failures of 0 (not run: stall-ext4.img left attached in loop 1)$' "$P/stall-summary.txt"
expect census_stall_left_no_stalls not grep -q '^ext4-loop[12]-[23]: ' "$P/stall.txt"
expect census_stall_left_hfs_ran grep -q '^hfs loop 2: .* of 3$' "$P/stall-summary.txt"
expect census_stall_left_fisher test "$(grep -c '^loop [12] .*: Fisher p not computed: ext4 stopped: stall-ext4.img left attached at iteration 1 of loop 1 ' "$P/stall-summary.txt")" -eq 2
expect census_stall_left_recorded has "$r" "^# recorded stall loop 2: hfs 0/3, ext4 0/0, Fisher p not computed (ext4 stopped: stall-ext4.img left attached at iteration 1 of loop 1)$"
for f in "$S"/nodes/*; do case $f in *.m | *.u) ;; *) test -f "$f" || continue; case $(sed -n "s/^vol=//p" "$f") in *stall-ext4*) rm -f "$f" "$f.m" "$f.u" ;; esac ;; esac; done   # drop_stuck, defined later

# census_busy: 20 write-then-unmount cycles per volume (a busy one says who held it), the held-file cases through parity,
#   and the forced ones on the HFS+ side only. Item 4 is checked (PARITY_MODE_BUSY defaults to check), but for the steps
#   DiskArbitration's tie to a linuxfs disk decides too (PARITY_MODE_BUSY_DA, checked since Task 16's fsname=/dev/<bsd>)
r=$(unset PARITY_MODE_BUSY PARITY_MODE_BUSY_DA; . "$here/lib/parity.sh"; echo "$PARITY_MODE_BUSY $PARITY_MODE_BUSY_DA")
expect census_busy_modes test "$r" = "check check"
: > "$S/calls"
r=$(census_busy ext4 2>&1)
expect census_busy_cycles grep -q '^hfs: busy 0 of 20$' "$P/busy.ext4.cycles.txt"
expect census_busy_cycles_fs grep -q '^ext4: busy 1 of 20$' "$P/busy.ext4.cycles.txt"
expect census_busy_lsof grep -q 'stub lsof' "$P/busy.ext4.cycles.txt"
expect census_busy_ps grep -q '^-- ps (mds, mdworker, fseventsd, Finder)' "$P/busy.ext4.cycles.txt"
expect census_busy_dissenter grep -q '^-- dissenter' "$P/busy.ext4.cycles.txt"
for s in shell-unmount shell-eject textedit-unmount textedit-eject finder-eject; do
  expect "census_busy_$s" test -s "$P/busy.ext4.$s.hfs.txt" -a -s "$P/busy.ext4.$s.ext4.txt"
done
expect census_busy_force-eject_hfs_only test -s "$P/busy.ext4.force-eject.hfs.txt" -a ! -e "$P/busy.ext4.force-eject.ext4.txt"
# Task 13b (the hfs-force-eject kit: clean on a busy ext4 volume, like HFS+): diskutil unmount force runs on both, held,
#   and is checked by its status and whether the volume went; since Task 16 (fsname=/dev/<bsd>) by diskutil's words too, under
#   PARITY_MODE_BUSY_DA
expect census_busy_force_unmount_both test -s "$P/busy.ext4.force-unmount.hfs.txt" -a -s "$P/busy.ext4.force-unmount.ext4.txt"
expect census_busy_force_unmount_checked has "$r" "^ok - parity busy.ext4.force-unmount$"
expect census_busy_force_unmount_gone grep -q '^mounted afterwards: no$' "$P/busy.ext4.force-unmount.ext4.txt"
expect census_busy_force_unmount_words grep -q '^Volume <VOL> on <DISK> unmounted$' "$P/busy.ext4.force-unmount.ext4.txt"
expect census_busy_textedit grep -q 'open -a TextEdit' "$S/calls"
expect census_busy_finder grep -q 'eject disk' "$S/calls"
expect census_busy_shot test "$(grep -c 'screencapture -x .*-busy-eject.png' "$S/calls")" -eq 2
expect census_busy_force_hfs grep -q '^diskutil unmount force .*/vols/busy-hfs-ext4$' "$S/calls"
expect census_busy_force_unmount_fs grep -q '^diskutil unmount force .*/vols/busy-ext4$' "$S/calls"
expect census_busy_eject_retried grep -q '^# census: retrying diskutil eject /dev/disk' "$P/busy.ext4.cycles.txt"
expect census_busy_eject_lsof grep -q '^#   COMMAND PID USER (stub lsof lsof .*/vols/busy-ext4)' "$P/busy.ext4.cycles.txt"
# (a)'s bar: ext4 busy once (the stub's busy-ext4), HFS+ never: not ok, and why; the only not ok
expect census_busy_bar_notok has "$r" "^not ok - parity busy.ext4.cycles (hfs 0 of 20, ext4 1 of 20)$"
expect census_busy_bar_why has "$r" "^parity: ext4 was busy more often than HFS+$"
expect census_busy_quiet test "$(printf '%s\n' "$r" | grep -c 'not ok')" -eq 1
# item 4's (a) with fsevents on (Task 15): each side's cycles say whether fseventsd had made .fseventsd, checked under
#   PARITY_MODE_SPOTLIGHT
expect census_busy_fsevents_said grep -q '^ext4: fsevents: .fseventsd yes$' "$P/busy.ext4.cycles.txt"
expect census_busy_fsevents_said_hfs grep -q '^hfs: fsevents: .fseventsd yes$' "$P/busy.ext4.cycles.txt"
expect census_busy_fsevents_ok has "$r" "^ok - parity spotlight.ext4.busy-fsevents (item 4 (a) with fsevents on: .fseventsd on disk after the cycles, so fseventsd let in at least once: hfs yes, ext4 yes)$"
# (a)'s eject cycles, each side PARITY_BUSY_EJECTS (3) times with another HFS+ copy coming and going: checked since Task 16,
#   linuxfs busy no more often than HFS+ (0 of 3)
expect census_busy_ejects_checked has "$r" "^ok - parity busy.ext4.ejects (hfs 0 of 3, ext4 0 of 3)$"
# the other volume is the HFSX control (another UUID and name), not a second copy of the HFS+ one
expect census_busy_ejects_other test "$(grep -c '^hdiutil attach .*busy-hfsx-other-ext4.img$' "$S/calls")" -eq 6
expect census_busy_ejects_not_hfs_copy not grep -q 'busy-hfs-other' "$S/calls"
expect census_busy_ejects_said grep -q '^ext4: eject busy 0 of 3$' "$P/busy.ext4.cycles.txt"
# (b): the shell's eject is checked; since Task 16 (fsname=/dev/<bsd>: diskutil words linuxfs's unmounts as HFS+'s) so are
#   the unmounts, TextEdit's eject and Finder's
expect census_busy_shell_eject_checked has "$r" "^ok - parity busy.ext4.shell-eject$"
for s in shell-unmount textedit-unmount textedit-eject finder-eject; do expect "census_busy_${s}_checked" has "$r" "^ok - parity busy.ext4.$s$"; done
expect census_busy_sysctl test -s "$P/busy-ext4.sysctl.txt"
# every mount is said, census_busy_cycles' remounts too (20 of them, and the attach)
expect census_names_busy_remounts test "$(grep -c '/vols/busy-ext4: exact' "$P/names-mode.txt")" -ge 21
# spec: .superpowers/sdd/2026-11-25-hfs-parity/task-16e-fix-brief.md -- push E's busy.ext4.cycles red: a busy unmount records
#       who held the volume at once (before the pause), and the HFS+ control carries linuxfs's custom volume icon
bl=$P/busy.ext4.cycles.txt
expect "census_busy_cycles: a busy unmount records the whole lsof table matched on the mount point, taken before the pause" \
  awk '/^-- sudo lsof -n -P \+c0 \(the whole table\), the lines naming / { h = NR } h && /^Finder 79271 stubuser .*\/vols\/busy-ext4\/.VolumeIcon.icns$/ { f = NR }
    h && !o && /stub-elsewhere/ { bad = 1 } f && /^-- once more: / { o = NR } END { exit !(f && o && !bad) }' "$bl"
expect "census_busy_cycles: a busy unmount records the opens on the volume since its mount (fs_usage)" \
  awk '/^-- fs_usage -w -f pathname: opens naming / { h = 1; next } /^-- / { h = 0 } h && /\/vols\/busy-ext4\/.VolumeIcon.icns .*Finder.79271$/ { f = 1 }
    h && /stub-elsewhere/ { bad = 1 } END { exit !(f && !bad) }' "$bl"
fsu_gone() { test -s "$S/fsu-pids" || return 1; for p in $(cat "$S/fsu-pids"); do ! kill -0 "$p" 2> /dev/null || return 1; done; }
expect "census_busy_cycles: fs_usage never left running" fsu_gone
# the preflight's fs_usage; one over the HFS+ side's cycles; over ext4's, one stopped at its refusal and one more after:
#   each stopped by INT (fs_usage flushes at its exit), none needing TERM or KILL
expect census_busy_fs_usage_runs test "$(grep -c '^fs_usage -w -f pathname$' "$S/calls")" -eq 4
expect census_busy_fs_usage_stopped test "$(grep -c '^sudo -n kill -INT [0-9][0-9]*$' "$S/calls")" -eq 4
expect census_busy_fs_usage_int_only not grep -q '^sudo -n kill -\(TERM\|9\) ' "$S/calls"
# fix round 1: the preflight, once a smoke: sudo -n sh, sudo -n kill, and fs_usage's time column, recorded; capture on
pf=$P/fs_usage-preflight.txt
expect census_fsu_preflight_on test "$(tail -n 1 "$pf")" = "capture: on"
expect census_fsu_preflight_column grep -q '^fs_usage first column: [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]*$' "$pf"
expect census_fsu_preflight_steps sh -c 'grep -q "^sudo -n sh -c echo ok$" "$1" && grep -q "^sudo -n kill -0 [0-9]" "$1"' _ "$S/calls"
expect census_busy_fs_usage_raw_gone test -z "$(ls "$W/census" | grep fs_usage)"
expect "census_busy: the HFS+ control carries the same custom volume icon as linuxfs" \
  sh -c 'cmp -s "$1/.VolumeIcon.icns" "$2" && grep -q "^xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 .*/vols/busy-hfs-ext4$" "$3"' _ "$T/vols/busy-hfs-ext4" "$PARITY_VOLICON_OF" "$S/calls"
# each side's custom icon said before its cycles; the HFS+ control's set, then mounted again, so each counted cycle mounts with it
expect census_busy_icon_said awk '/^hfs: custom icon: yes$/ && !c { h = 1 } /^ext4: custom icon: yes$/ && c == 20 { f = 1 } /^cycle [0-9]*: / { c++ } END { exit !(h && f) }' "$bl"
expect census_busy_icon_remounted awk '/^xattr -wx .*\/vols\/busy-hfs-ext4$/ { x = 1 } x && /^diskutil unmount .*\/vols\/busy-hfs-ext4$/ { u = 1 } u && /^diskutil mount / { m = 1; exit } END { exit !m }' "$S/calls"
# census_busy_bar's icons (its 7th and 8th arguments): sides that differ prove nothing; alike, the bar as before
r=$(census_busy_bar busy.x.cycles check x "0 20" "0 20" 20 no yes 2>&1)
expect "census_busy_bar: sides that differ in custom icon prove nothing" test "$r" = "$(printf '%s\n' 'not ok - parity busy.x.cycles (hfs 0 of 20, x 0 of 20; custom icon: hfs no, x yes)' 'parity: busy.x.cycles: the sides differ in custom icon (hfs no, x yes), so it proves nothing')"
r=$(census_busy_bar busy.x.cycles check x "0 20" "0 20" 20 yes yes 2>&1)
expect census_busy_bar_same_icon test "$r" = "ok - parity busy.x.cycles (hfs 0 of 20, x 0 of 20)"
r=$(census_busy_bar busy.x.cycles record x "0 20" "0 20" 20 "" yes 2>&1)
expect census_busy_bar_icon_recorded test "$r" = "# recorded busy.x.cycles: hfs 0 of 20, x 0 of 20; custom icon: hfs unknown, x yes"
# no linuxfs.icns to give the control (the postinstall could not make it): said, and the bar, seeing the sides differ, not ok
mv "$PARITY_VOLICON_OF" "$T/volicon.away"; echo noicon > "$W/img/noicon.img"; cp "$S/calls" "$T/calls.keep"   # (ext4's calls, for the cases below)
r=$(census_busy noicon 2>&1)
mv "$T/volicon.away" "$PARITY_VOLICON_OF"; rm -f "$W/img/noicon.img"; cp "$T/calls.keep" "$S/calls"
expect census_busy_no_icon_said has "$r" "^# census_busy noicon: no $PARITY_VOLICON_OF, so the HFS+ control gets no custom icon$"
expect census_busy_no_icon_notok has "$r" "^not ok - parity busy.noicon.cycles (hfs 0 of 20, noicon 0 of 20; custom icon: hfs no, noicon yes)$"
expect census_busy_no_icon_detached test -z "$(attached)"
expect census_fsu_preflight_once test "$(grep -c '^capture: ' "$pf")" -eq 1
cp "$S/calls" "$T/calls.keep"   # (ext4's calls, for the cases after these)
# fix round 1: icons never recorded on either side (both empty) prove nothing either
r=$(census_busy_bar busy.x.cycles check x "0 20" "0 20" 20 "" "" 2>&1)
expect census_busy_bar_icons_unrecorded test "$r" = "$(printf '%s\n' 'not ok - parity busy.x.cycles (hfs 0 of 20, x 0 of 20; custom icon: recorded on neither side)' 'parity: busy.x.cycles: neither side recorded its custom icon, so it proves nothing')"
# fix round 1: an fs_usage deaf to INT and TERM is KILLed, and that said (its unflushed output lost)
: > "$S/fsu-pids"
r=$(census_pid_gone() { return 1; }; census_fsu_start "$T/deaf.txt"; census_fsu_stop 2>&1)
expect census_fsu_stop_killed has "$r" "^-- fs_usage [0-9]* did not exit on INT or TERM: KILLed, its unflushed output lost$"
expect census_fsu_stop_kill_order awk '/^sudo -n kill -INT / { i = NR } /^sudo -n kill -TERM / && i { t = NR } /^sudo -n kill -9 / && t { k = 1 } END { exit !k }' "$S/calls"
fsu_dead() { test -s "$S/fsu-pids" || return 1; for p in $(cat "$S/fsu-pids"); do ! ps -o stat= -p "$p" 2> /dev/null | grep -qv '^ *Z' || return 1; done; }
dead=; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do fsu_dead && { dead=1; break; }; /bin/sleep 0.1; done
expect census_fsu_stop_killed_gone test -n "$dead"
# fix round 1 (I1): the abort path: a census subshell that ends without its stop (the smoke signalled) leaves fs_usage
#   running; census_fsu_abort, which finish runs, stops it by its pid file, then pkills any fs_usage left
: > "$S/fsu-pids"; : > "$S/calls"
( census_fsu_start "$T/abort.txt"; bounded 50 census_fsu_pidfile )
r=$(census_fsu_abort 2>&1)
dead=; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do fsu_dead && { dead=1; break; }; /bin/sleep 0.1; done
expect "census_fsu_abort: the abort path leaves no fs_usage running" test -n "$dead"
expect census_fsu_abort_int grep -q '^sudo -n kill -INT [0-9]' "$S/calls"
expect census_fsu_abort_pkill grep -q '^sudo -n pkill -x fs_usage$' "$S/calls"
expect census_fsu_abort_pidfile_gone test ! -e "$W/census/fs_usage.pid"
r=$(census_fsu_abort 2>&1); expect census_fsu_abort_idle test -z "$r"
expect smoke_finish_stops_fs_usage test -n "$(awk '/^finish\(\) \{/ { p = 1 } p && /census_fsu_abort/ { print; exit } p && /^}/ { exit }' "$here/smoke-mavericks.sh")"
expect smoke_traps_signals grep -q "^trap '.*finish' INT TERM HUP$" "$here/smoke-mavericks.sh"
# fix round 2: finish takes the trap away first (a signal during a normal finish does not start it again); the trap is set
#   only once what finish reads is (W made afresh, CRASH0), and a die before then exits without finish
expect smoke_finish_untraps_first test "$(awk '/^finish\(\) \{/ { p = 1; next } p && !/^ *#/ { print; exit }' "$here/smoke-mavericks.sh")" = "  trap - INT TERM HUP"
expect smoke_trap_after_setup awk '/^CRASH0=/ { c = NR } /^trap .* INT TERM HUP$/ { t = NR } END { exit !(c && t > c) }' "$here/smoke-mavericks.sh"
expect smoke_finish_ready_with_trap awk '/^CRASH0=/ { c = 1 } c && /^finish_ready=1/ { r = NR } /^trap .* INT TERM HUP$/ { t = NR } END { exit !(r && t == r + 1) }' "$here/smoke-mavericks.sh"
expect smoke_die_before_setup grep -q '^die() { notok "$1"; test -n "${finish_ready:-}" || exit 1; finish; }$' "$here/smoke-mavericks.sh"
# fix round 1: sudoers refusing kill: the preflight says capture off and why; the cycles then capture nothing (no fs_usage
#   started), say so at a refusal, and still count and bar as before
mv "$pf" "$T/pf.keep"; : > "$S/sudo-kill-refused"; : > "$S/calls"
census_fsu_preflight > /dev/null 2>&1
expect census_fsu_preflight_off test "$(tail -n 1 "$pf")" = "capture: off (sudo -n kill refused)"
rm -f "$S/busy-once"; echo x > "$W/census/busy-ext4-pf.img"
r=$(census_busy_cycles ext4 "$W/census/busy-ext4-pf.img" "$T/pf.log" 2>&1)
expect census_fsu_off_counted test "$r" = "1 20"
expect census_fsu_off_said grep -q '^-- fs_usage: not captured (capture: off (sudo -n kill refused))$' "$T/pf.log"
expect census_fsu_off_lsof_kept grep -q '^-- sudo lsof -n -P +c0 (the whole table)' "$T/pf.log"
expect census_fsu_off_no_start not grep -q '^fs_usage ' "$S/calls"
rm -f "$S/sudo-kill-refused" "$W/census/busy-ext4-pf.img" "$T/pf.log"; mv "$T/pf.keep" "$pf"; cp "$T/calls.keep" "$S/calls"
# census_busy_fsevents WHAT FS LOG, on its own: not ok when a side said no, or said nothing; recorded under record
printf '%s\n' 'hfs: fsevents: .fseventsd yes' 'xfs: fsevents: .fseventsd no' > "$T/bf.log"
r=$(census_busy_fsevents spotlight.xfs.busy-fsevents xfs "$T/bf.log" 2>&1)
expect census_busy_fsevents_notok has "$r" "^not ok - parity spotlight.xfs.busy-fsevents (item 4 (a) with fsevents on: .fseventsd on disk after the cycles, so fseventsd let in at least once: hfs yes, xfs no)$"
expect census_busy_fsevents_why has "$r" "^parity: spotlight.xfs.busy-fsevents: fseventsd did not make .fseventsd on both volumes, so (a) did not run with fsevents on$"
r=$(: > "$T/bf.log"; census_busy_fsevents spotlight.xfs.busy-fsevents xfs "$T/bf.log" 2>&1)
expect census_busy_fsevents_unknown has "$r" "^not ok - parity spotlight.xfs.busy-fsevents (item 4 (a) with fsevents on: .fseventsd on disk after the cycles, so fseventsd let in at least once: hfs unknown, xfs unknown)$"
r=$(PARITY_MODE_SPOTLIGHT=record; census_busy_fsevents spotlight.xfs.busy-fsevents xfs "$T/bf.log" 2>&1)
expect census_busy_fsevents_record test "$r" = "# recorded spotlight.xfs.busy-fsevents: item 4 (a) with fsevents on: .fseventsd on disk after the cycles, so fseventsd let in at least once: hfs unknown, xfs unknown"
rm -f "$T/bf.log"
# item 2 (Task 13b): census_finder_ask dismisses what its step left up (busy-eject's dialog) before the next side's shot
expect census_busy_dialogs grep -q '^busy-eject: OK: ' "$P/dialogs.txt"
# item 3 (Task 13b, fix round 1): a busy-eject shot is not awaited: on 10.9 Finder's eject alerts are invisible to System
#   Events, so a wait for one would always run out; it is taken after a fixed 3 s, and that said
expect census_busy_eject_not_awaited not grep -q '^busy-eject ext4: seen' "$P/shots.txt"
expect census_busy_eject_not_awaited_said grep -q '^busy-eject ext4: not awaited: Finder.s eject alerts are invisible to System Events on 10.9; photographed after 3 s (busy-eject-3s) and 15 s (busy-eject)$' "$P/shots.txt"
# (fix round 2) push C's HFS+ alert was not up 4 s in: each side is photographed twice, at 3 s and at 15 s, both kept
expect census_busy_eject_two_shots test "$(grep -c 'screencapture -x .*-busy-eject-3s.png' "$S/calls")" -eq 2
expect census_busy_eject_bound test -n "$(sed -n '/^census_busy()/,/^}/p' "$here/lib/parity.sh" | grep 'census_bound 1800 census_busy_parity "$cb_m" "busy.$cb_fs.finder-eject"')"
expect census_busy_eject_restarted grep -q '^busy-eject: restarted Finder after an eject (alerts invisible to System Events on 10.9)$' "$P/dialogs.txt"
expect census_busy_detached test -z "$(attached)"
# census_finder_ask dismisses the console's alerts before osascript starts, never between it and its shot (osascript
#   runs in the background, so its line and the shot's come in either order: a dismissal finds both or neither)
ask_dismissed_first() { awk '/killall UserNotificationCenter$/ { if (o != s) bad = 1; o = 0; s = 0; d = 1; next } /osascript .*eject disk/ { if (!d || o) bad = 1; o = 1; d = 0 } /screencapture -x .*busy-eject.png$/ { if (s) bad = 1; s = 1 } END { exit bad || o != s }' "$S/calls"; }
expect census_busy_finder_dismissed_first ask_dismissed_first
expect census_busy_eject_failed_record grep -q '^#   COMMAND PID USER (stub lsof lsof .*/vols/busy-ext4)' "$P/eject-failed.txt"
# a linuxfs disk whose eject fails is recorded (lsof on its device, the lklfuse processes) and left attached, not
#   forced; the busy steps go on, each with a fresh copy
echo stuck6 > "$W/img/stuck6.img"; : > "$P/eject-failed.txt"
r=$(PARITY_MODE_BUSY_DA=record; census_busy stuck6 2>&1)   # (the leftovers' handling; the stuck disk's da steps differ, recorded)
for s in shell-unmount shell-eject textedit-unmount textedit-eject finder-eject; do
  expect "census_busy_stuck_$s" test -s "$P/busy.stuck6.$s.hfs.txt" -a -s "$P/busy.stuck6.$s.stuck6.txt"
done
for s in force-unmount force-eject; do expect "census_busy_stuck_$s" test -s "$P/busy.stuck6.$s.hfs.txt"; done
expect census_busy_stuck_lsof_dev grep -q '^#   COMMAND PID USER (stub lsof lsof /dev/disk[0-9]* /dev/rdisk[0-9]*)$' "$P/eject-failed.txt"
expect census_busy_stuck_lklfuse grep -q '^# census: lklfuse processes' "$P/eject-failed.txt"
expect census_busy_stuck_ps_stub grep -q '^#   stubuser 4242 1 .*stub-lklfuse-line$' "$P/eject-failed.txt"
expect census_busy_stuck_fresh has "$r" "^# census_busy stuck6: .* left attached; the steps go on with a fresh copy"
# checked, the shell's eject differs: HFS+'s ejects, the stuck disk's never does; nothing else is not ok
expect census_busy_stuck_eject_notok has "$r" "^not ok - parity busy.stuck6.shell-eject$"
expect census_busy_stuck_quiet test "$(printf '%s\n' "$r" | grep -c 'not ok')" -eq 1
expect census_busy_stuck_no_ejects grep -q '^stuck6: eject cycles not run: busy-stuck6.img is still attached$' "$P/busy.stuck6.cycles.txt"
expect census_busy_stuck_df grep -q '^# census: df -k .*: [0-9]* KiB free, floor 1 KiB and [0-9]* KiB to copy' "$P/eject-failed.txt"
expect census_busy_stuck_lklfuse_count grep -q '^# census: lklfuse processes now: [0-9]*$' "$P/eject-failed.txt"
stuck_disks() { for f in "$S"/nodes/*; do case $f in *.m | *.u) ;; *) test -f "$f" || continue; case $(sed -n 's/^vol=//p' "$f") in *$1*) sed -n 's/^disk=//p' "$f" ;; esac ;; esac; done; }
drop_stuck() { for f in "$S"/nodes/*; do case $f in *.m | *.u) ;; *) test -f "$f" || continue; case $(sed -n 's/^vol=//p' "$f") in *$1*) rm -f "$f" "$f.m" "$f.u" ;; esac ;; esac; done; }
sd=$(stuck_disks stuck6); nf=
for d in $sd; do grep -qx "$d" "$S/fsdisks" || nf="$nf $d"; done
expect census_busy_stuck_count test "$(printf '%s\n' $sd | grep -c .)" -eq 7
expect census_busy_stuck_in_fsdisks test -n "$sd" -a -z "$nf"
drop_stuck stuck6
rm -f "$W/img/stuck6.img"
# below the free-space floor no fresh copy is made: said, recorded, and the busy steps stop for that filesystem
echo stuck7 > "$W/img/stuck7.img"; : > "$P/eject-failed.txt"
r=$(PARITY_FREE_FLOOR_KB=999999999999 PARITY_MODE_BUSY_DA=record; census_busy stuck7 2>&1)
expect census_busy_floor_said has "$r" "^# census_busy stuck7: .* KiB free on .*, under the floor .*: no fresh copy, so the busy steps stop"
expect census_busy_floor_recorded grep -q 'under the floor' "$P/eject-failed.txt"
expect census_busy_floor_stops test ! -e "$P/busy.stuck7.shell-eject.stuck7.txt"
expect census_busy_floor_no_copy test ! -e "$W/census/busy-stuck7-2.img"
expect census_busy_floor_quiet hasnt "$r" "not ok"
drop_stuck stuck7
rm -f "$W/img/stuck7.img"
# push A's spurious busy eject (item-4-findings.md), reproduced: a linuxfs disk is untied from its mount by another
#   volume's mount or unmount (the stub's da-forgets), so its eject fails busy with the volume still mounted; recorded
#   with who holds it, DiskArbitration's view and mount's line, then freed by unmounting its mount point
echo calm > "$W/img/calm.img"; : > "$S/da-forgets"
r=$(PARITY_MODE_BUSY_DA=record; census_busy calm 2>&1)
expect census_busy_calm_bar has "$r" "^ok - parity busy.calm.cycles (hfs 0 of 20, calm 0 of 20)$"
expect census_busy_untied_recorded has "$r" "^# recorded busy.calm.ejects: hfs 0 of 3, calm 3 of 3$"
# force-unmount's comparison goes by PARITY_MODE_BUSY_DA (diskutil's words come from DiskArbitration), not PARITY_MODE_BUSY:
#   recorded here, where only the da mode is record
expect census_busy_force_unmount_da has "$r" "^# recorded busy.calm.force-unmount$"
expect census_busy_force_unmount_da_only test "$PARITY_MODE_BUSY" = check
expect census_busy_untied_busy grep -q '^calm eject 1: BUSY: Volume failed to eject$' "$P/busy.calm.cycles.txt"
expect census_busy_untied_da grep -q '^# census: DiskArbitration: disk[0-9]* Mounted: No$' "$P/busy.calm.cycles.txt"
expect census_busy_untied_mount grep -q '^#   /dev/disk[0-9]* on .*/vols/busy-calm (macfuse_ext4' "$P/busy.calm.cycles.txt"
expect census_busy_untied_freed grep -q '^-- freed as a user would: Volume busy-calm on disk[0-9]* unmounted$' "$P/busy.calm.cycles.txt"
expect census_busy_untied_hfs grep -q '^hfs: eject busy 0 of 3$' "$P/busy.calm.cycles.txt"
# a busy eject's volume is freed, and its lklfuse waited for (census_lklfuse_gone), before the eject: no failure block
#   follows it in the cycles' record
expect census_busy_untied_no_race not grep -q '^# census: .* diskutil eject /dev/disk[0-9]* failed' "$P/busy.calm.cycles.txt"
expect census_busy_untied_waits test -n "$(sed -n '/^census_busy_ejects()/,/^}/p' "$here/lib/parity.sh" | grep 'bounded 300 census_lklfuse_gone "$be_mp"')"
# checked, the eject cycles' bar fails for it: linuxfs busier than HFS+
drop_stuck calm; drop_stuck busy-hfs
r=$(PARITY_MODE_BUSY_DA=check; census_busy calm 2>&1)
expect census_busy_untied_notok has "$r" "^not ok - parity busy.calm.ejects (hfs 0 of 3, calm 3 of 3)$"
rm -f "$S/da-forgets"; drop_stuck calm; drop_stuck busy-hfs
# the forced steps are recorded, never checked, even when PARITY_BUSY_FORCE=1 runs them on linuxfs too (preflight F14);
#   a step's own mode leaves PARITY_MODE_BUSY as it was
r=$(reset; pair; PARITY_MODE_BUSY=check; census_busy_parity record busy.x.force-unmount ls @MP@ 2>&1; echo "after: $PARITY_MODE_BUSY")
expect census_busy_parity_record test "$r" = "$(printf '%s\n' '# recorded busy.x.force-unmount' 'after: check')"
r=$(reset; pair; touch "$T/b/extra"; PARITY_MODE_BUSY=record PARITY_MODE_BUSY_DA=check; census_busy_parity da busy.x.da ls @MP@ 2>&1; echo "after: $PARITY_MODE_BUSY")
expect census_busy_parity_da has "$r" "^not ok - parity busy.x.da$"
expect census_busy_parity_da_restored has "$r" "^after: record$"
expect census_busy_forced_recorded test "$(grep -c 'census_busy_parity record "busy.$cb_fs.$cb_step"' "$here/lib/parity.sh")" -eq 1
# a cycle whose other volume never attached proves nothing: not counted (IMAGE is still ejected)
echo calm > "$W/census/m1-calm.img"; echo x > "$W/census/nevermount-other.img"; : > "$T/m1.log"
r=$(census_busy_ejects calm "$W/census/m1-calm.img" "$W/census/nevermount-other.img" "$T/m1.log" 2>/dev/null | tail -n 1)
expect census_busy_ejects_no_other test "$r" = "0 0"
expect census_busy_ejects_no_other_said grep -q '^calm eject 1: the other volume did not attach; not counted$' "$T/m1.log"
expect census_busy_ejects_no_other_ejected test -z "$(census_image_disk "$W/census/m1-calm.img")"
rm -f "$W/census/m1-calm.img" "$W/census/nevermount-other.img"
# census_lklfuse_gone MP: waits while an lklfuse serves MP (its command's last argument), and no longer
lg() { (ps() { if test -s "$T/lg.n"; then n=$(cat "$T/lg.n"); echo $((n - 1)) > "$T/lg.n"; test "$n" -le 0 || echo "u /p/lklfuse -f -o x /dev/fd/3 /Volumes/m"; fi; echo "u /p/lklfuse -f /dev/fd/3 /Volumes/m 2"; }; bounded 100 census_lklfuse_gone /Volumes/m); }
echo 2 > "$T/lg.n"; lg; expect census_lklfuse_gone_waits test "$(cat "$T/lg.n")" -eq -1
echo 0 > "$T/lg.n"; lg; expect census_lklfuse_gone_other_mp test "$(cat "$T/lg.n")" -eq -1
rm -f "$T/lg.n"
# a side whose cycles did not all run proves nothing: not ok in check mode
r=$(census_busy_bar busy.x.cycles check x "0 20" "0 7" 20 2>&1)
expect census_busy_bar_short has "$r" "^not ok - parity busy.x.cycles (hfs 0 of 20, x 0 of 7)$"
expect census_busy_bar_short_why has "$r" "did not run 20 times on each side, so it proves nothing$"
r=$(census_busy_bar busy.x.cycles check x "hung: x" "0 20" 20 2>&1)
expect census_busy_bar_garbled has "$r" "^not ok - parity busy.x.cycles (hfs 0 of 0, x 0 of 0)$"
r=$(census_busy_bar busy.x.cycles chekc x "0 20" "0 20" 20 2>&1)
expect census_busy_bar_badmode has "$r" "^not ok - parity busy.x.cycles$"
drop_stuck calm; drop_stuck busy-hfs
rm -f "$W/img/calm.img"

# census_spotlight: read-write, then read-only (HFS+ attach -readonly against ext4 with ReadOnly on). Item 5 is checked
#   (Task 15: PARITY_MODE_SPOTLIGHT defaults to check). The world push D hopes for first: indexing on for the HFS+
#   control (the stub's mdutil -s says enabled) and fseventsd let into the linuxfs volume, so every step but the file's
#   making and the refusals (each pass's own record; census_refusals_bar is their check) is checked, and ok
r=$(unset PARITY_MODE_SPOTLIGHT; . "$here/lib/parity.sh"; echo "$PARITY_MODE_SPOTLIGHT")
expect census_spotlight_mode test "$r" = check
: > "$S/calls"
r=$(census_spotlight ext4 2>&1)
for p in rw ro; do
  for s in mdfind store fseventsd; do
    expect "census_spotlight_on_${p}_$s" has "$r" "^ok - parity spotlight.ext4.$p.$s\$"
  done
  # (fix round 1, m4) mdutil by mount point, privacy-off and the remount hit item 6's f_mntfromname on linuxfs: they take
  #   PARITY_MODE_SPOTLIGHT_DA, checked since Task 16's fsname=/dev/<bsd>
  for s in mdutil privacy-off privacy-remount; do
    expect "census_spotlight_on_${p}_${s}_da" has "$r" "^ok - parity spotlight.ext4.$p.$s\$"
  done
  expect "census_spotlight_on_${p}_said" has "$r" "^# spotlight.ext4.$p: the indexing steps are checked: indexing is on for the HFS+ control\$"
  expect "census_spotlight_on_${p}_mode_file" grep -q '^check: indexing is on for the HFS+ control$' "$P/spotlight.ext4.$p.index-mode.txt"
  expect "census_spotlight_on_${p}_refusals_recorded" has "$r" "^# recorded spotlight.ext4.$p.refusals\$"
done
expect census_spotlight_on_refresh has "$r" "^ok - parity spotlight.ext4.rw.refresh$"
expect census_spotlight_on_create has "$r" "^# recorded spotlight.ext4.rw.create$"
expect census_spotlight_on_fseventsd grep -q '^.fseventsd: yes$' "$P/spotlight.ext4.rw.fseventsd.ext4.txt"
expect census_spotlight_on_store grep -q '^.Spotlight-V100: no$' "$P/spotlight.ext4.rw.store.ext4.txt"
expect census_spotlight_on_quiet hasnt "$r" "not ok"
expect census_spotlight_on_detached test -z "$(attached)"
r=$(unset PARITY_MODE_SPOTLIGHT_DA; . "$here/lib/parity.sh"; echo "$PARITY_MODE_SPOTLIGHT_DA")
expect census_spotlight_da_mode test "$r" = check
rm -f "$OUT"/*-refresh.png "$OUT"/*-privacy.png "$OUT"/*-privacy-ro.png
r=$(PARITY_MODE_SPOTLIGHT_DA=record; census_spotlight ext4 2>&1)
for s in mdutil privacy-off privacy-remount; do expect "census_spotlight_da_record_$s" has "$r" "^# recorded spotlight.ext4.rw.$s\$"; done
rm -f "$OUT"/*-refresh.png "$OUT"/*-privacy.png "$OUT"/*-privacy-ro.png
r=$(PARITY_MODE_SPOTLIGHT_DA=check; census_spotlight ext4 2>&1)
for s in mdutil privacy-off privacy-remount; do expect "census_spotlight_da_check_$s" has "$r" "^ok - parity spotlight.ext4.rw.$s\$"; done
# census_fs_mp NODE [slices] (Task 16): a linuxfs mount is told by its type, one of the six, now that DiskArbitration's are
#   named /dev/<bsd> as the Mac's are
printf '%s\n' '/dev/disk0s2 on / (hfs, local, journaled)' '/dev/disk3s1 on /Volumes/my (data) (macfuse_ext4, local, nodev)' \
  '/dev/disk4 on /Volumes/hfs (hfs, local)' '/dev/disk5 on /Volumes/other (macfuse, local)' '/dev/disk6 on /Volumes/x (macfuse_ext4x, local)' \
  '/dev/disk7 on /Volumes/whole (macfuse_xfs, local)' '/dev/disk3s10 on /Volumes/ten (macfuse_ext4, local)' > "$T/fsmp"
expect census_fs_mp_slice test "$(census_fs_mp disk3s1 < "$T/fsmp")" = "/Volumes/my (data)"
expect census_fs_mp_whole test "$(census_fs_mp /dev/disk7 < "$T/fsmp")" = /Volumes/whole
expect census_fs_mp_slices test "$(census_fs_mp disk3 slices < "$T/fsmp")" = "/Volumes/my (data)"
expect census_fs_mp_no_slices test -z "$(census_fs_mp disk3 < "$T/fsmp")"
expect census_fs_mp_hfs test -z "$(census_fs_mp disk4 slices < "$T/fsmp")"
expect census_fs_mp_family test -z "$(census_fs_mp disk5 < "$T/fsmp")$(census_fs_mp disk6 < "$T/fsmp")"
expect census_fs_mp_exact test -z "$(census_fs_mp disk3s1 < "$T/fsmp" | grep ten)"
rm -f "$T/fsmp"
# (fix round 1, m5) the ro pass waits (bounded) for .fseventsd on both volumes after the read-write mount that makes its file
expect census_spotlight_ro_waits test -n "$(sed -n '/^census_spotlight()/,/^}/p' "$here/lib/parity.sh" | grep 'census_fsevents_wait "$PARITY_CTL_MP" "$PARITY_FS_MP"')"
mkdir -p "$T/fw1/.fseventsd" "$T/fw2"
r=$(bounded 100 census_fsevents_wait "$T/fw1"; echo "rc $?")
expect census_fsevents_wait_there test "$r" = "rc 0"
: > "$T/sleeps"; r=$(bounded 100 census_fsevents_wait "$T/fw1" "$T/fw2"; echo "rc $?")
expect census_fsevents_wait_gives_up test "$r" = "rc 1" -a "$(grep -c '^sleep 1$' "$T/sleeps")" -eq 5
rm -rf "$T/fw1" "$T/fw2"
# push C's world: mdutil -i on fails -400 on the HFS+ control, mdutil -s says unknown, and root's fseventsd is refused on
#   the linuxfs volume: the indexing steps are recorded, said why, and .fseventsd's parity is not ok in each pass
#   (the first run's shots removed: census_shot takes HFS+'s once a run)
rm -f "$OUT"/*-refresh.png "$OUT"/*-privacy.png "$OUT"/*-privacy-ro.png
: > "$S/calls"; : > "$S/mdutil-400"; : > "$S/mdutil-unknown"; : > "$S/fsevents-refused"
r=$(census_spotlight ext4 2>&1)
rm -f "$S/mdutil-400" "$S/mdutil-unknown" "$S/fsevents-refused"
for p in rw ro; do
  for s in mdutil mdfind store privacy-off privacy-remount; do
    expect "census_spotlight_off_${p}_$s" has "$r" "^# recorded spotlight.ext4.$p.$s\$"
  done
  expect "census_spotlight_off_${p}_said" has "$r" "^# spotlight.ext4.$p: the indexing steps are recorded: indexing could not be turned on for the HFS+ control (mdutil -s: <MP>: Error: unknown indexing state.)\$"
  expect "census_spotlight_off_${p}_mode_file" grep -q '^record: indexing could not be turned on' "$P/spotlight.ext4.$p.index-mode.txt"
  expect "census_spotlight_off_${p}_fseventsd" has "$r" "^not ok - parity spotlight.ext4.$p.fseventsd\$"
done
expect census_spotlight_off_refresh has "$r" "^# recorded spotlight.ext4.rw.refresh$"
expect census_spotlight_off_only_fseventsd test "$(printf '%s\n' "$r" | grep -c 'not ok')" -eq 2
# item 5 (Task 13b): mdutil -i on failing -400 on the HFS+ control (push C) is followed, there alone, by mdutil -E and -i on
#   once more, all in index-on's record; and each pass keeps Spotlight's own state (the boot volume's, mds's job, its
#   stores and the volumes' mount flags) in spotlight.ext4.PASS.diagnosis.txt
for p in rw ro; do
  expect "census_spotlight_${p}_index_on_400" grep -q '(-400)' "$P/spotlight.ext4.$p.index-on.hfs.txt"
  expect "census_spotlight_${p}_index_on_erase" grep -q '^== sudo -n mdutil -E <MP>$' "$P/spotlight.ext4.$p.index-on.hfs.txt"
  expect "census_spotlight_${p}_index_on_again" grep -q '^== sudo -n mdutil -i on <MP>, again$' "$P/spotlight.ext4.$p.index-on.hfs.txt"
  expect "census_spotlight_${p}_diagnosis" grep -q '^== mdutil -s /$' "$P/spotlight.ext4.$p.diagnosis.txt"
done
expect census_spotlight_erase_hfs_only not grep -q '^sudo -n mdutil -E .*/vols/spotlight-ext4-' "$S/calls"
for p in rw ro; do
  for s in mdutil mdfind store fseventsd refusals privacy-off privacy-remount; do
    expect "census_spotlight_${p}_$s" test -s "$P/spotlight.ext4.$p.$s.hfs.txt" -a -s "$P/spotlight.ext4.$p.$s.ext4.txt"
  done
  for f in refusals-all processes lsof mdfind-seconds; do expect "census_spotlight_${p}_$f" test -e "$P/spotlight.ext4.$p.$f.txt"; done
  expect "census_spotlight_${p}_found" grep -q '^found: <MP>/parity-spot-' "$P/spotlight.ext4.$p.mdfind.ext4.txt"
done
# not found: mdfind is asked until PARITY_SPOT_SECS have passed by the clock, then that is said and recorded
mkdir -p "$T/nofind"; : > "$T/nofind.secs"
t0=$(date +%s); rnf=$(PARITY_SPOT_SECS=1; bounded 100 census_mdfind "$T/nofind" nothing "$T/nofind.secs" 2>&1); t1=$(date +%s)
expect census_mdfind_not_found test "$rnf" = "not found within 1 s" -a "$(cat "$T/nofind.secs")" = "$T/nofind: not found within 1 s"
expect census_mdfind_by_clock test $((t1 - t0)) -ge 1
expect census_spotlight_refresh test -s "$P/spotlight.ext4.rw.refresh.hfs.txt" -a -s "$P/spotlight.ext4.rw.refresh.ext4.txt" -a ! -e "$P/spotlight.ext4.ro.refresh.ext4.txt"
expect census_spotlight_dirs grep -q '^.fseventsd: no$' "$P/spotlight.ext4.rw.fseventsd.ext4.txt"
# pid 1's owner is the host's own: root on a Mac, the build user in the Linux container
pid1=$(ps -o uid=,user= -p 1 2> /dev/null | sed 's/^ *//; s/  */ /g')
expect census_spotlight_refusal_uid grep -qxF "#   pid 1: uid ${pid1:-unknown (it has exited)}" "$P/spotlight.ext4.rw.refusals-all.txt"
expect census_spotlight_refusal_mp grep -q '<MP>/.fseventsd (Operation not permitted)' "$P/spotlight.ext4.rw.refusals.ext4.txt"
expect census_spotlight_refusal_not_hfs not grep -q 'Operation not permitted' "$P/spotlight.ext4.rw.refusals.hfs.txt"
expect census_spotlight_readonly grep -q '^hdiutil attach -readonly -imagekey diskimage-class=CRawDiskImage .*/spotlight-hfs-ext4-ro.img$' "$S/calls"
expect census_spotlight_rw_not_readonly not grep -q '^hdiutil attach -readonly .*-rw.img$' "$S/calls"
ro_on=$(grep -n '^linuxfs prefs ReadOnly on$' "$S/calls" | cut -d: -f1) ro_off=$(grep -n '^linuxfs prefs ReadOnly off$' "$S/calls" | cut -d: -f1)
ro_att=$(grep -n '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/spotlight-ext4-ro.img$' "$S/calls" | tail -n 1 | cut -d: -f1)
expect census_spotlight_readonly_pref ascending "$ro_on" "$ro_att" "$ro_off"
expect census_spotlight_privacy grep -q '^sudo -n mdutil -i off .*/vols/spotlight-ext4-rw$' "$S/calls"
# indexing turned on for the HFS+ control first, so mds may index it; mdutil -s recorded after, for each side
for p in rw ro; do
  ion=$(grep -n "^sudo -n mdutil -i on .*/vols/spotlight-hfs-ext4-$p\$" "$S/calls" | head -n 1 | cut -d: -f1)
  ims=$(grep -n "^mdutil -s .*/vols/spotlight-hfs-ext4-$p\$" "$S/calls" | head -n 1 | cut -d: -f1)
  expect "census_spotlight_${p}_index_on" ascending "$ion" "$ims"
  expect "census_spotlight_${p}_index_on_record" test -s "$P/spotlight.ext4.$p.index-on.hfs.txt"
done
expect census_spotlight_index_on_hfs_only not grep -q '^sudo -n mdutil -i on .*/vols/spotlight-ext4-' "$S/calls"
for s in refresh privacy privacy-ro; do expect "census_spotlight_shot_$s" test "$(grep -Ec "screencapture -x .*/(hfs|ext4)-$s.png$" "$S/calls")" -eq 2; done
expect census_spotlight_pane grep -q 'com.apple.preference.spotlight' "$S/calls"
expect census_spotlight_sysctl test -s "$P/spotlight-ext4.sysctl.txt"
expect census_spotlight_recorded has "$r" "^# recorded spotlight.ext4.ro.mdfind"
expect census_spotlight_detached test -z "$(attached)"
: > "$S/calls"; r=$(census_index_on "$T/a" 2>&1)
expect census_index_on_plain not grep -q 'mdutil -E' "$S/calls"
# census_index_mode MP: check only when PARITY_MODE_SPOTLIGHT is check and mdutil -s MP says indexing is enabled
r=$(PARITY_MODE_SPOTLIGHT=record; census_index_mode "$T/a"; echo "$CS_INDEX_MODE: $CS_INDEX_WHY")
expect census_index_mode_record test "$r" = "record: PARITY_MODE_SPOTLIGHT is record"
r=$(PARITY_MODE_SPOTLIGHT=check; census_index_mode "$T/a"; echo "$CS_INDEX_MODE: $CS_INDEX_WHY")
expect census_index_mode_check test "$r" = "check: indexing is on for the HFS+ control"
# census_spot_parity index|record|check WHAT CMD...: a step's own mode leaves PARITY_MODE_SPOTLIGHT as it was
r=$(reset; pair; touch "$T/b/extra"; PARITY_MODE_SPOTLIGHT=check CS_INDEX_MODE=record; census_spot_parity index spotlight.x.i ls @MP@ 2>&1; census_spot_parity record spotlight.x.r ls @MP@ 2>&1; census_spot_parity check spotlight.x.c ls @MP@ 2>&1; echo "after: $PARITY_MODE_SPOTLIGHT")
expect census_spot_parity_index has "$r" "^# recorded spotlight.x.i$"
expect census_spot_parity_record has "$r" "^# recorded spotlight.x.r$"
expect census_spot_parity_check has "$r" "^not ok - parity spotlight.x.c$"
expect census_spot_parity_restored has "$r" "^after: check$"
r=$(reset; pair; PARITY_MODE_SPOTLIGHT=record CS_INDEX_MODE=check; census_spot_parity index spotlight.x.i ls @MP@ 2>&1)
expect census_spot_parity_index_check test "$r" = "ok - parity spotlight.x.i"
# da: record while indexing is off; with it on, PARITY_MODE_SPOTLIGHT_DA
r=$(reset; pair; touch "$T/b/extra"; PARITY_MODE_SPOTLIGHT_DA=check CS_INDEX_MODE=record; census_spot_parity da spotlight.x.d ls @MP@ 2>&1)
expect census_spot_parity_da_off test "$r" = "# recorded spotlight.x.d"
r=$(reset; pair; touch "$T/b/extra"; PARITY_MODE_SPOTLIGHT_DA=check CS_INDEX_MODE=check; census_spot_parity da spotlight.x.d ls @MP@ 2>&1)
expect census_spot_parity_da_on has "$r" "^not ok - parity spotlight.x.d$"
r=$(reset; pair; touch "$T/b/extra"; PARITY_MODE_SPOTLIGHT_DA=record CS_INDEX_MODE=check; census_spot_parity da spotlight.x.d ls @MP@ 2>&1; echo "after: $PARITY_MODE_SPOTLIGHT")
expect census_spot_parity_da_record has "$r" "^# recorded spotlight.x.d$"
expect census_spot_parity_da_restored has "$r" "^after: check$"

# census_finder: the screenshot pairs, Finder's properties against df -k, diskutil info's fields, a custom volume icon
: > "$S/calls"
r=$(census_finder ext4 2>&1)
for s in properties diskutil-info diskutil-info-dev volumeicon; do expect "census_finder_$s" test -s "$P/finder.ext4.$s.hfs.txt" -a -s "$P/finder.ext4.$s.ext4.txt"; done
# 10.9's diskutil info has no Removable Media or Device Location: its own names, by mount point and by device
for f in Protocol Read-Only.Media Ejectable Internal; do expect "census_finder_du_$f" grep -q "^$f: " "$P/finder.ext4.diskutil-info-dev.ext4.txt"; done
expect census_finder_du_dev grep -q '^diskutil info /dev/disk[0-9]*$' "$S/calls"
expect census_finder_du_raw test "$(grep -c '^== diskutil info ' "$P/finder.ext4.diskutil-info-raw.txt")" -eq 4
# every screenshot comes after the console's alerts (the unsigned-kext one) are dismissed
dismissed_first() { awk '/killall UserNotificationCenter$/ { d = 1; next } /screencapture -x/ { if (!d) bad = 1; d = 0 } END { exit bad }' "$S/calls"; }
expect census_finder_alert_dismissed dismissed_first
expect census_finder_alert_record grep -q 'UserNotificationCenter' "$P/alerts.txt"
for s in sidebar getinfo desktop-on desktop-off icon; do expect "census_finder_shot_$s" test "$(grep -Ec "screencapture -x .*/(hfs|ext4)-$s.png$" "$S/calls")" -eq 2; done
# spec: item 6's amendment -- the icon pair's difference is recorded as expected, once, for the fs side only: census_volume_icon's
#       cp puts a real .VolumeIcon.icns on the volume (it wins over the linuxfs icon), and its Finder Info flag cannot be stored
#       until item 7 (Task 19), so Finder shows macFUSE's icon there
expect census_finder_icon_expected test "$(grep -c '^icon ext4: differs from hfs-icon.png, as expected until item 7 (Task 19): ' "$P/shots.txt")" -eq 1
expect census_finder_icon_expected_only_icon test "$(grep -c 'as expected until item 7' "$P/shots.txt")" -eq 1
expect census_finder_icon_not_by_design test "$(grep -c 'by design' "$P/shots.txt")" -eq 0
expect census_finder_props grep -q '^capacity equals df -k' "$P/finder.ext4.properties.ext4.txt"
expect census_finder_props_ejectable grep -q '^ejectable: true$' "$P/finder.ext4.properties.hfs.txt"
expect census_finder_raw grep -q 'Mac OS Extended format' "$P/finder.ext4.raw.txt"
# the 20 MiB Finder's free space lacks on ext4 and xfs (item 6): df -k before and after Finder's query and beside the
#   Get Info shot, and du -sk of what Spotlight and fseventsd keep on the volume, on both sides, recorded only
for w in "before Finder's query" "after Finder's query" "beside Get Info"; do
  expect "census_finder_space_df_$w" test "$(grep -c "^-- $w: df -k (size, used, available): [0-9]* [0-9]* [0-9]*$" "$P/finder.ext4.raw.txt")" -eq 2
  for d in .Spotlight-V100 .fseventsd; do
    expect "census_finder_space_du_${w}_$d" test "$(grep -c "^-- $w: du -sk $d: " "$P/finder.ext4.raw.txt")" -eq 2
  done
done
# (the stub logs the two-line script as two lines: sudo's, then the du loop's, ending in the volume)
expect census_finder_space_du_root sh -c 'grep -q "^sudo -n sh -c df -P -k" "$1" && grep -q "du -sk .* _ .*/vols/finder-ext4\$" "$1"' _ "$S/calls"
# one sudo of df and du, bounded at 5 s: census_finder's worst stays 30 min (29.2 + 6 x 5 s), so the census still ends by 143
expect census_finder_space_bounded grep -qF '_cs_o=$(bounded 50 sudo -n sh -c ' "$here/lib/parity.sh"
expect census_finder_space_order awk '/^-- before Finder.s query: df/ && !b { b = NR } /^Finder \(/ && !f { f = NR } /^-- beside Get Info: df/ && !g { g = NR } END { exit !(b && b < f && f < g) }' "$P/finder.ext4.raw.txt"
expect census_finder_space_not_compared hasnt "$(cat "$P/finder.ext4.properties.ext4.txt")" "^-- "
expect census_finder_icon_flag grep -q '^xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 .*/vols/finder-ext4$' "$S/calls"
expect census_finder_icns test -s "$T/vols/finder-ext4/.VolumeIcon.icns"
expect census_finder_desktop_on grep -q '^guest-macosx-aqua defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool true$' "$S/calls"
expect census_finder_desktop_off grep -q '^guest-macosx-aqua defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false$' "$S/calls"
expect census_finder_desktop_restored test "$(grep 'ShowExternalHardDrivesOnDesktop' "$S/calls" | tail -n 1)" = "guest-macosx-aqua defaults delete com.apple.finder ShowExternalHardDrivesOnDesktop"
expect census_finder_restarts test "$(grep -c '^guest-macosx-aqua killall Finder$' "$S/calls")" -ge 4
# item 2: Finder restarted before the first Get Info (it reads the bundles' FSNames when it starts), then the
#   filesystem's own Get Info photographed as getinfo-format (its Format line, HFS+ has none)
restart_before_info() { awk '/^guest-macosx-aqua killall Finder$/ { k = 1 } /open information window/ { exit !k } END { exit !k }' "$S/calls"; }
expect census_finder_restart_before_info restart_before_info
expect census_finder_getinfo_format test "$(grep -c 'screencapture -x .*/ext4-getinfo-format.png$' "$S/calls")" -eq 1 -a "$(grep -c 'getinfo-format' "$S/calls")" -eq 1
expect census_finder_quiet hasnt "$r" "not ok"
expect census_finder_detached test -z "$(attached)"
# item 3 (Task 13b): each view's shot waits (bounded) for its Finder window, and says so
expect census_finder_awaits_window grep -q '^sidebar hfs: seen after [0-9]* s$' "$P/shots.txt"
expect census_finder_awaits_info grep -q '^getinfo-format ext4: seen after [0-9]* s$' "$P/shots.txt"
: > "$S/calls"
census_finder btrfs > /dev/null 2>&1
expect census_finder_hfs_shots_once test "$(grep -c 'screencapture -x .*/hfs-sidebar.png$' "$S/calls")" -eq 0 -a "$(grep -c 'screencapture -x .*/btrfs-sidebar.png$' "$S/calls")" -eq 1
expect census_finder_restart_before_info_each restart_before_info
expect census_finder_getinfo_format_each test "$(grep -c 'screencapture -x .*/btrfs-getinfo-format.png$' "$S/calls")" -eq 1

# census_trash_tags_case: Finder's delete, .Trashes and empty trash; a tag and a label, after a remount too; the
#   oversized xattr; pathconf against HFS+ and against HFSX. APFS, read-only, gets the case step alone.
: > "$S/calls"
r=$(census_trash_tags_case ext4 2>&1)
for s in trash.ext4.finder-delete trash.ext4.trashes trash.ext4.after-empty tags.ext4.set tags.ext4.read tags.ext4.after-remount tags.ext4.oversized case.ext4.pathconf case.ext4.pathconf-hfsx; do
  expect "census_ttc_$s" test -s "$P/$s.hfs.txt" -a -s "$P/$s.ext4.txt"
done
expect census_ttc_empty_record test -s "$P/trash.ext4.empty-trash.txt"
expect census_ttc_delete grep -q 'to delete (POSIX file ".*/vols/trash-ext4/trash-me" as alias)' "$S/calls"
expect census_ttc_empty grep -q 'empty trash' "$S/calls"
expect census_ttc_warns_restored test "$(grep 'warns before emptying' "$S/calls" | tail -n 1)" = 'guest-macosx-aqua osascript -e tell application "Finder" to set warns before emptying of trash to true'
expect census_ttc_shot test "$(grep -Ec 'screencapture -x .*/(hfs|ext4)-trash-delete.png$' "$S/calls")" -eq 2
expect census_ttc_tag grep -q '^xattr -wx com.apple.metadata:_kMDItemUserTags 62706c6973743030a10156506172697479080a0000000000000101000000000000000200000000000000000000000000000011 .*/vols/trash-ext4/tagged$' "$S/calls"
expect census_ttc_label grep -q 'set label index of (POSIX file ".*/vols/trash-ext4/tagged" as alias) to 2' "$S/calls"
expect census_ttc_remount test "$(grep -c '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/trash-ext4.img$' "$S/calls")" -eq 2
# the sizes, past 128 KiB, by setxattr from Python (no exec argument carries them): each one's result, in order, all of
#   them or up to the first refusal
for f in hfs ext4; do
  got=$(sed -n 's/^\([0-9]*\) bytes: .*/\1/p' "$P/tags.ext4.oversized.$f.txt" | tr '\n' ' ')
  case "$PARITY_XATTR_SIZES " in
  "$got"*) if test "$got" = "$PARITY_XATTR_SIZES " || grep -q '^stopped at the first refusal$' "$P/tags.ext4.oversized.$f.txt"; then ok=1; else ok=; fi ;;
  *) ok= ;;
  esac
  expect "census_ttc_oversized_sizes_$f" test -n "$got" -a -n "$ok"
done
expect census_ttc_hfsx grep -q '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/trash-hfsx-ext4.img$' "$S/calls"
expect census_ttc_pathconf grep -Eq '^(pathconf\(_PC_CASE_SENSITIVE\) = -?[0-9]+|errno [0-9]+)$' "$P/case.ext4.pathconf.ext4.txt"
expect census_ttc_quiet hasnt "$r" "not ok"
expect census_ttc_detached test -z "$(attached)"
# a failed remount (the linuxfs eject fails) skips only the read after it: the control comes back for the case steps
echo stuck4 > "$W/img/stuck4.img"
r=$(census_trash_tags_case stuck4 2>&1)
expect census_ttc_remount_fails has "$r" "^# census_trash_tags_case stuck4: no remount, so no tags read after one"
expect census_ttc_remount_fails_case test -s "$P/case.stuck4.pathconf.hfs.txt" -a -s "$P/case.stuck4.pathconf-hfsx.stuck4.txt"
expect census_ttc_remount_fails_no_read test ! -e "$P/tags.stuck4.after-remount.stuck4.txt"
for f in "$S"/nodes/*; do case $f in *.m | *.u) ;; *) test "$(sed -n 's/^vol=//p' "$f")" != trash-stuck4 || rm -f "$f" "$f.m" "$f.u" ;; esac; done
rm -f "$W/img/stuck4.img"
# the oversized probe is bounded at 1 min a side (2 min for the step), so a trash/tags/case census stays in its envelope
r=$(census_xattr_big() { echo "${PARITY_BOUND:-unset}" > "$T/xb-bound"; }; census_trash_tags_case btrfs 2>&1)
expect census_ttc_oversized_bound test "$(cat "$T/xb-bound" 2>/dev/null)" = 600
r=$(census_trash_tags_case apfs 2>&1)
expect census_ttc_apfs_case test -s "$P/case.apfs.pathconf.apfs.txt" -a -s "$P/case.apfs.pathconf-hfsx.apfs.txt"
expect census_ttc_apfs_case_only test -z "$(ls "$P" | grep -E '^(trash|tags)\.apfs\.')"
expect census_ttc_apfs_detached test -z "$(attached)"

# census_later: Time Machine, the exFAT control against ext4 (each beside HFS+)
: > "$S/calls"; rm -f "$P/shots.txt"
r=$(census_later 2>&1)
# tmutil isexcluded with no destination says [Excluded] for every volume: not asked, and said so
expect census_later_no_isexcluded not grep -q '^tmutil isexcluded' "$S/calls"
expect census_later_tm_note grep -q 'uninformative' "$P/later.tm-excluded.txt"
# alerts are dismissed before each attach, and never between an attach and its tm-offer shot (the offer comes after)
tm_dismissed() { awk '/killall UserNotificationCenter$/ { if (a) bad = 1; d = 1; next } /^hdiutil attach -imagekey / { if (!d) bad = 1; a = 1; d = 0 } /tm-offer.png$/ { a = 0 } END { exit bad }' "$S/calls"; }
expect census_later_dismissed_before_attach tm_dismissed
expect census_later_no_destination not grep -Eq 'tmutil (setdestination|removedestination)' "$S/calls"
expect census_later_shots test "$(grep -Ec 'screencapture -x .*/(hfs|exfat|ext4)-tm-offer.png$' "$S/calls")" -eq 3
# (fix round 1) the offer is not awaited (it may never come for linuxfs), and each shot says so
expect census_later_tm_not_awaited test "$(grep -Ec '^tm-offer (hfs|exfat|ext4): not awaited: .*; photographed after 5 s$' "$P/shots.txt")" -eq 3
expect census_later_quiet hasnt "$r" "not ok"
expect census_later_detached test -z "$(attached)"

# item 3 (Task 13b): census_await says how long it waited, or that it gave up (the shot is taken anyway)
#   (Task 16c fix round 2) seen on the first try is counted in the stub's osascript calls, exactly one, not read from the
#   clock: a whole-second date +%s around one stubbed round could say 1 s whenever the round crossed a second boundary
rm -f "$P/shots.txt"
aw_calls() { grep -c 'osascript -e tell application "Finder" to return (POSIX path of (target of front Finder window as alias)) is "/x/"$' "$S/calls" || :; }
n0=$(aw_calls)
r=$(bounded 100 census_await stepq hfs 'tell application "Finder" to return (POSIX path of (target of front Finder window as alias)) is "/x/"' 2>&1); rc=$?
expect census_await_seen test "$rc" -eq 0 -a "$(($(aw_calls) - n0))" -eq 1
expect census_await_seen_said grep -Eq '^stepq hfs: seen after [0-9]+ s$' "$P/shots.txt"
: > "$S/no-window"
r=$(bounded 100 census_await stepr fsq 'tell application "Finder" to return (POSIX path of (target of front Finder window as alias)) is "/x/"' 2>&1); rc=$?
rm -f "$S/no-window"
expect census_await_not_seen test "$rc" -ne 0
expect census_await_not_seen_said grep -q '^stepr fsq: not seen within 0 s (photographed anyway): false$' "$P/shots.txt"
# a pair of byte-identical shots is no pair: the filesystem's is removed and that said; the one-screen shots (the Desktop,
#   the Privacy pane, which show every volume) are not pairs, and stay
parity_pair disk2s1 "$T/a" CTL fsq disk3s1 "$T/b" FSQ
rm -f "${OUT:?}"/*-pairq.png "${OUT:?}"/*-pairr.png "${OUT:?}"/*-desktop-on.png; : > "$S/same-shots"
census_shot pairq hfs nodismiss; census_shot pairq fs nodismiss
expect census_shot_identical_refused test -f "$OUT/hfs-pairq.png" -a ! -e "$OUT/fsq-pairq.png"
expect census_shot_identical_said grep -q '^pairq fsq: byte-identical to hfs-pairq.png: no verdict: identical shots$' "$P/shots.txt"
census_shot desktop-on hfs nodismiss; census_shot desktop-on fs nodismiss
expect census_shot_one_screen_kept test -f "$OUT/fsq-desktop-on.png"
rm -f "$S/same-shots"
census_shot pairr hfs nodismiss; census_shot pairr fs nodismiss
expect census_shot_distinct_kept test -f "$OUT/hfs-pairr.png" -a -f "$OUT/fsq-pairr.png"
rm -f "${OUT:?}"/*-pairq.png "${OUT:?}"/*-pairr.png "${OUT:?}"/*-desktop-on.png

# item 2 (Task 13b): Finder's own dialogs dismissed between census steps: Cancel, else OK, never the default button (Force
#   Eject, on a busy eject's); what each said in dialogs.txt; when System Events cannot (no assistive access), or a
#   dialog has neither button, Finder is restarted, which closes its dialogs
rm -f "$P/dialogs.txt"; : > "$S/calls"
census_finder_dialogs step-x > /dev/null 2>&1
expect census_dialogs_said grep -q '^step-x: OK: The disk “stub” was ejected\.$' "$P/dialogs.txt"
expect census_dialogs_no_restart not grep -q 'killall Finder' "$S/calls"
expect census_dialogs_never_default test -z "$(grep -n 'AXDefaultButton\|key code 36' "$here/lib/parity.sh" | grep -v '^[0-9]*: *#')"
: > "$S/no-ui"; : > "$S/calls"
census_finder_dialogs step-y > /dev/null 2>&1
rm -f "$S/no-ui"
expect census_dialogs_no_ui grep -q '^step-y: System Events could not (.*assistive access.*): Finder restarted$' "$P/dialogs.txt"
expect census_dialogs_no_ui_restart grep -q '^guest-macosx-aqua killall Finder$' "$S/calls"
: > "$S/dialog-force"; : > "$S/calls"
census_finder_dialogs step-z > /dev/null 2>&1
rm -f "$S/dialog-force"
expect census_dialogs_force_left grep -q '^step-z: left up (Force Eject…): .*: Finder restarted$' "$P/dialogs.txt"
expect census_dialogs_force_restart grep -q '^guest-macosx-aqua killall Finder$' "$S/calls"
# (fix round 1) on 10.9 Finder's eject alerts are invisible to System Events, so after Finder was asked to eject (in a
#   subshell, as bounded runs it) the next dismissal restarts Finder whatever System Events says, says so, and only once;
#   a Finder step that ejects nothing leaves no restart; the eject's shot is not awaited (no System Events wait), but
#   taken after 3 s; nothing presses a key (Force Eject can never be pressed)
rm -f "$P/dialogs.txt" "$P/shots.txt"; : > "$S/calls"; : > "$T/sleeps"
bounded 1800 census_finder_eject "$T/b" FSQ > /dev/null 2>&1
expect census_eject_shot_not_awaited not grep -q 'return exists (first window' "$S/calls"
expect census_eject_shot_said grep -q '^busy-eject fsq: not awaited: Finder.s eject alerts are invisible to System Events on 10.9; photographed after 3 s (busy-eject-3s) and 15 s (busy-eject)$' "$P/shots.txt"
expect census_eject_shots_order ascending "$(grep -n 'screencapture -x .*/fsq-busy-eject-3s.png$' "$S/calls" | cut -d: -f1)" "$(grep -n 'screencapture -x .*/fsq-busy-eject.png$' "$S/calls" | cut -d: -f1)"
expect census_eject_shots_kept test -f "$OUT/fsq-busy-eject-3s.png" -a -f "$OUT/fsq-busy-eject.png"
expect census_eject_late_pause grep -q '^sleep 1[0-5]$' "$T/sleeps"
: > "$S/calls"; census_finder_dialogs step-e > /dev/null 2>&1
expect census_eject_restarts grep -q '^guest-macosx-aqua killall Finder$' "$S/calls"
expect census_eject_restart_said grep -q '^step-e: restarted Finder after an eject (alerts invisible to System Events on 10.9)$' "$P/dialogs.txt"
: > "$S/calls"; census_finder_dialogs step-f > /dev/null 2>&1
expect census_eject_restart_once not grep -q 'killall Finder' "$S/calls"
bounded 1800 census_finder_eject "$T/b" FSQ > /dev/null 2>&1; bounded 1800 census_finder_eject "$T/a" CTL > /dev/null 2>&1
expect census_eject_restart_between_sides test "$(grep -c 'killall Finder' "$S/calls")" -eq 1
census_finder_dialogs step-h > /dev/null 2>&1
bounded 1600 census_finder_ask trash-delete "$T/b" 'tell application "Finder" to delete (POSIX file "/x" as alias)' > /dev/null 2>&1
: > "$S/calls"; census_finder_dialogs step-g > /dev/null 2>&1
expect census_no_eject_no_restart not grep -q 'killall Finder' "$S/calls"
expect census_no_keystrokes test -z "$(grep -n 'keystroke\|key code' "$here/lib/parity.sh" | grep -v '^[0-9]*: *#')"
: > "$S/calls"; r=$(census_on ext4 true 2>&1)
expect census_on_dismisses grep -q 'click button "Cancel"' "$S/calls"
expect census_on_dialogs_said grep -q '^after true ext4: OK: ' "$P/dialogs.txt"

# item 4 (Task 13b): after each census step, every disk it attached and left is freed: a linuxfs volume still mounted
#   (its disk untied by DiskArbitration) is unmounted by its mount point, its lklfuse waited for, then the disk ejected,
#   never by force; Apple's are ejected; each said in census-sweep.txt, a disk that stays attached too. A disk attached
#   before the step is not the step's
for c in calm hfs stuck pre; do echo "sweep $c" > "$W/census/sweep-$c.img"; done
census_attach "$W/census/sweep-pre.img" > /dev/null 2>&1; pre=disk$(cat "$S/disks")
leave() { for c in calm hfs stuck; do census_attach "$W/census/sweep-$c.img" > /dev/null 2>&1; done; return 0; }
: > "$S/da-forgets"; rm -f "$P/census-sweep.txt"; : > "$S/calls"
r=$(census_on ext4 leave 2>&1)
rm -f "$S/da-forgets"
calm_d=$(sed -n 's,^after leave ext4: /dev/\(disk[0-9]*\) .*/sweep-calm.img: .*,\1,p' "$P/census-sweep.txt")
expect census_sweep_linuxfs grep -q "^after leave ext4: /dev/$calm_d .*/sweep-calm.img: linuxfs at .*/vols/sweep-calm: unmounted by its mount point, then ejected$" "$P/census-sweep.txt"
expect census_sweep_unmount_first ascending "$(grep -n '^diskutil unmount .*/vols/sweep-calm$' "$S/calls" | tail -n 1 | cut -d: -f1)" "$(grep -n "^diskutil eject /dev/$calm_d\$" "$S/calls" | tail -n 1 | cut -d: -f1)"
expect census_sweep_apple grep -q '^after leave ext4: /dev/disk[0-9]* .*/sweep-hfs.img: ejected$' "$P/census-sweep.txt"
expect census_sweep_stuck grep -q '^after leave ext4: /dev/disk[0-9]* .*/sweep-stuck.img: linuxfs at .*/vols/sweep-stuck: unmounted by its mount point; left attached$' "$P/census-sweep.txt"
expect census_sweep_not_pre not grep -q 'sweep-pre' "$P/census-sweep.txt"
expect census_sweep_left test "$(attached | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')" = "$(printf '%s\n' "$pre" $(stuck_disks sweep-stuck) | sort | tr '\n' ' ')"
drop_stuck sweep-stuck
for c in calm hfs stuck; do echo "sweep $c" > "$W/census/sweep-$c.img"; done   # census_on's census_clean took the ejected copies
# the sweep's time is bounded (PARITY_SWEEP_SECS, checked before each disk): what it had no time for is said, and left
rm -f "$P/census-sweep.txt"
r=$(PARITY_SWEEP_SECS=0; census_on ext4 leave 2>&1)
expect census_sweep_no_time test "$(grep -c '^after leave ext4: /dev/disk[0-9]* .*: not tried: the sweep.s 0 s are up$' "$P/census-sweep.txt")" -eq 3
drop_stuck sweep-; rm -f "${W:?}"/census/sweep-*.img
# (fix round 1) the sweep never detaches by force a disk a live lklfuse may hold: with mount unreadable it tries nothing;
#   with no mount line, a disk an lklfuse names (/dev/rdiskN), or a linuxfs image's, or any when ps cannot say, is ejected
#   (census_detach fs), never detached by force; only a disk of Apple's image, no lklfuse on it, is
sw_one() { hdiutil attach -nomount "$W/census/sweep-$1.img" > /dev/null 2>&1; echo "disk$(cat "$S/disks")"; }
for c in stuck-hfs-held stuck-hfs-psless stuck-hfs-plain stuck-ext4; do echo "sweep $c" > "$W/census/sweep-$c.img"; done
: > "$S/calls"
d=$(sw_one stuck-hfs-held); echo "$d" > "$S/lklfuse-holds"
r=$(census_sweep_disk "/dev/$d" "$W/census/sweep-stuck-hfs-held.img")
rm -f "$S/lklfuse-holds"
expect census_sweep_held_said test "$r" = "no mount line, but an lklfuse names /dev/r$d: its eject failed; left attached (never detached by force)"
expect census_sweep_held_not_forced not grep -q 'detach -force' "$S/calls"
expect census_sweep_held_tried grep -q "^diskutil eject /dev/$d\$" "$S/calls"
d=$(sw_one stuck-hfs-psless); : > "$S/ps-fail"
r=$(census_sweep_disk "/dev/$d" "$W/census/sweep-stuck-hfs-psless.img")
rm -f "$S/ps-fail"
expect census_sweep_psless_said test "$r" = "no mount line, but ps could not say whether an lklfuse holds it: its eject failed; left attached (never detached by force)"
expect census_sweep_psless_not_forced not grep -q 'detach -force' "$S/calls"
d=$(sw_one stuck-ext4)
rm -f "$P/census-sweep.txt"; census_sweep stepq "$(census_attached | grep -v sweep-stuck-ext4)"
expect census_sweep_fs_image grep -q "^stepq: /dev/$d .*/sweep-stuck-ext4.img: no mount line, but a linuxfs image: its eject failed; left attached (never detached by force)\$" "$P/census-sweep.txt"
expect census_sweep_fs_image_not_forced not grep -q 'detach -force' "$S/calls"
: > "$S/mount-fail"; : > "$S/calls"
r=$(census_sweep_disk "/dev/$d" "$W/census/sweep-stuck-ext4.img")
rm -f "$S/mount-fail"
expect census_sweep_mount_unreadable test "$r" = "mount unreadable; not tried"
expect census_sweep_mount_unreadable_untouched not grep -q '^diskutil \(eject\|unmount\)\|^hdiutil detach' "$S/calls"
d=$(sw_one stuck-hfs-plain); : > "$S/calls"
r=$(census_sweep_disk "/dev/$d" "$W/census/sweep-stuck-hfs-plain.img")
expect census_sweep_apple_forced test "$r" = "nothing mounted, no lklfuse on it, an image of Apple's: detached"
expect census_sweep_apple_forced_call grep -q "^hdiutil detach -force /dev/$d\$" "$S/calls"
drop_stuck sweep-; rm -f "${W:?}"/census/sweep-*.img
expect census_sweep_after_stall test -n "$(sed -n '/^parity_census_all()/,/^}/p' "$here/lib/parity.sh" | grep 'census_after census_stall')"
expect census_sweep_after_later test -n "$(sed -n '/^parity_census_all()/,/^}/p' "$here/lib/parity.sh" | grep 'census_after census_later')"

# census_before_login: mdutil -s and .fseventsd only
mkdir -p "$T/bl/.fseventsd"
r=$(census_before_login "$T/bl" 2>&1)
expect census_before_login_mdutil grep -q '^<MP>:$' "$P/spotlight.before-login.txt"
expect census_before_login_fseventsd grep -q '^.fseventsd: yes$' "$P/spotlight.before-login.txt"
expect census_before_login_recorded has "$r" "^# recorded spotlight.before-login"

# census_refusals_bar LINE (Task 15): fseventsd's, mds's or mdworker's "Operation not permitted" naming a linuxfs census
#   mount point (names-mode.txt's), in system.log after LINE: ok when there is none, not ok with the lines; another
#   process's, or another volume's (one whose name only begins alike), not counted; no mount point proves nothing
rb() { ( PARITY_SYSLOG=$T/rb.log; census_refusals_bar "$@" ) 2>&1; }
printf '%s\n' 'disk5 /Volumes/my data: exact (stub)' 'disk6 /Volumes/my data: exact (stub)' 'disk7 /Volumes/flash: exact (stub)' > "$P/names-mode.txt"
printf '%s\n' 'Nov 25 old fseventsd[42]: failed to make the directory /Volumes/flash/.fseventsd (1/Operation not permitted)' \
  'Nov 25 fseventsd[42]: failed to make the directory /Volumes/my data 3/.fseventsd (1/Operation not permitted)' \
  'Nov 25 Finder[9]: /Volumes/flash/x (Operation not permitted)' \
  'Nov 25 fseventsd[42]: opened /Volumes/flash' > "$T/rb.log"
r=$(rb 1)
expect census_refusals_bar_ok test "$r" = "ok - spotlight: no refusals for linuxfs volumes (0 lines, 2 linuxfs mount points searched, system.log since the census began; 0 others recorded)"
echo 'Nov 25 mdworker[77]: open /Volumes/my data/x: Operation not permitted' >> "$T/rb.log"
echo 'Nov 25 fseventsd[42]: failed to make the directory /Volumes/flash/.fseventsd (1/Operation not permitted)' >> "$T/rb.log"
r=$(rb 1)
expect census_refusals_bar_notok has "$r" "^not ok - spotlight: no refusals for linuxfs volumes (2 lines, 2 linuxfs mount points searched, system.log since the census began; 0 others recorded)$"
expect census_refusals_bar_lines has "$r" "^# Nov 25 mdworker\[77\]: open /Volumes/my data/x: Operation not permitted$"
expect census_refusals_bar_file test "$(grep -c . "$P/refusals-linuxfs.txt")" -eq 2
r=$(PARITY_MODE_SPOTLIGHT=record; rb 1)
expect census_refusals_bar_record test "$r" = "# recorded spotlight: no refusals for linuxfs volumes (2 lines, 2 linuxfs mount points searched, system.log since the census began; 0 others recorded)"
# system.log turned over since POS, and no rotated file began with POS's first line: syslog_since reads it whole
printf '%s\n' 'disk7 /Volumes/flash: exact (stub)' > "$P/names-mode.txt"
r=$(rb '999|a first line no file has')
expect census_refusals_bar_turned_over has "$r" "^not ok - spotlight: no refusals for linuxfs volumes (2 lines, 1 linuxfs mount points searched"
: > "$P/names-mode.txt"; r=$(rb 1)
expect census_refusals_bar_none test "$r" = "not ok - spotlight: no refusals for linuxfs volumes: no linuxfs census mount to search for, so this proves nothing"
r=$(PARITY_MODE_SPOTLIGHT=chek; rb 1)
expect census_refusals_bar_badmode has "$r" "^not ok - spotlight: no refusals for linuxfs volumes$"
# (fix round 1, I2) a position from census_log_pos ("LINES|FIRST") is read through rotation (syslog_since): the rest of
#   the rotated .gz the census began in, then the new file
printf '%s\n' 'disk7 /Volumes/flash: exact (stub)' > "$P/names-mode.txt"
printf '%s\n' 'head line' 'before' 'Nov 25 fseventsd[42]: failed to make the directory /Volumes/flash/.fseventsd (1/Operation not permitted)' | gzip > "$T/rb.log.0.gz"
printf '%s\n' 'new head' 'Nov 25 mdworker[7]: /Volumes/flash/y: Operation not permitted' 'x' 'y' 'z' > "$T/rb.log"
r=$(rb '2|head line')
expect census_refusals_bar_rotated has "$r" "^not ok - spotlight: no refusals for linuxfs volumes (2 lines, 1 linuxfs mount points searched"
r=$( (PARITY_SYSLOG=$T/rb.log; census_log_pos) )
expect census_log_pos test "$r" = "5|new head"
rm -f "$T/rb.log.0.gz"
# (fix round 1, m3) only fseventsd's, mds's and mdworker's access refusals count; mds_stores's, mdflagwriter's and any
#   tagging one (item 7's) are recorded in refusals-linuxfs-other.txt, not counted
printf '%s\n' 'h' 'Nov 25 mdflagwriter[5]: /Volumes/flash/t: Operation not permitted' \
  'Nov 25 mdworker[7]: setxattr com.apple.metadata:_kMDItemUserTags /Volumes/flash/t: Operation not permitted' \
  'Nov 25 mds_stores[8]: /Volumes/flash/.Spotlight-V100: Operation not permitted' > "$T/rb.log"
r=$(rb 1)
expect census_refusals_bar_item7_ok test "$r" = "ok - spotlight: no refusals for linuxfs volumes (0 lines, 1 linuxfs mount points searched, system.log since the census began; 3 others recorded)"
expect census_refusals_bar_item7_recorded test "$(grep -c . "$P/refusals-linuxfs-other.txt")" -eq 3
rm -f "$T/rb.log"

# parity_census_all: the controls, then each census in order (NTFS with NTFSTakeover on), PARITY_STALL_N 50, a census
#   disk left attached recorded; past PARITY_CENSUS_MIN, the rest is skipped and said
rm -rf "$W/ctl"; echo left > "$W/census/left-stuck.img"; echo old > "$W/census/old.img"
census_attach "$W/census/left-stuck.img" > /dev/null 2>&1; left=disk$(cat "$S/disks")
ran=$T/ran; : > "$ran"
r=$(
  unset PARITY_STALL_N
  tk() { if test "$(cat "$S/takeover" 2> /dev/null)" = 1; then echo on; else echo off; fi; }
  census_stall() { echo "stall $# $PARITY_STALL_N" >> "$ran"; }
  census_unicode() { echo "unicode $1 $(tk)" >> "$ran"; }
  census_busy() { echo "busy $1 $(tk)" >> "$ran"; }
  census_spotlight() { echo "spotlight $1 $(tk)" >> "$ran"; }
  census_finder() { echo "finder $1 $(tk)" >> "$ran"; }
  census_trash_tags_case() { echo "trash_tags_case $1 $(tk)" >> "$ran"; }
  census_later() { echo "later $#" >> "$ran"; }
  parity_census_all 2>&1
)
# the stub images are ext4, btrfs, xfs, ntfs and apfs: f2fs is said to be missing, and skipped
want=$(printf '%s\n' "stall 0 50" "unicode ext4 off" "unicode btrfs off" "unicode xfs off" "unicode ntfs on" "busy ext4 off" "busy xfs off" \
  "spotlight ext4 off" "finder ext4 off" "finder btrfs off" "finder xfs off" "finder ntfs on" "finder apfs off" \
  "trash_tags_case ext4 off" "trash_tags_case btrfs off" "trash_tags_case xfs off" "trash_tags_case ntfs on" "trash_tags_case apfs off" "later 0")
expect census_all_order test "$(cat "$ran")" = "$want"
expect census_all_names_bar has "$r" "^# recorded census names: "
# no linuxfs census mount ran (the steps are stand-ins), so the refusals bar proves nothing
expect census_all_refusals_bar has "$r" "^not ok - spotlight: no refusals for linuxfs volumes: no linuxfs census mount to search for"
expect census_all_missing has "$r" "^# census: no .*/img/f2fs.img, so no census_finder f2fs"
expect census_all_controls test -f "$W/ctl/hfs.img" -a -f "$W/ctl/hfsx.img" -a -f "$W/ctl/fat32.img" -a -f "$W/ctl/exfat.img"
expect census_all_takeover_off test ! -f "$S/takeover"
expect census_all_left grep -q "^/dev/$left .*/census/left-stuck.img\$" "$P/census-left-attached.txt"
expect census_all_left_said has "$r" "^# census: left attached .*left-stuck.img"
expect census_all_cleans test ! -e "$W/census/old.img" -a -e "$W/census/left-stuck.img"
# a step begins only when, at its worst (the console hung: every AppleScript at its bound), it ends by
#   PARITY_CENSUS_MIN + 11; a step whose worst is 11 or less keeps the plain cutoff
expect census_worst_default test "$(census_worst_min zzz)" -eq 11
# Task 16l: census_pair_up's census_da_root (bounded at 10 s) on each pair it makes: spotlight 33, census_finder 31, trash/tags/case 22
expect census_worst_table test "$(for c in census_unicode census_busy census_spotlight census_finder census_trash_tags_case census_later census_stall stall; do census_worst_min "$c"; done | tr '\n' ' ')" = '17 32 33 31 22 9 63 63 '
# Task 15: the census begins nothing past 132 min (it was 135), for the refusals bar and the non-admin mount after it
r=$(unset PARITY_CENSUS_MIN; . "$here/lib/parity.sh"; echo "$PARITY_CENSUS_MIN")
expect census_min_default test "$r" -eq 132
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=20; census_due census_finder ext4 2>&1); rc=$?
expect census_due_worst_skips test "$rc" -ne 0
expect census_due_worst_said has "$r" "^# census: census_finder may take 31 min, past the census's end (31 min), skipped: census_finder ext4$"
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=30; census_due census_finder ext4 2>&1)
expect census_due_worst_fits test -z "$r"
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=11; census_due census_later 2>&1)
expect census_due_plain_cutoff test -z "$r"
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=10; census_due census_later 2>&1)
expect census_due_plain_cutoff_said has "$r" "^# census: out of time (10 min), skipped: census_later$"
: > "$ran"
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=20; census_finder() { echo finder >> "$ran"; }; census_on ext4 census_finder ext4 2>&1)
expect census_on_worst_skips test ! -s "$ran"
: > "$ran"
r=$(PARITY_CENSUS_MIN=0; census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; parity_census_all 2>&1)
expect census_all_out_of_time test ! -s "$ran"
expect census_all_out_of_time_said has "$r" "^# census: out of time (0 min), skipped: census_stall"
# before any copy, $W's free space is checked and recorded, against PARITY_START_FLOOR_KB (not busy's 2 GiB floor);
#   with no room for the controls, nothing runs
: > "$ran"; : > "$P/census-room.txt"
r=$(PARITY_START_FLOOR_KB=999999999999; census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; parity_census_all 2>&1)
expect census_all_room_short test ! -s "$ran"
expect census_all_room_said has "$r" "^# census: .* KiB free on .*, under the floor .*: no census"
expect census_all_room_recorded grep -q '^# census: df -k .* KiB free, floor 999999999999 KiB and [0-9]* KiB to copy' "$P/census-room.txt"
: > "$ran"
r=$(PARITY_FREE_FLOOR_KB=999999999999; census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; PARITY_STALL_N=0; parity_census_all 2>&1)
expect census_all_room_busy_floor_apart test "$(head -n 1 "$ran")" = stall
# room for the controls but not for a step's copies: that step is skipped and said, the census goes on to the next
#   (19 steps: the stub images lack f2fs)
: > "$ran"; : > "$P/census-room.txt"; printf '%s\n' 99999999 1 > "$S/df-free"
r=$(
  census_stall() { echo stall >> "$ran"; }; census_unicode() { echo "unicode $1" >> "$ran"; }; census_busy() { echo "busy $1" >> "$ran"; }
  census_spotlight() { echo "spotlight $1" >> "$ran"; }; census_finder() { echo "finder $1" >> "$ran"; }
  census_trash_tags_case() { echo "ttc $1" >> "$ran"; }; census_later() { echo later >> "$ran"; }
  PARITY_START_FLOOR_KB=524288; parity_census_all 2>&1
)
rm -f "$S/df-free"
expect census_all_step_room_short test ! -s "$ran"
expect census_all_step_room_said_stall has "$r" "^# census: 1 KiB free on .*, under the floor 524288 KiB .*, skipped: census_stall$"
expect census_all_step_room_said_each test "$(printf '%s\n' "$r" | grep -c ', skipped: census_')" -eq 19
expect census_all_step_room_recorded test "$(grep -c ', skipped: census_' "$P/census-room.txt")" -eq 19
expect census_all_step_room_controls test -f "$W/ctl/hfs.img"
: > "$ran"
r=$(census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; PARITY_CENSUS_MIN=0; parity_census_all 2>&1)
expect census_all_room_ok grep -q '^# census: df -k .* KiB free, floor 1 KiB' "$P/census-room.txt"
# item 1 (Task 13b): census_names_bar, from names-mode.txt: with PARITY_NAMES_WANT (the smoke's exact when macFUSE is
#   5.5.0-mavericks.5 or later, else scanning), not ok when a mount ran the other mode, or none ran the wanted one (it
#   would prove nothing); a mount whose log had no names line is counted, not failed; with no PARITY_NAMES_WANT, recorded
nb() { printf '%s\n' "$@" > "$P/names-mode.txt"; census_names_bar 2>&1; }
r=$(PARITY_NAMES_WANT=exact; nb 'disk3 /Volumes/a: exact (x)' 'disk5 /Volumes/c: none (no names line in L)')
expect census_names_bar_ok test "$r" = "ok - census names: no linuxfs census mount ran scanning (1 exact, 0 scanning, 1 with no names line, of 2)"
r=$(PARITY_NAMES_WANT=exact; nb 'disk3 /Volumes/a: exact (x)' 'disk4 /Volumes/b b: scanning (y)')
expect census_names_bar_scanning_notok has "$r" "^not ok - census names: 1 ran scanning, though PARITY_NAMES_WANT is exact (1 exact, 1 scanning, 0 with no names line, of 2)$"
expect census_names_bar_scanning_said has "$r" "^census names: ran scanning: disk4 /Volumes/b b$"
r=$(PARITY_NAMES_WANT=exact; nb 'disk5 /Volumes/c: none (no names line in L)')
expect census_names_bar_none_notok has "$r" "^not ok - census names: none ran exact, so this proves nothing (0 exact, 0 scanning, 1 with no names line, of 1)$"
expect census_names_bar_none_said hasnt "$r" "no linuxfs census mount ran"
rm -f "$P/names-mode.txt"; r=$(PARITY_NAMES_WANT=exact; census_names_bar 2>&1)
expect census_names_bar_nofile_notok has "$r" "^not ok - census names: none ran exact, so this proves nothing (0 exact, 0 scanning, 0 with no names line, of 0)$"
r=$(PARITY_NAMES_WANT=scanning; nb 'disk4 /Volumes/b: scanning (y)')
expect census_names_bar_older test "$r" = "ok - census names: no linuxfs census mount ran exact (0 exact, 1 scanning, 0 with no names line, of 1)"
r=$(unset PARITY_NAMES_WANT; nb 'disk4 /Volumes/b: scanning (y)')
expect census_names_bar_record test "$r" = "# recorded census names: (0 exact, 1 scanning, 0 with no names line, of 1)"
r=$(PARITY_NAMES_WANT=exacT; nb 'disk4 /Volumes/b: exact (y)')
expect census_names_bar_bad_want has "$r" "^not ok - census names$"
rm -f "$P/names-mode.txt"
# the deadline counts from the smoke's start, PARITY_T0
: > "$ran"
r=$(PARITY_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=9; census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; parity_census_all 2>&1)
expect census_all_from_smoke_start test ! -s "$ran"
r=$(PARITY_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=$(($(census_worst_min census_stall) + 5)); census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; parity_census_all 2>&1)
expect census_all_within test "$(head -n 1 "$ran")" = stall
# NTFSTakeover is put back as it was, not deleted
echo 0 > "$S/takeover"
r=$(census_on ntfs cat "$S/takeover" 2>&1)
expect census_on_takeover_during test "$r" = 1
expect census_on_takeover_restored test "$(cat "$S/takeover")" = 0
rm -f "$S/takeover"
# when hdiutil info fails, census_clean removes nothing and the leftovers are unknown, not none
echo old > "$W/census/old2.img"; : > "$S/info-fail"
r=$(census_clean 2>&1; census_left_attached 2>&1)
expect census_clean_info_fails test -e "$W/census/old2.img"
expect census_clean_info_fails_said has "$r" "^# census: hdiutil info failed, so no copy is removed"
expect census_left_info_fails grep -q '^unknown: hdiutil info failed$' "$P/census-left-attached.txt"
rm -f "$S/info-fail" "$W/census/old2.img"
rm -f "$S/nodes/$left" "$S/nodes/$left.m"
census_left_attached > /dev/null 2>&1
expect census_all_none_left grep -q '^none$' "$P/census-left-attached.txt"

# the smoke sources parity.sh and runs the census before the before-login section, and records the before-login mount in it;
#   the workflow uploads OUT/parity and gives the guest job 180 minutes
sm=$here/smoke-mavericks.sh wf=$here/../.github/workflows/on-mavericks.yml
first_line() { grep -n -- "$1" "$sm" | head -n 1 | cut -d: -f1; }
bl=$(first_line '---- before login')
expect smoke_t0_first ascending "$(first_line '^PARITY_T0=\$(date +%s)$')" "$(first_line '^installed=')"
expect smoke_sources_parity ascending "$(first_line '^ *\. ".*/lib/parity\.sh"')" "$bl"
expect smoke_runs_census ascending "$(first_line '^ *parity_census_all$')" "$bl"
expect smoke_before_login_census ascending "$bl" "$(first_line 'census_before_login "\$mp"')"
expect workflow_parity_upload grep -q '^ *images-after/parity/\*\*$' "$wf"
expect workflow_guest_timeout awk '/^  guest:/ { g = 1 } /^  fsck:/ { g = 0 } g && /^    timeout-minutes: 180$/ { f = 1 } END { exit !f }' "$wf"
# push C's census runs item 3's loop, 50 iterations, before the census
expect smoke_stall_on ascending "$(first_line '^ *PARITY_STALL_N=50$')" "$(first_line '^ *parity_census_all$')"
# item 5 (Task 15): a user outside macFUSE's admin_group, lfs_nonadmin, made with dscl after the census and removed
#   before the before-login section (and by finish), mounts an ext4 image without the CLI's SHARE_OPT, which the smoke
#   reads from the installed CLI and never writes itself
na_l=$(first_line '^ *if check "non-admin: .* made with dscl')
expect smoke_nonadmin_after_census ascending "$(first_line '^ *parity_census_all$')" "$na_l" "$bl"
expect smoke_nonadmin_removed ascending "$na_l" "$(first_line '^ *check "non-admin: .* removed" nonadmin_remove$')" "$bl"
# smoke_fn NAME: the smoke's definition of the function NAME (one line, or up to its closing brace)
smoke_fn() { awk -v n="$1() " 'index($0, n) == 1 { p = 1; print; if ($0 !~ /[{] *(#.*)?$/) exit; next } p { print } p && /^}/ { exit }' "$sm"; }
expect smoke_finish_removes_nonadmin has "$(smoke_fn finish)" 'nonadmin_remove'
expect smoke_share_opt_not_written not grep -q 'allow_root' "$sm"
r=$(eval "$(smoke_fn share_opt_of)"; share_opt_of "$here/../cli/linuxfs")
expect smoke_share_opt_of test -n "$r" -a "$r" = "$(sed -n 's/^SHARE_OPT=//p' "$here/../cli/linuxfs")"
# no_share_opt UID MP SHARE: the lklfuse UID runs serving MP has an -o, and SHARE is not among its options
nso() { (eval "$(smoke_fn lklfuse_opts_of)"; eval "$(smoke_fn no_share_opt)"; ps() { cat "$T/nso.ps"; }; no_share_opt "$@") > /dev/null 2>&1; }
printf '%s\n' '  601 /p/lklfuse -f -o type=ext4,lock=/l,local,uid=601,gid=20,owner=root /h/ext4.img /h/mnt' '  501 /p/lklfuse -f -o type=ext4,allow_root /x.img /h/mnt' > "$T/nso.ps"
expect smoke_no_share_opt nso 601 /h/mnt allow_root
expect smoke_no_share_opt_empty not nso 601 /h/mnt ''
printf '%s\n' '  601 /p/lklfuse -f -o type=ext4,allow_root,local /h/ext4.img /h/mnt' > "$T/nso.ps"
expect smoke_share_opt_seen not nso 601 /h/mnt allow_root
printf '%s\n' '  601 /p/lklfuse -f -o type=ext4,local /h/ext4.img /h/mnt2' > "$T/nso.ps"
expect smoke_no_share_opt_none not nso 601 /h/mnt allow_root
# (fix round 1, I1) the real image's volname is "my data": the -o is read whole, past its space
printf '%s\n' '  601 /p/lklfuse -f -o type=ext4,lock=/l,local,volname=my data,fsname=linuxfs@ext4.img,noappledouble,fstypename=ext4,fssubtype=7,allow_root,uid=601,gid=20,owner=root /h/ext4.img /h/mnt' > "$T/nso.ps"
expect smoke_share_opt_seen_spaced not nso 601 /h/mnt allow_root
printf '%s\n' '  601 /p/lklfuse -f -o type=ext4,lock=/l,local,volname=my data,fsname=linuxfs@ext4.img,noappledouble,fstypename=ext4,fssubtype=7,uid=601,gid=20,owner=root /h/ext4.img /h/mnt' > "$T/nso.ps"
expect smoke_no_share_opt_spaced nso 601 /h/mnt allow_root
r=$( (eval "$(smoke_fn lklfuse_opts_of)"; ps() { cat "$T/nso.ps"; }; lklfuse_opts_of 601 /h/mnt) )
expect smoke_lklfuse_opts_whole test "$r" = "type=ext4,lock=/l,local,volname=my data,fsname=linuxfs@ext4.img,noappledouble,fstypename=ext4,fssubtype=7,uid=601,gid=20,owner=root"
rm -f "$T/nso.ps"
# (fix round 1, m1) its ps, and the section's dscl reads, are bounded
expect smoke_lklfuse_opts_bounded test -n "$(smoke_fn lklfuse_opts_of | grep 'bounded 100 ps ')"
expect smoke_nonadmin_dscl_bounded test -z "$( (smoke_fn nonadmin_make; smoke_fn nonadmin_remove) | grep 'dscl . -read\|dscl . -list' | grep -v 'bounded 100 dscl')"
expect smoke_sudo_true_bounded grep -q '^if bounded 100 sudo -n true 2> /dev/null; then$' "$sm"
# nonadmin_unshared: macFUSE's allow_other is off, and lfs_nonadmin is outside its admin_group
nau() { (eval "$(smoke_fn nonadmin_unshared)"; NA=lfs_nonadmin; sysctl() { case $2 in *admin_group) echo 80 ;; *allow_other) echo "$nau_ao" ;; esac; }; id() { echo "$nau_g"; }; nonadmin_unshared) > /dev/null 2>&1; }
nau_ao=0 nau_g="20 12 61"; expect smoke_nonadmin_unshared nau
nau_ao=0 nau_g="20 80"; expect smoke_nonadmin_admin not nau
nau_ao=1 nau_g="20"; expect smoke_nonadmin_allow_other not nau
nau_ao=0 nau_g=""; expect smoke_nonadmin_no_groups not nau
# nonadmin_make IMAGE and nonadmin_remove, with dscl, sudo and mount stubbed (calls in $T/na.calls)
nam() {
  ( eval "$(smoke_fn nonadmin_make)"; eval "$(smoke_fn nonadmin_remove)"
    NA=lfs_nonadmin NAH=$T/nah na_made=${nam_made:-}
    dscl() { echo "dscl $*" >> "$T/na.calls"; case "$*" in *-read*) test -f "$T/na.exists" ;; *-list*) printf '%s\n' 'root 0' 'me 501' 'u 601' 'v 602' ;; esac; }
    sudo() { echo "sudo $*" >> "$T/na.calls"; }
    mount() { cat "$T/na.mount" 2> /dev/null; }
    "$@"; echo "rc $? made ${na_made:-} uid ${na_uid:-}" )
}
: > "$T/na.calls"; r=$(nam nonadmin_make /img 2>&1)
expect smoke_nonadmin_make has "$r" "^rc 0 made 1 uid 603$"
expect smoke_nonadmin_make_staff grep -q 'PrimaryGroupID 20' "$T/na.calls"
expect smoke_nonadmin_make_hidden grep -q 'IsHidden 1' "$T/na.calls"
expect smoke_nonadmin_make_args grep -qF "_ lfs_nonadmin 603 $T/nah /img" "$T/na.calls"
expect smoke_nonadmin_make_chown_uid grep -qF 'chown -R "$2:20" "$3"' "$T/na.calls"
expect smoke_nonadmin_make_no_admin not grep -qw 'admin\|GroupMembership' "$T/na.calls"
: > "$T/na.calls"; : > "$T/na.exists"; r=$(nam nonadmin_make /img 2>&1)
expect smoke_nonadmin_exists has "$r" "^rc 1 made  uid"
expect smoke_nonadmin_exists_untouched not grep -q '^sudo' "$T/na.calls"
: > "$T/na.calls"; r=$(nam nonadmin_remove 2>&1)
expect smoke_nonadmin_remove_unmade test "$(cat "$T/na.calls")" = ""
rm -f "$T/na.exists"
: > "$T/na.calls"; r=$(nam_made=1; nam nonadmin_remove 2>&1)
expect smoke_nonadmin_remove has "$r" "^rc 0 made  uid"
expect smoke_nonadmin_remove_dscl grep -q 'dscl . -delete' "$T/na.calls"
expect smoke_nonadmin_remove_home grep -q 'rm -rf' "$T/na.calls"
echo "/dev/x on $T/nah/mnt (macfuse_ext4, local, mounted by lfs_nonadmin)" > "$T/na.mount"
: > "$T/na.calls"; r=$(nam_made=1; nam nonadmin_remove 2>&1)
expect smoke_nonadmin_remove_mounted_keeps_home not grep -q 'rm -rf' "$T/na.calls"
expect smoke_nonadmin_remove_mounted_dscl grep -q 'sudo -n dscl . -delete /Users/lfs_nonadmin' "$T/na.calls"
expect smoke_nonadmin_remove_mounted_said has "$r" "still mounted"
expect smoke_nonadmin_remove_no_unmount not grep -q 'unmount\|umount' "$T/na.calls"
rm -f "$T/na.mount" "$T/na.calls"
# (fix round 1, m2) the non-admin's volume is unmounted once, by root's diskutil unmount of its mount point (DiskArbitration
#   may refuse a user neither at the console nor an admin), never forced, and that is said
r=$( (eval "$(smoke_fn nonadmin_unmount)"; NA=lfs_nonadmin NAH=$T/nah na_uid=603 L=/p/linuxfs
  sudo() { echo "sudo $*" >> "$T/na.calls"; }; ps() { :; }; mount() { :; }; nonadmin_unmount; echo "rc $?") 2>&1)
expect smoke_nonadmin_unmount has "$r" "^rc 0$"
expect smoke_nonadmin_unmount_said has "$r" "^unmounted by: sudo -n diskutil unmount $T/nah/mnt$"
expect smoke_nonadmin_unmount_root grep -qxF "sudo -n diskutil unmount $T/nah/mnt" "$T/na.calls"
expect smoke_nonadmin_unmount_once test "$(grep -c unmount "$T/na.calls")" -eq 1
expect smoke_nonadmin_unmount_not_forced not grep -q 'force\|umount -f' "$T/na.calls"
rm -f "$T/na.calls"

# item 2 in the smoke: the six names exactly, never the macfuse_ prefix as a family, and no bundle under its old linuxfs name left
expect smoke_no_old_names test -z "$(grep -n 'linuxfs[_]' "$sm" "$here/lib/parity.sh" "$here/parity-test.sh")"
expect smoke_fstab_by_hand grep -qF "'LABEL=my\\040data none macfuse_ext4 rw,noauto # linuxfs'" "$sm"
expect smoke_apfs_mount_program test "$(grep -c 'pgrep -f mount_macfuse_apfs' "$sm")" -eq 3
# the FSNames are tools/fsrules.c's
fsn_bad=
for fs in ext4 ntfs btrfs xfs f2fs apfs; do
  want=$(awk -v f="\"$fs\"," -F'"' 'index($0, "{ " f) == 2 { print $12; exit }' "$here/../tools/fsrules.c")
  got=$(eval "$(smoke_fn fsname_of)"; fsname_of "$fs")
  test -n "$want" -a "$got" = "$want" || fsn_bad="$fsn_bad $fs:'$got'/'$want'"
done
expect smoke_fsnames test -z "$fsn_bad"
test -z "$fsn_bad" || echo "# fsname_of against fsrules.c:$fsn_bad"
# persona_is: personality, Type (Bundle) macfuse_FS, Name (User Visible) the FSName, and Mounted
du_says() { printf '   %s\n' "File System Personality:  $1" "Type (Bundle):            $2" "Name (User Visible):      $3" "Mounted:                  $4" > "$T/du"; }
persona() { (eval "$(smoke_fn info)"; eval "$(smoke_fn fsname_of)"; eval "$(smoke_fn persona_is)"; diskutil() { cat "$T/du"; }; persona_is /dev/disk9s1 "$@") > /dev/null 2>&1; }
du_says XFS macfuse_xfs 'Linux XFS (linuxfs)' Yes; expect smoke_persona_ok persona XFS xfs
du_says XFS macfuse_ext4 'Linux XFS (linuxfs)' Yes; expect smoke_persona_bundle not persona XFS xfs
du_says XFS macfuse_xfs 'Unknown (macfuse_xfs)' Yes; expect smoke_persona_fsname not persona XFS xfs
du_says XFS macfuse_xfs 'Linux XFS (linuxfs)' No; expect smoke_persona_mounted not persona XFS xfs
du_says xfs macfuse_xfs 'Linux XFS (linuxfs)' Yes; expect smoke_persona_personality not persona XFS xfs
# mount_type_is: mount shows the mount point as (TYPE, exactly
printf '%s\n' '/dev/disk4s1 on /Volumes/my data (macfuse_ext4, local, nodev, nosuid, synchronous, mounted by u)' \
  '/dev/disk5 on /Volumes/x (macfuse, local, nodev)' '/dev/disk6 on /Volumes/y (macfuse_ext4x, local)' > "$T/mounts"
mtype() { (eval "$(smoke_fn mount_type_is)"; mount() { cat "$T/mounts"; }; mount_type_is "$@") > /dev/null 2>&1; }
expect smoke_mount_type_ok mtype '/Volumes/my data' macfuse_ext4
expect smoke_mount_type_plain mtype /Volumes/x macfuse
expect smoke_mount_type_exact not mtype /Volumes/x macfuse_ext4
expect smoke_mount_type_no_prefix not mtype /Volumes/y macfuse_ext4
expect smoke_mount_type_no_family not mtype '/Volumes/my data' macfuse
expect smoke_mount_type_exfat test "$(eval "$(smoke_fn type_of)"; type_of exfat) $(eval "$(smoke_fn type_of)"; type_of apfs)" = 'macfuse macfuse_apfs'
# F7: macFUSE's own mount_macfuse as root is found, the bundles' mount_macfuse_<fs> never
rootps() { printf '%s\n' "$@" > "$T/ps"; (eval "$(smoke_fn no_root_mount_macfuse)"; ps() { cat "$T/ps"; }; no_root_mount_macfuse); }
expect smoke_root_helper_found not rootps 'root 12 /Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse -o allow_other /dev/fd/3'
expect smoke_root_helper_bare_found not rootps 'root 12 mount_macfuse'
expect smoke_root_bundle_ignored rootps 'root 13 /System/Library/Filesystems/macfuse_ext4.fs/Contents/Resources/mount_macfuse_ext4 -o nodev /dev/disk4s1 /Volumes/x' 'root 14 mount_macfuse_ntfs /dev/disk5 /Volumes/y'
expect smoke_root_helper_user_ignored rootps 'u 12 /Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse /dev/fd/3'
# the checks are where item 2 asks: each DiskArbitration cycle, each CLI image mount, ignore's entry, before login
expect smoke_type_in_da_cycle test -n "$(smoke_fn da_cycle | grep 'mount_type_is "$mp" "macfuse_$nm"')"
expect smoke_persona_in_da_cycle test -n "$(smoke_fn da_cycle | grep 'persona_is "$dev" "$want" "$nm"')"
expect smoke_type_in_noauto test "$(smoke_fn noauto_cycle | grep -c 'mount_type_is "$mp" "macfuse_$fs"')" -eq 1
expect smoke_ignore_entry_named test -n "$(smoke_fn noauto_cycle | grep 'macfuse_$fs')"
expect smoke_type_cli test "$(grep -c 'mount_type_is "$m" "$(type_of "$fs")"' "$sm")" -eq 2
expect smoke_type_cli_apfs test "$(grep -c 'mount_type_is "$m" macfuse_apfs' "$sm")" -eq 1
expect smoke_type_before_login ascending "$bl" "$(first_line 'mount_type_is "$mp" macfuse_ext4')"

# item 1 (Task 13b): the smoke tells the census which names mode its macFUSE means, before the census
expect smoke_names_want ascending "$(first_line 'PARITY_NAMES_WANT=exact')" "$(first_line '^ *parity_census_all$')"
expect smoke_names_want_by_macfuse grep -q 'if macfuse_at_least 5 5 0 5; then PARITY_NAMES_WANT=exact; else PARITY_NAMES_WANT=scanning; fi' "$sm"
# item 5 (Task 13b): the smoke returns system.log from its own start (the census's window in it), not its last 3000 lines;
#   across a turnover (the first line differs), the rest of the rotated file FIRST began, those after it, then the new one
printf '%s\n' first a b > "$T/sl"
r=$(printf '%s\n' c d >> "$T/sl"; syslog_since 3 first "$T/sl")
expect smoke_syslog_since test "$r" = "$(printf '%s\n' c d)"
# (fix round 1) 10.9's aslmanager rotates system.log by size, gzipped, as system.log.0.gz (newest) to .N.gz: the walk goes
#   back (bounded) to the file FIRST began; newsyslog's .bz2 is read when there is no .gz
printf '%s\n' first a b c | gzip > "$T/sl.0.gz"; printf '%s\n' new e > "$T/sl"
r=$(syslog_since 3 first "$T/sl")
expect smoke_syslog_rotated test "$r" = "$(printf '%s\n' c new e)"
printf '%s\n' first a b c | gzip > "$T/sl.1.gz"; printf '%s\n' x y | gzip > "$T/sl.0.gz"
r=$(syslog_since 3 first "$T/sl")
expect smoke_syslog_rotated_twice test "$r" = "$(printf '%s\n' c x y new e)"
printf '%s\n' other | gzip > "$T/sl.1.gz"
r=$(syslog_since 3 first "$T/sl")
expect smoke_syslog_lost_said has "$r" "^# syslog_since: "
expect smoke_syslog_lost_rest has "$r" "^x$"
expect smoke_syslog_lost_new test "$(printf '%s\n' "$r" | tail -n 2)" = "$(printf '%s\n' new e)"
expect smoke_syslog_walk_bounded test -n "$(sed -n '/^syslog_since()/,/^}/p' "$here/lib/parity.sh" | grep -e '-lt 20')"
# (Task 15 fix round 1) one reader: syslog_since and syslog_rotated live in parity.sh, which the smoke sources before
#   finish can need them
expect smoke_syslog_shared test -z "$(smoke_fn syslog_since)$(smoke_fn syslog_rotated)"
expect smoke_parity_sourced_early ascending "$(first_line '^ *\. ".*/lib/parity\.sh"')" "$(first_line '^installed=')"
rm -f "$T"/sl.*.gz
if command -v bzip2 > /dev/null 2>&1; then
  printf '%s\n' first a b c | bzip2 > "$T/sl.0.bz2"
  r=$(syslog_since 3 first "$T/sl")
  expect smoke_syslog_rotated_bz2 test "$r" = "$(printf '%s\n' c new e)"
else echo "ok - smoke_syslog_rotated_bz2 # SKIP no bzip2"; fi
rm -f "$T/sl" "$T/sl.0.bz2"
expect smoke_syslog_not_tail test -z "$(grep -n 'tail -n 3000' "$sm")"
expect smoke_syslog_mark ascending "$(first_line '^PARITY_T0=')" "$(first_line '^LOG0=')" "$(first_line '^installed=')"
expect smoke_syslog_in_finish test -n "$(smoke_fn finish | grep 'syslog_since "$LOG0" "$LOGHEAD"')"

# da_unmount and da_eject (item 4, Step 2): who holds the volume is sudo -n lsof on its mount point (every user's files,
#   root's too), never lsof +D as the user; an eject's failure also says DiskArbitration's view, mount's line and who has
#   the disk's devices open; the one retry stays (preflight F13), printed
expect smoke_no_lsof_D test -z "$(grep -n 'lsof +D' "$sm")"
busyfn() { # FAILS CMD...: the smoke's retry_busy (and da_unmount), diskutil failing FAILS times; calls in $T/busy.calls
  : > "$T/busy.calls"; echo "$1" > "$T/busy.left"; shift
  (eval "$(smoke_fn info)"; eval "$(smoke_fn holders)"; eval "$(smoke_fn retry_busy)"; eval "$(smoke_fn da_unmount)"
   eval "$(smoke_fn stop_and_ask)"; eval "$(smoke_fn mounted_by_root)"
   bounded() { shift; "$@"; }; sleep() { echo "sleep $*" >> "$T/busy.calls"; }
   diskutil() {
     echo "diskutil $*" >> "$T/busy.calls"
     case $1 in info) printf '   Mounted:                  No\n'; return 0 ;; esac
     k=$(cat "$T/busy.left"); test "$k" -gt 0 || return 0; echo $((k - 1)) > "$T/busy.left"; echo "Volume failed to eject"; return 1
   }
   sudo() { echo "sudo $*" >> "$T/busy.calls"; echo "COMMAND PID USER (stub)"; }
   mount() { echo "/dev/disk9 on /Volumes/x (macfuse_ext4, local, nodev, nosuid, synchronous, mounted by u)"; }
   "$@")
}
r=$(busyfn 1 da_unmount /Volumes/x 2>&1); rc=$?
expect smoke_da_unmount_retried test "$rc" -eq 0
expect smoke_da_unmount_sudo_lsof grep -qx 'sudo -n lsof /Volumes/x' "$T/busy.calls"
expect smoke_da_unmount_said has "$r" "^# diskutil unmount /Volumes/x failed; who holds /Volumes/x:$"
expect smoke_da_unmount_retry_said has "$r" "^# retrying diskutil unmount /Volumes/x$"
expect smoke_da_unmount_once test "$(grep -c '^diskutil unmount' "$T/busy.calls")" -eq 2
r=$(busyfn 0 da_unmount /Volumes/x 2>&1); rc=$?
expect smoke_da_unmount_quiet test "$rc" -eq 0 -a -z "$r" -a "$(grep -c . "$T/busy.calls")" -eq 1
r=$(busyfn 2 retry_busy /Volumes/x /dev/disk9 diskutil eject /dev/disk9 2>&1); rc=$?
expect smoke_eject_fails_twice test "$rc" -ne 0 -a "$(grep -c '^diskutil eject' "$T/busy.calls")" -eq 2
expect smoke_eject_da_view has "$r" "^#   DiskArbitration: disk9 Mounted: No$"
expect smoke_eject_mount_line has "$r" "^#   mount: /dev/disk9 on /Volumes/x (macfuse_ext4"
expect smoke_eject_lsof_mp grep -qx 'sudo -n lsof /Volumes/x' "$T/busy.calls"
expect smoke_da_eject_uses_retry test -n "$(smoke_fn da_eject | grep 'retry_busy "$2" "$1" diskutil eject "$1"')"

# no forced unmount, eject or detach ever targets a linuxfs disk (QEMU first)
forced=
for d in $(sort -u "$S/fsdisks"); do
  grep -Eq "^(hdiutil detach -force|diskutil unmountDisk force|diskutil unmount force) (/dev/)?$d(s1)?\$" "$S/calls.all" && forced="$forced $d"
done
expect census_no_force_on_fs test -z "$forced" -a -s "$S/fsdisks"
# (fix round 2) a linuxfs disk is never detached by force, mounted or not: census_attach's "not mounted within 60 s"
#   (a slow DiskArbitration mount: its lklfuse may be starting), a stalled plain attach in fl_iter, and fl_iter's no-UUID
#   path (swept or not) are ejected, and the eject retried, as census_detach fs does
forced_on() { grep -q "^hdiutil detach -force $1\$" "$S/calls.all"; }
for c in nevermount-stuck-a nevermount-stuck-b nouuid-stuck nouuid-swept-stuck; do echo "$c" > "$W/census/$c.img"; done
census_attach "$W/census/nevermount-stuck-a.img" > /dev/null 2>&1; d=$(cat "$S/disks")
expect never_mounted_attach_not_forced not forced_on "/dev/disk$d"
expect never_mounted_attach_retried test "$(grep -c "^diskutil eject /dev/disk$d\$" "$S/calls.all")" -ge 2
fl_iter ext4 2 1 "$W/census/nevermount-stuck-b.img" > /dev/null 2>&1; d=$(cat "$S/disks")
expect never_mounted_stall_not_forced not forced_on "/dev/disk$d"
expect never_mounted_stall_retried test "$(grep -c "^diskutil eject /dev/disk$d\$" "$S/calls.all")" -ge 2
fl_iter ext4 1 1 "$W/census/nouuid-stuck.img" > /dev/null 2>&1; d=$(cat "$S/disks")
expect never_mounted_nouuid_not_forced not forced_on "/dev/disk$d"
expect never_mounted_nouuid_retried test "$(grep -c "^diskutil eject /dev/disk$d\$" "$S/calls.all")" -ge 2
# (fix round 4) fl_iter's "no noauto entry" setup failure (linuxfs ignore wrote none) on a disk never mounted: ejected,
#   retried, never forced
echo noentry-stuck > "$W/census/noentry-stuck.img"; : > "$S/ignore-fails"
fl_iter ext4 1 1 "$W/census/noentry-stuck.img" > /dev/null 2>&1; d=$(cat "$S/disks")
rm -f "$S/ignore-fails"
expect never_mounted_noentry_said grep -q '^ext4-loop1-1: setup failed: no noauto entry for UUID UUID-noentry-stuck$' "$P/stall.txt"
expect never_mounted_noentry_not_forced not forced_on "/dev/disk$d"
expect never_mounted_noentry_retried test "$(grep -c "^diskutil eject /dev/disk$d\$" "$S/calls.all")" -ge 2
fl_iter ext4 1 1 "$W/census/nouuid-swept-stuck.img" > /dev/null 2>&1; d=$(cat "$S/disks")
expect swept_nouuid_not_forced not forced_on "/dev/disk$d"
expect swept_nouuid_retried test "$(grep -c "^diskutil eject /dev/disk$d\$" "$S/calls.all")" -ge 2
rm -f "$S/nodes/disk$d" "$S/nodes/disk$d.m"   # the leftover goes without a stub call, so no forced detach is logged
drop_stuck nevermount-stuck; drop_stuck nouuid-stuck; drop_stuck noentry-stuck; rm -f "${W:?}/census/noentry-stuck.img"
# (fix round 2) census_detach_checked's Apple side (nothing mounted) is detached by force only when no lklfuse names
#   the disk: with one on it, or ps unable to say, it is ejected only
for c in held plain; do echo "$c" > "$W/census/sweep-stuck-hfs-$c.img"; done
hdiutil attach -nomount "$W/census/sweep-stuck-hfs-held.img" > /dev/null 2>&1; d=disk$(cat "$S/disks")
echo "$d" > "$S/lklfuse-holds"; census_detach_checked "/dev/$d" apple > /dev/null 2>&1; rm -f "$S/lklfuse-holds"
expect census_detach_checked_held_not_forced not forced_on "/dev/$d"
: > "$S/ps-fail"; census_detach_checked "/dev/$d" apple > /dev/null 2>&1; rm -f "$S/ps-fail"
expect census_detach_checked_psless_not_forced not forced_on "/dev/$d"
hdiutil attach -nomount "$W/census/sweep-stuck-hfs-plain.img" > /dev/null 2>&1; d=disk$(cat "$S/disks")
census_detach_checked "/dev/$d" apple > /dev/null 2>&1
expect census_detach_checked_apple_forced forced_on "/dev/$d"
drop_stuck sweep-stuck-hfs; rm -f "${W:?}"/census/sweep-stuck-hfs-*.img
# item 7's recovery: the remount's linuxfs attach never mounts and cannot be detached: the case step is skipped, said,
#   and the stale disk is not ejected again
echo flaky5 > "$W/img/flaky5.img"; first=disk$(($(cat "$S/disks") + 2))
r=$(census_trash_tags_case flaky5 2>&1)
expect census_ttc_stale_said has "$r" "^# census_trash_tags_case flaky5: /dev/disk[0-9]* is attached but not mounted as the pair's volume, so no case step"
expect census_ttc_stale_no_case test ! -e "$P/case.flaky5.pathconf.flaky5.txt"
expect census_ttc_stale_not_ejected_again test "$(grep -c "^diskutil eject /dev/$first\$" "$S/calls.all")" -eq 1
for f in "$S"/nodes/*; do case $f in *.m | *.u) ;; *) test -f "$f" || continue; case $(sed -n 's/^vol=//p' "$f") in *flaky5*) rm -f "$f" "$f.m" "$f.u" ;; esac ;; esac; done
rm -f "$W/img/flaky5.img"
expect census_waits_bounded test ! -s "$unbounded"
test ! -s "$unbounded" || sed 's/^/# /' "$unbounded"

# da_attach_retry (tests/lib/attach-retry.sh): a plain attach that stalls with "no mountable file systems" is tried once more,
#   printed and recorded; any other failure, and a second stall, are not retried again
. "$here/lib/attach-retry.sh"
image_disk() { census_image_disk "$1"; }
echo ar > "$W/img/retry-once.img"; echo ar > "$W/img/retry-always.img"; echo ar > "$W/img/plain-ar.img"
rm -f "$P/attach-retries.txt"
r=$(da_attach_retry "$W/img/plain-ar.img" 2>&1); rc=$?
expect attach_retry_none_rc test "$rc" -eq 0
expect attach_retry_none_quiet hasnt "$r" "retrying"
expect attach_retry_none_unrecorded test ! -e "$P/attach-retries.txt"
r=$(da_attach_retry "$W/img/retry-once.img" 2>&1); rc=$?
expect attach_retry_once_rc test "$rc" -eq 0
expect attach_retry_once_said has "$r" "^# retrying hdiutil attach: hdiutil: attach failed - no mountable file systems$"
expect attach_retry_once_recorded grep -q "retry-once.img: no mountable file systems$" "$P/attach-retries.txt"
r=$(da_attach_retry "$W/img/retry-always.img" 2>&1); rc=$?
expect attach_retry_always_fails test "$rc" -ne 0
expect attach_retry_always_once test "$(printf '%s\n' "$r" | grep -c '^# retrying hdiutil attach')" -eq 1
expect attach_retry_always_recorded test "$(grep -c "retry-always.img" "$P/attach-retries.txt")" -eq 1
expect attach_retry_counted test "$(attach_retries)" -eq 2
# any other failure is not retried: no retry line, no record
echo ar > "$W/img/other-fail.img"
mkdir -p "$T/bin2"; printf '#!/bin/sh\necho "hdiutil: attach failed - Resource temporarily unavailable" >&2; exit 1\n' > "$T/bin2/hdiutil"; chmod +x "$T/bin2/hdiutil"
r=$(PATH=$T/bin2:$PATH; da_attach_retry "$W/img/other-fail.img" 2>&1); rc=$?
expect attach_retry_other_fails test "$rc" -ne 0
expect attach_retry_other_quiet hasnt "$r" "retrying"
expect attach_retry_other_unrecorded test "$(attach_retries)" -eq 2
rm -f "$W/img/other-fail.img"; rm -rf "$T/bin2"
# the census counts stalls, so it never retries one; the smoke's finish says the count
expect attach_retry_not_in_census test "$(grep -c 'da_attach_retry' "$here/lib/parity.sh")" -eq 0
expect attach_retry_count_said grep -q '^  ar=$(attach_retries' "$here/smoke-mavericks.sh"
rm -f "$W/img"/retry-*.img "$W/img/plain-ar.img"

# owners_fstab_add and owners_fstab_gone (tests/lib/owners-fstab.sh): the smoke's owners line goes on a line of its own
#   even when /etc/fstab ends without a newline, and taking it away leaves every other entry as it was
. "$here/lib/owners-fstab.sh"
OF=$T/owners-fstab OT='# linuxfs-smoke-owners'
r=$(sudo() { test "$1" != -n || shift; "$@"; }
  printf 'UUID=A none hfs rw,noauto' > "$OF"
  owners_fstab_add "$OF" "UUID=B none macfuse_ext4 rw,owners $OT"; echo "add $?"
  awk '{ print NR ": " $0 }' "$OF"
  owners_fstab_gone "$OF" "$OT"; echo "gone $?"
  awk '{ print "after " NR ": " $0 }' "$OF")
expect owners_fstab_add_ok has "$r" "^add 0$"
expect owners_fstab_add_own_line has "$r" "^2: UUID=B none macfuse_ext4 rw,owners $OT$"
expect owners_fstab_add_keeps_last has "$r" "^1: UUID=A none hfs rw,noauto$"
expect owners_fstab_gone_ok has "$r" "^gone 0$"
expect owners_fstab_gone_keeps test "$(printf '%s\n' "$r" | grep -c '^after ')" -eq 1 -a -n "$(printf '%s\n' "$r" | grep -x 'after 1: UUID=A none hfs rw,noauto')"
r=$(sudo() { test "$1" != -n || shift; "$@"; }
  printf 'UUID=A none hfs rw,noauto\n' > "$OF"; owners_fstab_add "$OF" "UUID=B none macfuse_ext4 rw,owners $OT"; wc -l < "$OF" | tr -d ' ')
expect owners_fstab_add_no_blank test "$r" = 2
r=$(sudo() { test "$1" != -n || shift; "$@"; }; rm -f "$OF"; owners_fstab_add "$OF" "x $OT"; cat "$OF")
expect owners_fstab_add_new_file test "$r" = "x $OT"
r=$(sudo() { return 1; }; printf 'x %s\n' "$OT" > "$OF"; owners_fstab_gone "$OF" "$OT"; echo "gone $?")
expect owners_fstab_gone_says_left has "$r" "^gone 1$"
# the copy is written back only when it was written whole: a temp path that cannot be written (here a directory) leaves
#   FSTAB as it was, and says the line is still there
r=$(sudo() { test "$1" != -n || shift; "$@"; }; printf 'UUID=A none hfs rw,noauto\nx %s\n' "$OT" > "$OF"; mkdir "$OF.owners-tmp"
  owners_fstab_gone "$OF" "$OT"; echo "gone $?"; awk '{ print "kept " NR ": " $0 }' "$OF"; rmdir "$OF.owners-tmp")
expect owners_fstab_gone_tmp_fails has "$r" "^gone 1$"
expect owners_fstab_gone_tmp_fails_intact test "$(printf '%s\n' "$r" | grep -c '^kept ')" -eq 2 -a -n "$(printf '%s\n' "$r" | grep -x 'kept 1: UUID=A none hfs rw,noauto')"
expect owners_fstab_in_smoke grep -q '^\. "$tests_dir/lib/owners-fstab.sh"' "$here/smoke-mavericks.sh"
rm -f "$OF"

# spec: .superpowers/sdd/2026-11-25-hfs-parity/push-d-debug.md -- push E (Task 16e): DiskArbitration's mounts passed no allow_root (the
#   mount program's process has not the user's groups), so root's fseventsd and mds were refused on them, as in push C. The three
#   steps that need them let in on a DiskArbitration volume (.fseventsd's parity, the refusals bar, busy-fsevents) take
#   PARITY_MODE_FSEVENTS_DA, record in push E; Task 16l (the mount daemon: root mounts them) puts it back to check (modes_f), with
#   the other item 5, item 4 and item 6 gates, and the census's 132 minutes unchanged
r=$(unset PARITY_MODE_SPOTLIGHT PARITY_MODE_SPOTLIGHT_DA PARITY_MODE_BUSY_DA PARITY_MODE_FSEVENTS_DA PARITY_CENSUS_MIN; . "$here/lib/parity.sh"
  echo "$PARITY_MODE_FSEVENTS_DA $PARITY_MODE_SPOTLIGHT $PARITY_MODE_SPOTLIGHT_DA $PARITY_MODE_BUSY_DA $PARITY_CENSUS_MIN")
expect modes_f test "$r" = "check check check check 132"
expect modes_f_spec has "$(sed -n '/^# spec: .*push-d-debug.md/,/^PARITY_MODE_FSEVENTS_DA=/p' "$here/lib/parity.sh")" 'Task 16l'
expect modes_f_spec_default grep -qx 'PARITY_MODE_FSEVENTS_DA=${PARITY_MODE_FSEVENTS_DA:-check}' "$here/lib/parity.sh"
# record is still a mode it takes (a slack push may need it): the three steps recorded, said so
rm -f "$OUT"/*-refresh.png "$OUT"/*-privacy.png "$OUT"/*-privacy-ro.png
: > "$S/calls"; : > "$S/fsevents-refused"
r=$(PARITY_MODE_FSEVENTS_DA=record; census_spotlight ext4 2>&1
  census_refusals_bar 0 2>&1
  printf '%s\n' 'hfs: fsevents: .fseventsd yes' 'ext4: fsevents: .fseventsd no' > "$T/bf.log"
  census_busy_fsevents spotlight.ext4.busy-fsevents ext4 "$T/bf.log" 2>&1)
rm -f "$S/fsevents-refused"
for p in rw ro; do expect "fsevents_da_record_${p}_fseventsd" has "$r" "^# recorded spotlight.ext4.$p.fseventsd\$"; done
expect fsevents_da_record_refusals has "$r" "^# recorded spotlight: no refusals for linuxfs volumes ([1-9][0-9]* lines"
expect fsevents_da_record_busy has "$r" "^# recorded spotlight.ext4.busy-fsevents: .*ext4 no\$"
expect fsevents_da_record_quiet hasnt "$r" "not ok"
# under the defaults (Task 16l), the three are checked: not ok, root's fseventsd refused
rm -f "$OUT"/*-refresh.png "$OUT"/*-privacy.png "$OUT"/*-privacy-ro.png
: > "$S/calls"; : > "$S/fsevents-refused"
r=$(unset PARITY_MODE_FSEVENTS_DA; . "$here/lib/parity.sh"; census_spotlight ext4 2>&1
  census_refusals_bar 0 2>&1
  census_busy_fsevents spotlight.ext4.busy-fsevents ext4 "$T/bf.log" 2>&1)
rm -f "$S/fsevents-refused" "$T/bf.log"
for p in rw ro; do expect "fsevents_da_check_${p}_fseventsd" has "$r" "^not ok - parity spotlight.ext4.$p.fseventsd\$"; done
expect fsevents_da_check_refusals has "$r" "^not ok - spotlight: no refusals for linuxfs volumes ([1-9][0-9]* lines"
expect fsevents_da_check_busy has "$r" "^not ok - parity spotlight.ext4.busy-fsevents "
# (r0 M3) root's mds is refused on DiskArbitration volumes as root's fseventsd is: with indexing on for the HFS+ control, the indexing
#   steps (index and da) are recorded too while PARITY_MODE_FSEVENTS_DA is record, said why; under check (the default since Task 16l)
#   they are checked
rm -f "$OUT"/*-refresh.png "$OUT"/*-privacy.png "$OUT"/*-privacy-ro.png
: > "$S/calls"
r=$(PARITY_MODE_FSEVENTS_DA=record; census_spotlight ext4 2>&1)
for p in rw ro; do
  for s in mdutil mdfind store privacy-off privacy-remount; do expect "fsevents_da_index_record_${p}_$s" has "$r" "^# recorded spotlight.ext4.$p.$s\$"; done
  expect "fsevents_da_index_record_${p}_said" has "$r" "^# spotlight.ext4.$p: the indexing steps are recorded: indexing is on for the HFS+ control, but root's mds is not let into a DiskArbitration volume until the mount daemon (PARITY_MODE_FSEVENTS_DA is record)\$"
done
expect fsevents_da_index_record_refresh has "$r" "^# recorded spotlight.ext4.rw.refresh$"
expect fsevents_da_index_record_quiet hasnt "$r" "not ok"
rm -f "$OUT"/*-refresh.png "$OUT"/*-privacy.png "$OUT"/*-privacy-ro.png
r=$(unset PARITY_MODE_FSEVENTS_DA; . "$here/lib/parity.sh"; census_spotlight ext4 2>&1)
for s in mdfind store mdutil; do expect "fsevents_da_index_check_$s" has "$r" "^ok - parity spotlight.ext4.rw.$s\$"; done
# PARITY_MODE_SPOTLIGHT record still records them; a mode that is neither is not ok, named
r=$(PARITY_MODE_SPOTLIGHT=record PARITY_MODE_FSEVENTS_DA=check; printf 'xfs: fsevents: .fseventsd no\n' > "$T/bf.log"; census_busy_fsevents spotlight.xfs.busy-fsevents xfs "$T/bf.log" 2>&1)
expect fsevents_da_spotlight_record has "$r" "^# recorded spotlight.xfs.busy-fsevents"
r=$(PARITY_MODE_FSEVENTS_DA=chek; census_busy_fsevents spotlight.xfs.busy-fsevents xfs "$T/bf.log" 2>&1)
expect fsevents_da_badmode has "$r" "^not ok - parity spotlight.xfs.busy-fsevents$"
expect fsevents_da_badmode_named has "$r" "PARITY_MODE_FSEVENTS_DA is 'chek'"
r=$(reset; pair; PARITY_MODE_FSEVENTS_DA=chek; census_spot_parity fsevents spotlight.x.fseventsd ls @MP@ 2>&1)
expect fsevents_da_badmode_parity has "$r" "^not ok - parity spotlight.x.fseventsd"
expect fsevents_da_badmode_parity_named has "$r" "PARITY_MODE_FSEVENTS_DA is 'chek'"
rm -f "$T/bf.log"
# the smoke (push D's phantoms): after each DiskArbitration mount in da_cycle, the mount is in the table (da_mount_true) and system.log
#   since the attach or the mount has no mount_macfuse or libfuse mount failure (no_mount_failed)
dc=$(sed -n '/^da_cycle()/,/^}/p' "$sm")
expect da_cycle_checks_first has "$(printf '%s\n' "$dc" | grep -A 2 'mounted at $mp within 30 s"')" 'da_mount_true "$dev" "$mp" "$nm"'
expect da_cycle_checks_first_log has "$(printf '%s\n' "$dc" | grep -A 2 'mounted at $mp within 30 s"')" 'no_mount_failed "$pos"'
expect da_cycle_checks_again has "$(printf '%s\n' "$dc" | grep -A 2 'mounted again at $mp"')" 'da_mount_true "$dev" "$mp" "$nm"'
expect da_cycle_checks_again_log has "$(printf '%s\n' "$dc" | grep -A 2 'mounted again at $mp"')" 'no_mount_failed "$pos"'
expect da_cycle_pos_attach has "$(printf '%s\n' "$dc" | grep -B 1 'da_attach "$img"')" 'pos=$(log_pos)'
expect da_cycle_pos_mount has "$(printf '%s\n' "$dc" | grep -B 1 'diskutil mount" bounded')" 'pos=$(log_pos)'
eval "$(sed -n '/^da_mount_true()/,/^}/p; /^no_mount_failed()/,/^}/p' "$sm")"
r=$(info() { echo Yes; }; mount() { echo '/dev/disk0s2 on / (hfs, local, journaled)'; }; da_mount_true /dev/disk5 /Volumes/x ext4; echo "rc $?")
expect da_mount_true_phantom has "$r" "^rc 1$"
r=$(info() { echo Yes; }; mount() { echo '/dev/disk5 on /Volumes/x (macfuse_ext4, local, nodev, nosuid, mounted by me)'; }; da_mount_true /dev/disk5 /Volumes/x ext4; echo "rc $?")
expect da_mount_true_there has "$r" "^rc 0$"
r=$(info() { echo No; }; mount() { echo '/dev/disk5 on /Volumes/x (macfuse_ext4, local, nodev, nosuid, mounted by me)'; }; da_mount_true /dev/disk5 /Volumes/x ext4; echo "rc $?")
expect da_mount_true_not_said has "$r" "^rc 1$"
r=$(info() { echo Yes; }; mount() { echo '/dev/disk5s1 on /Volumes/x (macfuse_ext4, local)'; echo '/dev/disk5 on /Volumes/xy (macfuse_ext4, local)'; echo '/dev/disk5 on /Volumes/x (macfuse_xfs, local)'; }; da_mount_true /dev/disk5 /Volumes/x ext4; echo "rc $?")
expect da_mount_true_exact has "$r" "^rc 1$"
r=$(syslog_since() { printf '%s\n' 'Nov 25 kernel: something' 'Nov 25 mount_macfuse[9]: mount_macfuse: failed to mount /Volumes/Windows@/dev/macfuse0: Operation not permitted'; }; no_mount_failed '5|head'; echo "rc $?")
expect no_mount_failed_macfuse has "$r" "^rc 1$"
expect no_mount_failed_says has "$r" "failed to mount /Volumes/Windows"
r=$(syslog_since() { echo 'Nov 25 lklfuse[9]: fuse: mount failed with error: 1'; }; no_mount_failed '5|head'; echo "rc $?")
expect no_mount_failed_libfuse has "$r" "^rc 1$"
r=$(syslog_since() { echo "$1|$2" > "$T/nmf.args"; echo 'Nov 25 linuxfs-mount[9]: mount_ext4: /dev/disk5: exit 0'; }; no_mount_failed '5|head line'; echo "rc $?")
expect no_mount_failed_clean has "$r" "^rc 0$"
expect no_mount_failed_pos test "$(cat "$T/nmf.args")" = "5|head line"
rm -f "$T/nmf.args"

# ---- Task 16l: root's automounts (the mount daemon), in the census and the smoke ----
# census_da_root DEV MP FS POS: the smoke's checks of a DiskArbitration mount (da_mount_true, no_mount_failed, da_root_mount,
#   no_owner_pseudo) as one check, bounded at 10 s: ok on the stand-in (root's mount, nodev and nosuid, root's mount_macfuse -o
#   allow_other with fsname=/dev/DEV, mounted by root and served by _linuxfs); not ok, said why, for a fallback user mount, no
#   nodev, macFUSE's refusal, DiskArbitration's ?owner= entry, and a phantom (Mounted: Yes, nothing in mount)
dr() { # FLAG: a fresh stand-in linuxfs disk attached with $S/FLAG, census_da_root on it, then ejected
  : > "${S:?}/$1"; echo dr > "${W:?}/census/daroot-$1.img"
  dr_pos=$(census_log_pos); census_attach "$W/census/daroot-$1.img" > /dev/null 2>&1
  census_da_root "$CA_DEV" "$CA_MP" ext4 "$dr_pos" 2>&1
  rm -f "${S:?}/${1:?}"; census_detach "$CA_DISK" fs "$CA_MP" > /dev/null 2>&1; rm -f "${W:?}/census/daroot-${1:?}.img"
}
r=$(dr da-none)
expect census_da_root_ok has "$r" "^ok - census ext4: /dev/disk[0-9]* on .*/vols/daroot-da-none is root's mount, true to DiskArbitration$"
r=$(dr da-user-mount)
expect census_da_root_user_mount has "$r" "^not ok - census ext4: /dev/disk[0-9]* on .*/vols/daroot-da-user-mount is root's mount"
expect census_da_root_user_mount_named has "$r" "^# .*not root's mount: mounted by vagrant"
r=$(dr da-no-nodev)
expect census_da_root_no_nodev has "$r" "^not ok - census ext4: "
expect census_da_root_no_nodev_said has "$r" "^# .*has no nodev"
r=$(dr da-macfuse-failed)
expect census_da_root_macfuse_failed has "$r" "^not ok - census ext4: "
expect census_da_root_macfuse_failed_said has "$r" "^# .*mount_macfuse: failed to mount"
r=$(dr da-owner-pseudo)
expect census_da_root_owner_pseudo has "$r" "^not ok - census ext4: "
expect census_da_root_owner_pseudo_said has "$r" "^# .*id = .*/vols/daroot-da-owner-pseudo?owner=0"
r=$(dr da-phantom)
expect census_da_root_phantom has "$r" "^not ok - census ext4: "
expect census_da_root_phantom_said has "$r" "^# DiskArbitration: Mounted: Yes; mount: nothing from /dev/disk"
expect census_da_root_bounded test -n "$(sed -n '/^census_da_root()/,/^}/p' "$here/lib/parity.sh" | grep 'bounded 100 census_da_root_checks "\$@"')"
expect census_da_root_checks test -n "$(sed -n '/^census_da_root_checks()/,/^}/p' "$here/lib/parity.sh" | grep 'da_mount_true .*no_mount_failed .*da_root_mount .*no_owner_pseudo')"
# census_pair_up runs it on the pair's linuxfs side, once (the HFS+ control is Apple's)
echo h > "$W/census/pu-hfs.img"; echo f > "$W/census/pu-xfs.img"; pu_before=$(attached)
r=$(census_pair_up "$W/census/pu-hfs.img" "$W/census/pu-xfs.img" xfs 2>&1; census_pair_down > /dev/null 2>&1)
rm -f "${W:?}/census/pu-hfs.img" "${W:?}/census/pu-xfs.img"
expect census_pair_up_da_root test "$(printf '%s\n' "$r" | grep -c "^ok - census xfs: /dev/disk[0-9]* on .*/vols/pu-xfs is root's mount")" -eq 1
expect census_pair_up_da_root_once test "$(printf '%s\n' "$r" | grep -c "root's mount")" -eq 1
expect census_pair_up_detached test "$(attached)" = "$pu_before"

# census_lklfuse_gone MP by root's records (_linuxfs's, through sudo): it waits while a record's pid naming MP still runs lklfuse
#   (a root mount's lklfuse serves /dev/fd/N, which no command line ends in MP), and returns once that pid is gone
mkdir -p "$S/rootstate"; printf '/dev/rdisk7\t/Volumes/r\text4\trw\n' > "$S/rootstate/4321"; : > "$T/lgr.alive"
lgr() { # CMD...: CMD with the real bounded, the real sleep, and a ps where pid 4321 is an lklfuse while $T/lgr.alive is there
  ( unset -f sleep; bounded() { bounded_real "$@"; }
    ps() {
      case "$*" in
      *pid=,command=*) echo "  99 /p/other"; test ! -f "$T/lgr.alive" || echo " 4321 /p/lklfuse -f -o x /dev/fd/3 /dev/fd/4" ;;
      *"-p 4321"*) test -f "$T/lgr.alive" || return 1; echo S ;;
      *-p*) return 1 ;;
      *) echo "u /p/other" ;;
      esac
    }
    "$@" ) > /dev/null 2>&1
}
lgr bounded 20 census_lklfuse_gone /Volumes/r; rc=$?
expect census_lklfuse_gone_record_waits test "$rc" -eq 124
lgr bounded 20 census_lklfuse_gone /Volumes/elsewhere; rc=$?
expect census_lklfuse_gone_record_other_mp test "$rc" -eq 0
( /bin/sleep 1; rm -f "${T:?}/lgr.alive" ) &
lgr bounded 100 census_lklfuse_gone /Volumes/r; rc=$?
expect census_lklfuse_gone_record_returns test "$rc" -eq 0 -a ! -f "$T/lgr.alive"
wait
# census_lklfuse_on DISK by root's records too: a live lklfuse's record names /dev/rDISK (or a slice); a dead one's does not count
: > "$T/lgr.alive"
lgr census_lklfuse_on /dev/disk7; rc=$?
expect census_lklfuse_on_record test "$rc" -eq 0
rm -f "${T:?}/lgr.alive"
lgr census_lklfuse_on /dev/disk7; rc=$?
expect census_lklfuse_on_record_dead test "$rc" -eq 1
rm -rf "${S:?}/rootstate"

# census_names_mode reads _linuxfs's lklfuse log (through sudo) when the user's has none: a root mount's lklfuse runs as _linuxfs
rm -f "$P/names-mode.txt"; mkdir -p "$S/rootlogs" "$S/lklogs"; printf '%s\n' 'lklfuse: names: exact (root)' > "$S/rootlogs/rdisk77.log"
r=$(mount() { echo "/dev/disk77 on /Volumes/n (macfuse_ext4, local, nodev, nosuid)"; }; census_names_mode disk77 /Volumes/n; cat "$P/names-mode.txt")
expect census_names_mode_root test "$r" = "disk77 /Volumes/n: exact (root)"
expect census_names_mode_root_sudo grep -q "^sudo -n cat $S/rootlogs/rdisk77.log$" "$S/calls.all"
rm -f "$P/names-mode.txt"; printf '%s\n' 'lklfuse: names: scanning (user)' > "$S/lklogs/rdisk77.log"
r=$(mount() { echo "/dev/disk77 on /Volumes/n (macfuse_ext4, local, nodev, nosuid, mounted by u)"; }; census_names_mode disk77 /Volumes/n; cat "$P/names-mode.txt")
expect census_names_mode_user_first test "$r" = "disk77 /Volumes/n: scanning (user)"
# r0 M4: a root mount (no "mounted by") reads _linuxfs's log first: a stale user log for the same node (phase 1's CLI) is not its
rm -f "$P/names-mode.txt"; printf '%s\n' 'lklfuse: names: exact (root)' > "$S/rootlogs/rdisk77.log"
r=$(mount() { echo "/dev/disk77 on /Volumes/n (macfuse_ext4, local, nodev, nosuid)"; }; census_names_mode disk77 /Volumes/n; cat "$P/names-mode.txt")
expect census_names_mode_root_first test "$r" = "disk77 /Volumes/n: exact (root)"
rm -f "$P/names-mode.txt"; rm -f "${S:?}/rootlogs/rdisk77.log"
r=$(mount() { echo "/dev/disk77 on /Volumes/n (macfuse_ext4, local, nodev, nosuid)"; }; census_names_mode disk77 /Volumes/n; cat "$P/names-mode.txt")
expect census_names_mode_root_then_user test "$r" = "disk77 /Volumes/n: scanning (user)"
rm -f "$P/names-mode.txt" "${S:?}/rootlogs/rdisk77.log" "${S:?}/lklogs/rdisk77.log"

# the smoke's checks of root's automounts
expect smoke_mountd_ready_first ascending "$(first_line '^check "the mount daemon is loaded.*" mountd_ready$')" "$(first_line 'then da_cycle "\$fs"')"
mr() { (eval "$(smoke_fn mountd_ready)"; MOUNTD=dev.mavergreen.linuxfs.mountd MOUNTD_SOCK=/var/run/dev.mavergreen.linuxfs.mountd.sock
  sudo() { echo "sudo $*" >> "$T/mr.calls"; test -z "$mr_unloaded"; }; stat() { echo "$mr_stat"; }; mountd_ready) > /dev/null 2>&1; }
: > "$T/mr.calls"
mr_unloaded= mr_stat="root srw-rw-rw-"; expect smoke_mountd_ready mr
expect smoke_mountd_ready_launchctl grep -qx 'sudo -n launchctl list dev.mavergreen.linuxfs.mountd' "$T/mr.calls"
mr_unloaded=1; expect smoke_mountd_ready_unloaded not mr
mr_unloaded= mr_stat="root srwxr-xr-x"; expect smoke_mountd_ready_mode not mr
mr_stat="daemon srw-rw-rw-"; expect smoke_mountd_ready_owner not mr
mr_stat=""; expect smoke_mountd_ready_no_socket not mr
expect smoke_mountd_ready_bounded test -n "$(smoke_fn mountd_ready | grep 'bounded 100 sudo -n launchctl list')"
# root_lklfuse_of MP: from root's records (_linuxfs's, read through sudo), the pid whose mount point is MP, of a live lklfuse
mkdir -p "$T/rs"; printf '/dev/rdisk5\t/Volumes/my data\text4\trw\n' > "$T/rs/4321"; printf '/dev/rdisk4\t/Volumes/my data\text4\trw\n' > "$T/rs/4322"
printf '/dev/rdisk6\t/Volumes/other\text4\trw\n' > "$T/rs/4323"
rl() { # CMD...: the smoke's root_lklfuse_of, da_served and lklfuses, sudo serving $T/rs, ps as $T/rl.ps and $T/rl.ax say, syslog_since $T/rl.log
  (eval "$(smoke_fn root_lklfuse_of)"; eval "$(smoke_fn da_served)"; eval "$(smoke_fn lklfuses)"; eval "$(smoke_fn no_root_lklfuse)"
   LINUXFS_ROOT_STATE=$T/rs tab=$(printf '\t')
   sudo() { test "$1" != -n || shift; "$@"; }
   ps() {
     case "$*" in
     *-axww*) cat "$T/rl.ax" 2> /dev/null ;;
     *"-p 4322"*) return 1 ;;
     *user=*) sed -n 1p "$T/rl.ps" ;;
     *-p*) sed -n 1p "$T/rl.ps" | cut -d ' ' -f 2- ;;
     esac
   }
   syslog_since() { cat "$T/rl.log"; }
   "$@")
}
echo "_linuxfs /p/lklfuse -f -o type=ext4,lock=/dev/fd/7,volname=my data,fsname=/dev/disk5,uid=99,gid=99 /dev/fd/3 /dev/fd/4" > "$T/rl.ps"
: > "$T/rl.ax"; : > "$T/rl.log"
r=$(rl root_lklfuse_of '/Volumes/my data' 2>&1)
expect smoke_root_lklfuse_of test "$r" = 4321
expect smoke_root_lklfuse_of_bounded test -n "$(smoke_fn root_lklfuse_of | grep 'bounded 100 sudo -n ')"
# da_served MP [owners POS]: that pid runs lklfuse as _linuxfs, its -o holds uid=99,gid=99 (owners: no uid=, and root's mount_macfuse
#   -o line in system.log has default_permissions), and no lklfuse runs as root
r=$(rl da_served '/Volumes/my data' 2>&1); rc=$?
expect smoke_da_served test "$rc" -eq 0
echo "vagrant /p/lklfuse -f -o type=ext4,volname=my data,uid=99,gid=99 /dev/fd/3 /dev/fd/4" > "$T/rl.ps"
r=$(rl da_served '/Volumes/my data' 2>&1); rc=$?
expect smoke_da_served_user test "$rc" -ne 0
echo "_linuxfs /p/lklfuse -f -o type=ext4,volname=my data,uid=501,gid=20 /dev/fd/3 /dev/fd/4" > "$T/rl.ps"
r=$(rl da_served '/Volumes/my data' 2>&1); rc=$?
expect smoke_da_served_ids test "$rc" -ne 0
echo "_linuxfs /p/lklfuse -f -o type=ext4,volname=my data,uid=99,gid=99 /dev/fd/3 /dev/fd/4" > "$T/rl.ps"
echo "root 77 /p/lklfuse -f -o x /dev/disk9 /Volumes/z" > "$T/rl.ax"
r=$(rl da_served '/Volumes/my data' 2>&1); rc=$?
expect smoke_da_served_root_lklfuse test "$rc" -ne 0
: > "$T/rl.ax"
r=$(rl da_served '/Volumes/elsewhere' 2>&1); rc=$?
expect smoke_da_served_no_record test "$rc" -ne 0
echo "_linuxfs /p/lklfuse -f -o type=ext4,volname=my data /dev/fd/3 /dev/fd/4" > "$T/rl.ps"
echo "Nov 25 linuxfs-mount[9]: mount_ext4: disk5 on /Volumes/my data: mount_macfuse -o allow_other,nosuid,nodev,default_permissions,local,fsname=/dev/disk5 (pid 9)" > "$T/rl.log"
r=$(rl da_served '/Volumes/my data' owners '5|head' 2>&1); rc=$?
expect smoke_da_served_owners test "$rc" -eq 0
r=$(rl da_served '/Volumes/my data' 2>&1); rc=$?
expect smoke_da_served_owners_unasked test "$rc" -ne 0
echo "_linuxfs /p/lklfuse -f -o type=ext4,volname=my data,uid=99,gid=99 /dev/fd/3 /dev/fd/4" > "$T/rl.ps"
r=$(rl da_served '/Volumes/my data' owners '5|head' 2>&1); rc=$?
expect smoke_da_served_owners_uid test "$rc" -ne 0
echo "_linuxfs /p/lklfuse -f -o type=ext4,volname=my data /dev/fd/3 /dev/fd/4" > "$T/rl.ps"
echo "Nov 25 linuxfs-mount[9]: mount_ext4: disk5 on /Volumes/my data: mount_macfuse -o allow_other,nosuid,nodev,local,fsname=/dev/disk5 (pid 9)" > "$T/rl.log"
r=$(rl da_served '/Volumes/my data' owners '5|head' 2>&1); rc=$?
expect smoke_da_served_owners_no_dp test "$rc" -ne 0
# r0 I1: lklfuse_has OPT MP finds root's mount's lklfuse by its record (its command ends in /dev/fd/N, never MP); with no record,
#   the user path's, whose command ends in MP
echo "_linuxfs /p/lklfuse -f -o type=ext4,volicon=/b/linuxfs.icns,uid=99,gid=99 /dev/fd/3 /dev/fd/4" > "$T/rl.ps"; : > "$T/rl.ax"
lh() { (eval "$(smoke_fn root_lklfuse_of)"; eval "$(smoke_fn lklfuses)"; eval "$(smoke_fn lklfuse_on)"; eval "$(smoke_fn lklfuse_serving)"; eval "$(smoke_fn lklfuse_has)"
   LINUXFS_ROOT_STATE=$T/rs tab=$(printf '\t')
   sudo() { test "$1" != -n || shift; "$@"; }
   ps() {
     case "$*" in
     *-axww*) cat "$T/rl.ax" 2> /dev/null ;;
     *"-p 4322"*) return 1 ;;
     *user=*) sed -n 1p "$T/rl.ps" ;;
     *-p*) sed -n 1p "$T/rl.ps" | cut -d ' ' -f 2- ;;
     esac
   }
   lklfuse_has "$@") > /dev/null 2>&1; }
expect smoke_lklfuse_has_root lh volicon=/b/linuxfs.icns '/Volumes/my data'
expect smoke_lklfuse_has_root_not not lh volicon=/c/other.icns '/Volumes/my data'
echo "u 88 /p/lklfuse -f -o type=ext4,volicon=/b/linuxfs.icns /dev/disk9 /Volumes/user vol" > "$T/rl.ax"
expect smoke_lklfuse_has_user lh volicon=/b/linuxfs.icns '/Volumes/user vol'
expect smoke_lklfuse_has_none not lh volicon=/b/linuxfs.icns '/Volumes/nothing'
: > "$T/rl.ax"
expect smoke_lklfuse_has_by_serving test -n "$(smoke_fn lklfuse_has | grep 'lklfuse_serving "$2"')" -a -z "$(smoke_fn lklfuse_has | grep 'lklfuse_on')"
expect smoke_lklfuse_serving_root_first test -n "$(smoke_fn lklfuse_serving | grep 'root_lklfuse_of "$1"')"
expect smoke_no_lklfuse_user_is test -z "$(grep -n 'lklfuse_user_is' "$sm")"
rm -rf "${T:?}/rs"; rm -f "${T:?}/rl.ps" "${T:?}/rl.ax" "${T:?}/rl.log"
# da_root_mount: root's mount_macfuse line must name this disk's fsname
r=$( (eval "$(smoke_fn da_root_mount)"; mounted_by_root() { :; }
  mount() { echo "/dev/disk5 on /Volumes/x (macfuse_ext4, local, nodev, nosuid, synchronous)"; }
  syslog_since() { echo "Nov 25 x[9]: mount_ext4: disk5 on /Volumes/x: mount_macfuse -o allow_other,nosuid,nodev,fsname=/dev/disk9 (pid 9)"; echo "Nov 25 x[9]: mount_ext4: disk5 mounted on /Volumes/x by root, served by _linuxfs"; }
  da_root_mount /Volumes/x /dev/disk5 ext4 '5|head'; echo "rc $?") 2>&1)
expect smoke_da_root_mount_fsname has "$r" "^rc 1$"
# no_owner_pseudo MP POS: system.log since POS has no "id = MP?owner=" (DiskArbitration's entry for a mount it cannot tie to a disk)
nop() { (eval "$(smoke_fn no_owner_pseudo)"; syslog_since() { printf '%s\n' "$nop_l"; }; no_owner_pseudo '/Volumes/my data' '5|head') > /dev/null 2>&1; }
nop_l='Nov 25 diskarbitrationd[8]: created disk, id = /dev/disk5'; expect smoke_no_owner_pseudo nop
nop_l='Nov 25 diskarbitrationd[8]: created disk, id = /Volumes/my data?owner=501'; expect smoke_no_owner_pseudo_seen not nop
nop_l='Nov 25 diskarbitrationd[8]: created disk, id = /Volumes/my data 1?owner=501'; expect smoke_no_owner_pseudo_other_mp nop
# mountd_unshared_peer DEV POS: the daemon's peer line since POS is the console user's, outside macFUSE's admin_group; its result
#   line for DEV is ok; the volume (a fresh image's) has no .fseventsd before the write, and has one within 10 s of it (root's
#   fseventsd let in)
mkdir -p "$T/mup"
mup() { # with $mup_fe: after (fseventsd makes .fseventsd once the write lands), before (it is there already), never
  rm -rf "${T:?}/mup/.fseventsd"; test "$mup_fe" != before || mkdir "$T/mup/.fseventsd"
  if test "$mup_fe" = after; then ( i=0; while ! test -e "$T/mup/da-fsevents" && test $i -lt 50; do i=$((i + 1)); /bin/sleep 0.1; done; mkdir "$T/mup/.fseventsd" ) & fi
  (eval "$(smoke_fn mountd_unshared_peer)"; unset -f sleep; bounded() { bounded_real "$@"; }
  info() { echo "$T/mup"; }; stat() { echo 501; }; sysctl() { echo 80; }; syslog_since() { printf '%s\n' "$mup_l"; }
  mountd_unshared_peer /dev/disk5 '5|head') > "$T/mup.out" 2>&1; mup_rc=$?; wait; return $mup_rc; }
ok_l="Nov 25 dev.mavergreen.linuxfs.mountd[7]: mountd: disk5 on $T/mup: ok (peer 501, DA 12ms)"
mup_fe=after
mup_l="$(printf '%s\n' 'Nov 25 dev.mavergreen.linuxfs.mountd[7]: mountd: peer uid 501 groups 20,12,61' "$ok_l")"; expect smoke_mountd_unshared_peer mup
expect smoke_mountd_unshared_peer_tidy test ! -e "$T/mup/da-fsevents"
mup_l="$(printf '%s\n' 'Nov 25 dev.mavergreen.linuxfs.mountd[7]: mountd: peer uid 501 groups 20,80,12' "$ok_l")"; expect smoke_mountd_unshared_peer_admin not mup
mup_l="$(printf '%s\n' 'Nov 25 dev.mavergreen.linuxfs.mountd[7]: mountd: peer uid 502 groups 20' "$ok_l")"; expect smoke_mountd_unshared_peer_not_console not mup
mup_l="$ok_l"; expect smoke_mountd_unshared_peer_no_peer not mup
mup_l="$(printf '%s\n' 'Nov 25 dev.mavergreen.linuxfs.mountd[7]: mountd: peer uid 501 groups 20' "Nov 25 x[7]: mountd: disk5 on $T/mup: user (peer 501, DA 12ms): busy")"
expect smoke_mountd_unshared_peer_user not mup
mup_l="$(printf '%s\n' 'Nov 25 dev.mavergreen.linuxfs.mountd[7]: mountd: peer uid 501 groups 20' "$ok_l")"
mup_fe=never; expect smoke_mountd_unshared_peer_no_fseventsd not mup
# the ruling on fix round 1's risk 1: the fresh image (made on Linux, never mounted on a Mac) is what makes .fseventsd mean root's
#   fseventsd got in, so one made at mount time, before the write, is ok; what .fseventsd holds is printed (ls -la)
mup_fe=before; expect smoke_mountd_unshared_peer_at_mount mup
expect smoke_mountd_unshared_peer_ls grep -q "^\.fseventsd on $T/mup: .*total" "$T/mup.out"
expect smoke_mountd_unshared_peer_no_absence test -z "$(smoke_fn mountd_unshared_peer | grep 'before the write')"
expect da_cycle_peer_ls_shown test -n "$(printf '%s\n' "$dc" | grep -F 'mountd_unshared_peer "$dev" "$pos"; sed -n '"'"'s/^\.fseventsd on /# .fseventsd on /p'"'"' "$W/step-$n.log"; fi')"
# the check's image is the first ext4 raw cycle's: da-ext4.img, unpacked afresh from IN's ext4.img.gz in the cycles loop
expect mountd_unshared_peer_fresh_image test -n "$(sed -n '/^for c in ext4:ext4:rw /,/^done/p' "$sm" | grep -F 'if gunzip -c "$IN/$fs.img.gz" > "$W/img/da-$fs.img"; then da_cycle "$fs" "$W/img/da-$fs.img" "$pers" "$kind" raw;')"
rm -rf "${T:?}/mup"; rm -f "${T:?}/mup.out"
# r0 I2: each raw cycle's image is unpacked afresh from IN (phase 1 mounted and wrote IN's copy in W/img), never copied from it
expect da_cycle_raw_fresh test -n "$(grep -F 'gunzip -c "$IN/$fs.img.gz" > "$W/img/da-$fs.img"' "$sm")" -a -z "$(grep -F 'cp "$W/img/$fs.img" "$W/img/da-$fs.img"' "$sm")"
# da_cycle: after each of its mounts, root's mount (da_root_mount), served by _linuxfs (da_served) and no ?owner= (no_owner_pseudo);
#   its unmount and eject are the user's own (no sudo); the peer proof once, in the first ext4 cycle (raw)
dc_first=$(printf '%s\n' "$dc" | sed -n '/mounted at $mp within 30 s"/,/da_unmount/p')
dc_again=$(printf '%s\n' "$dc" | sed -n '/mounted again at $mp"/,/da_eject/p')
for c in 'da_root_mount "$mp" "$dev" "$nm" "$pos"' 'da_served "$mp"' 'no_owner_pseudo "$mp" "$pos"'; do
  expect "da_cycle_first_${c%% *}" test "$(printf '%s\n' "$dc_first" | grep -cF "bounded 300 $c")" -eq 1
  expect "da_cycle_again_${c%% *}" test "$(printf '%s\n' "$dc_again" | grep -cF "bounded 300 $c")" -eq 1
done
expect da_cycle_user_unmount test -z "$(printf '%s\n' "$dc" | grep 'da_unmount\|da_eject' | sed "s/(the user's, no sudo)//" | grep sudo)$(smoke_fn da_unmount | grep sudo)$(smoke_fn da_eject | grep 'diskutil eject' | grep sudo)"
expect da_cycle_peer_once test "$(grep -c 'mountd_unshared_peer "' "$sm")" -eq 1
expect da_cycle_peer_ext4_raw test -n "$(printf '%s\n' "$dc_first" | grep 'mountd_unshared_peer "$dev" "$pos"' | grep -F '"$nm.$via" = ext4.raw')"
expect da_eject_root_first test -n "$(smoke_fn da_eject | grep 'root_lklfuse_of "$2"')" -a -n "$(smoke_fn da_eject | grep 'lklfuse_on "$2"')"
expect smoke_owners_served test -n "$(smoke_fn owners_case | grep 'da_served "$mp" owners "$pos"')"
# after the census, the one new step (code line) is before login's "the mount daemon was not asked": named, read once from loglog,
#   bounded
after=$(awk 'p && !/^ *#/ { print } /^ *parity_census_all$/ { p = 1 }' "$sm")
expect smoke_after_census_one_mountd test "$(printf '%s\n' "$after" | grep -c 'mountd\|mount daemon')" -eq 1
expect smoke_before_login_not_asked test -n "$(printf '%s\n' "$after" | grep '^ *check "before login: the mount daemon was not asked" bounded 100 mountd_not_asked "$loglp"$')"
expect smoke_before_login_loglp test -n "$(printf '%s\n' "$after" | grep 'loglog=.*loglp=$(log_pos)')"
expect smoke_before_login_not_asked_in_section ascending "$bl" "$(first_line 'check "before login: the mount daemon was not asked"')" "$(first_line '^  restore_login$')"

# ---- Task 16l fix round 1 ----
# r0 I3: when the user's diskutil unmount or eject of root's mount fails twice and the volume is still root's, with nothing saying
#   busy (diskutil's busy or dissent, or a holder in lsof), retry_busy prints the fixed STOP-AND-ASK: marker (risk 1); never for a
#   busy volume, a user mount, or a retry that worked
sa() { # FAILS MSG LSOF MOUNTLINE CMD...: the smoke's retry_busy, diskutil failing FAILS times saying MSG, lsof saying LSOF
  : > "$T/sa.calls"; echo "$1" > "$T/sa.left"; sa_msg=$2 sa_lsof=$3 sa_mount=$4; shift 4
  (eval "$(smoke_fn info)"; eval "$(smoke_fn holders)"; eval "$(smoke_fn retry_busy)"; eval "$(smoke_fn da_unmount)"; eval "$(smoke_fn mounted_by_root)"
   eval "$(smoke_fn stop_and_ask)"
   bounded() { shift; "$@"; }; sleep() { :; }
   diskutil() {
     echo "diskutil $*" >> "$T/sa.calls"
     case $1 in info) return 0 ;; esac
     k=$(cat "$T/sa.left"); test "$k" -gt 0 || return 0; echo $((k - 1)) > "$T/sa.left"; echo "$sa_msg"; return 1
   }
   sudo() { echo "sudo $*" >> "$T/sa.calls"; case $* in *lsof*) test -z "$sa_lsof" || printf '%s\n' "COMMAND PID USER" "$sa_lsof" ;; esac; }
   mount() { echo "$sa_mount"; }
   "$@") 2>&1
}
rootl="/dev/disk9 on /Volumes/x (macfuse_ext4, local, nodev, nosuid, synchronous)"
userl="/dev/disk9 on /Volumes/x (macfuse_ext4, local, nodev, nosuid, synchronous, mounted by u)"
r=$(sa 2 "Unmount failed for /Volumes/x" "" "$rootl" da_unmount /Volumes/x)
expect smoke_stop_and_ask_unmount has "$r" "^STOP-AND-ASK: the user's diskutil unmount /Volumes/x of root's mount at /Volumes/x was refused"
expect smoke_stop_and_ask_once test "$(printf '%s\n' "$r" | grep -c 'STOP-AND-ASK:')" -eq 1
expect smoke_stop_and_ask_says_output has "$r" "^STOP-AND-ASK: .*: Unmount failed for /Volumes/x$"
r=$(sa 2 "Volume failed to eject" "" "$rootl" retry_busy /Volumes/x /dev/disk9 diskutil eject /dev/disk9)
expect smoke_stop_and_ask_eject has "$r" "^STOP-AND-ASK: the user's diskutil eject /dev/disk9 of root's mount at /Volumes/x was refused"
r=$(sa 2 "Volume x on disk9 failed to unmount: dissented by PID 77" "" "$rootl" da_unmount /Volumes/x)
expect smoke_stop_and_ask_not_dissent test -z "$(printf '%s\n' "$r" | grep 'STOP-AND-ASK')"
r=$(sa 2 "Unmount failed: Resource busy" "" "$rootl" da_unmount /Volumes/x)
expect smoke_stop_and_ask_not_busy test -z "$(printf '%s\n' "$r" | grep 'STOP-AND-ASK')"
r=$(sa 2 "Unmount failed for /Volumes/x" "mdworker 77 root cwd DIR /Volumes/x" "$rootl" da_unmount /Volumes/x)
expect smoke_stop_and_ask_not_held test -z "$(printf '%s\n' "$r" | grep 'STOP-AND-ASK')"
r=$(sa 2 "Unmount failed for /Volumes/x" "" "$userl" da_unmount /Volumes/x)
expect smoke_stop_and_ask_not_user_mount test -z "$(printf '%s\n' "$r" | grep 'STOP-AND-ASK')"
r=$(sa 2 "Unmount failed for /Volumes/x" "" "" da_unmount /Volumes/x)
expect smoke_stop_and_ask_not_unmounted test -z "$(printf '%s\n' "$r" | grep 'STOP-AND-ASK')"
r=$(sa 1 "Unmount failed for /Volumes/x" "" "$rootl" da_unmount /Volumes/x)
expect smoke_stop_and_ask_not_retried test -z "$(printf '%s\n' "$r" | grep 'STOP-AND-ASK')"
rm -f "${T:?}/sa.calls" "${T:?}/sa.left"
expect smoke_stop_and_ask_in_retry test -n "$(smoke_fn retry_busy | grep 'stop_and_ask ')"
# r0 I3: da_cycle's eject is two checks: the user's eject (no sudo), then, only when it worked, that it leaves no lklfuse
expect da_cycle_eject_split test -n "$(printf '%s\n' "$dc" | grep '^ *if check "$tag: diskutil eject (the user'"'"'s, no sudo)" da_eject "$disk" "$mp"; then')" \
  -a -n "$(printf '%s\n' "$dc" | grep 'check "$tag: the eject leaves no lklfuse" da_lklfuse_gone "$mp"')"
expect da_eject_no_wait test -z "$(smoke_fn da_eject | grep 'while\|ps -p')"
# r0 M1: da_lklfuse_gone waits on da_eject's pids; with none found for a volume that was mounted (no record read, e.g. sudo
#   refused), not ok, said, instead of passing at once
lg() { (eval "$(smoke_fn lklfuses)"; eval "$(smoke_fn lklfuse_on)"; eval "$(smoke_fn da_lklfuse_gone)"; eval "$(smoke_fn pid_gone)"; unset -f sleep; bounded() { bounded_real "$@"; }
  ps() { case "$*" in *-axww*) : ;; *) return 1 ;; esac; }; sleep() { :; }
  ej_pids=$1 ej_was=$2; da_lklfuse_gone /Volumes/x) 2>&1; }
r=$(lg "" "/dev/disk9 on /Volumes/x (macfuse_ext4)"); rc=$?
expect smoke_lklfuse_gone_no_pids test "$rc" -ne 0
expect smoke_lklfuse_gone_no_pids_said has "$r" "^no lklfuse to wait on"
r=$(lg "" ""); rc=$?
expect smoke_lklfuse_gone_unmounted test "$rc" -eq 0
r=$(lg 4321 "/dev/disk9 on /Volumes/x (macfuse_ext4)"); rc=$?
expect smoke_lklfuse_gone_pid_gone test "$rc" -eq 0
# the ruling on r0's concern 1: in da_cycle (never the census's pairs), after each mount, diskutil info MP names DEV's node:
#   DiskArbitration ties the mount point to the disk (bounded)
din() { (eval "$(smoke_fn da_info_node)"; info() { test "$1" = /Volumes/x && test "$2" = "Device Node" && echo "$din_n"; }; da_info_node /Volumes/x "$1") > /dev/null 2>&1; }
din_n=/dev/disk5s1; expect smoke_da_info_node din /dev/disk5s1
expect smoke_da_info_node_bare din disk5s1
expect smoke_da_info_node_other not din /dev/disk5
din_n=; expect smoke_da_info_node_none not din /dev/disk5s1
dc_first=$(printf '%s\n' "$dc" | sed -n '/mounted at $mp within 30 s"/,/da_unmount/p')
dc_again=$(printf '%s\n' "$dc" | sed -n '/mounted again at $mp"/,/da_eject/p')
expect da_cycle_first_info_node test "$(printf '%s\n' "$dc_first" | grep -cF 'bounded 300 da_info_node "$mp" "$dev"')" -eq 1
expect da_cycle_again_info_node test "$(printf '%s\n' "$dc_again" | grep -cF 'bounded 300 da_info_node "$mp" "$dev"')" -eq 1
expect census_no_info_node test -z "$(grep -n 'da_info_node' "$here/lib/parity.sh")"
# r0 I1's audit: da_cycle looks up no lklfuse by its mount point but through root's records (lklfuse_serving, da_served)
expect da_cycle_no_lklfuse_on test -z "$(printf '%s\n' "$dc" | grep 'lklfuse_on')"
# r0 M3: no fallback to record contradicts PARITY_MODE_FSEVENTS_DA's default; and Task 16l's flip is told as done
expect fsevents_da_no_record_fallback test -z "$(grep -n 'PARITY_MODE_FSEVENTS_DA:-record' "$here/lib/parity.sh")"
expect fsevents_da_no_future test -z "$(grep -n 'Task 16l flips them back' "$here/lib/parity.sh")"
# r0 M5: before login, the daemon's own lines (its ident, linuxfs-mountd) or a mount program's about it, read through any
#   turnover (syslog_since from log_pos's); automountd's are not the daemon's
mna() { (eval "$(smoke_fn mountd_not_asked)"; eval "$(smoke_fn log_since)"; syslog_since() { printf '%s\n' "$mna_l"; }; mountd_not_asked '5|head') > /dev/null 2>&1; }
mna_l='Nov 25 automountd[51]: automountd: no mounts'; expect smoke_mountd_not_asked mna
mna_l='Nov 25 linuxfs-mountd[9]: mountd: refused uid 0: not the console user'; expect smoke_mountd_not_asked_daemon not mna
mna_l='Nov 25 linuxfs-mount[9]: mount_ext4: disk5 on /Volumes/x: the mount daemon said no (3: busy)'; expect smoke_mountd_not_asked_program not mna
expect smoke_mountd_not_asked_since test -n "$(smoke_fn mountd_not_asked | grep 'log_since "$1"')" -a -z "$(smoke_fn mountd_not_asked | grep 'tail -n')"

test "$fails" -eq 0
