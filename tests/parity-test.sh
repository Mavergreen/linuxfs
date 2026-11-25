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
export PARITY_FSTAB PARITY_DALOG PARITY_SYSLOG STUB
: > "$PARITY_FSTAB"; : > "$PARITY_DALOG"; : > "$PARITY_DAPL"; : > "$S/calls"; : > "$PARITY_SYSLOG"; echo icns > "$PARITY_ICNS"
for py in python3 /usr/bin/python; do command -v "$py" > /dev/null 2>&1 && PARITY_PYTHON=$py; done
cat > "$T/bin/stub" <<'EOF'
#!/bin/sh
# census_dry's stub of the Mac's disk tools: a node file per attached disk node (img, vol, mp, uuid, disk), .m when mounted
me=${0##*/}
# ps -ax: the host's processes, less any lklfuse (or a "not ok" in some other run's command line), and one fixed
#   lklfuse line; the rest (ps -p) as it is
if test "$me" = ps; then
  case "$*" in
  *-ax*) /bin/ps "$@" | grep -v 'lklfuse\|not ok'; echo "stubuser 4242 1 Mon Nov 25 10:00:00 2026 /stub/lklfuse -f stub-lklfuse-line" ;;
  *) exec /bin/ps "$@" ;;
  esac
  exit 0
fi
printf '%s\n' "$me $*" | tee -a "$STUB/calls.all" >> "$STUB/calls"
N=$STUB/nodes
field() { sed -n "s/^$2=//p" "$N/$1" 2> /dev/null; }
node_of() { # a disk node, or a mount point: its node
  for f in "$N"/*; do
    case $f in *.m) continue ;; esac
    test -f "$f" || continue
    nd=${f##*/}
    if test "$nd" = "${1#/dev/}"; then echo "$nd"; return; fi
    if test -f "$f.m" && test "$(field "$nd" mp)" = "$1"; then echo "$nd"; return; fi
  done
}
log() { echo "$(date +%H:%M:%S)   $*" >> "$PARITY_DALOG"; }
case $me in
hdiutil)
  case $1 in
  attach)
    nomount= verbose= img=
    for a; do case $a in -nomount) nomount=1 ;; -verbose) verbose=1 ;; *.img) img=$a ;; esac; done
    b=${img##*/}; b=${b%.img}
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
    # a linuxfs volume draws a refusal from root's fseventsd (pid 1 stands in), naming its mount point
    test "$nd" != "$d" || echo "Nov 25 10:00:00 stubhost fseventsd[1]: could not open $mp/.fseventsd (Operation not permitted)" >> "$PARITY_SYSLOG"
    printf 'img=%s\nvol=%s\nmp=%s\nuuid=UUID-%s\ndisk=%s\n' "$img" "$b" "$mp" "$b" "$d" > "$N/$nd"
    log "created disk, id = /dev/$d."
    log "probed disk, id = /dev/$nd, with stub, success."
    case $b in *nouuid*) sed -i.x '/^uuid=/d' "$N/$nd"; rm -f "$N/$nd.x" ;; esac
    # flaky (a linuxfs image): only its first attach mounts; after its first eject, ejects and detaches fail
    case $b in *hfs*) ;; *flaky*) if test -f "$STUB/flaky-attached"; then b=nevermount-$b; else : > "$STUB/flaky-attached"; fi ;; esac
    case $b in *names*) test ! -f "$STUB/names-nomount" || b=nevermount-$b ;; *hfs*) ;; *nomnt*) b=nevermount-$b ;; esac
    case $b:$nomount in *nevermount*:) echo "/dev/$nd          	Stub" ;; *swept*:1 | *:) : > "$N/$nd.m"; echo "/dev/$nd          	Stub	$mp" ;;
    *) echo "/dev/$nd          	Stub" ;; esac ;;
  detach)
    for a; do case $a in disk*|/dev/disk*) d=${a#/dev/}; case $(field "$d" vol) in *hfs*) ;; *flaky*) test ! -f "$STUB/flaky-ejected" || exit 1 ;; esac; rm -f "$N/$d" "$N/$d.m" "$N/${d}s1" "$N/${d}s1.m" ;; esac; done ;;
  info)
    test ! -f "$STUB/info-fail" || { echo "hdiutil: info failed - stub"; exit 1; }
    echo "framework       : stub"; echo "driver          : stub"
    for f in "$N"/*; do case $f in *.m) continue ;; esac; test -f "$f" || continue
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
    if test -f "$N/$nd.m"; then echo "   Mounted:                  Yes"; echo "   Mount Point:              $(field "$nd" mp)"
    else echo "   Mounted:                  No"; fi
    test -z "$(field "$nd" uuid)" || echo "   Volume UUID:              $(field "$nd" uuid)"
    printf '%s\n' "   Protocol:                 Disk Image" "   Read-Only Media:          No" "   Ejectable:                Yes" "   Internal:                 No" ;;
  mount)
    nd=$(node_of "$2"); test -n "$nd" || exit 1; : > "$N/$nd.m"; echo "Volume $(field "$nd" vol) on $nd mounted" ;;
  unmount)
    t=$2; test "$t" != force || t=$3
    nd=$(node_of "$t"); test -n "$nd" || { echo "Unmount failed for $t"; exit 1; }
    case $(field "$nd" vol) in *busy-ext4*)
      if test ! -f "$STUB/busy-once"; then : > "$STUB/busy-once"; echo "Unmount failed for $t"; exit 1; fi ;;
    esac
    rm -f "$N/$nd.m"; echo "Volume $(field "$nd" vol) on $nd unmounted" ;;
  eject)
    d=${2#/dev/}
    case $(field "$d" vol) in *stuck*) echo "Disk $d couldn't be ejected (stub stuck)"; exit 1 ;; esac
    case $(field "$d" vol) in *hfs*) ;; *flaky*)
      if test -f "$STUB/flaky-ejected"; then echo "Disk $d couldn't be ejected (stub flaky)"; exit 1; fi; : > "$STUB/flaky-ejected" ;;
    esac
    case $(field "$d" vol) in busy-ext4)
      if test ! -f "$STUB/eject-once"; then : > "$STUB/eject-once"; echo "Disk $d couldn't be ejected (stub busy)"; exit 1; fi ;;
    esac
    rm -f "$N/$d" "$N/$d.m" "$N/${d}s1" "$N/${d}s1.m"; echo "Disk $d ejected" ;;
  esac ;;
linuxfs)
  case $1 in
  ignore) d=${2#/dev/}; echo "UUID=$(field "$d" uuid) none macfuse_ext4 rw,noauto # linuxfs" >> "$PARITY_FSTAB" ;;
  unignore) d=${2#/dev/}; grep -v "^UUID=$(field "$d" uuid) " "$PARITY_FSTAB" > "$PARITY_FSTAB.t"; cat "$PARITY_FSTAB.t" > "$PARITY_FSTAB"; rm -f "$PARITY_FSTAB.t" ;;
  esac ;;
sudo)
  test "$1" != -n || shift
  case $1 in sh|tail|cat|wc|mdutil|tmutil) exec "$@" ;; lsof) echo "COMMAND PID USER (stub lsof $*)" ;; esac ;;
mkfile) : > "$2" ;;
sysctl) echo "$1.version.number: stub" ;;
mdutil) eval "echo \"\${$#}:\""; if test "$1" = -s; then echo "	Indexing enabled."; else echo "	Indexing disabled."; fi ;;
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
  case $1 in -l) echo "com.apple.FinderInfo: stub" ;; -px) echo "00 00 04 00" ;; esac ;;
guest-macosx-aqua)
  case $1 in
  screencapture) : > "$3" ;;
  defaults) test "$2" != read || exit 1 ;;
  osascript)
    case "$*" in
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
for c in hdiutil diskutil osascript sudo sysctl mkfile linuxfs mdutil mdfind tmutil defaults xattr df ps; do ln -sf stub "$T/bin/$c"; done
rm -f "$T/aqua/guest-macosx-aqua"; ln -sf ../bin/stub "$T/aqua/guest-macosx-aqua"
expect census_aqua_off_path not command -v guest-macosx-aqua
L=$T/bin/linuxfs; IN=$T/in
rm -rf "$W/ctl" "$OUT/parity"; mkdir -p "$W/img"
for f in ext4 btrfs xfs ntfs apfs; do echo "$f image" > "$W/img/$f.img"; done
echo names | gzip -c > "$IN/ext4-names.img.gz"
unbounded=$T/unbounded; : > "$unbounded"
PARITY_XATTR_SIZES="131072 131073 262144"; PARITY_FREE_FLOOR_KB=1 PARITY_START_FLOOR_KB=1

# census_xattr_sizes: by default the probe climbs past 10.9's XATTR_MAXSIZE-free HFS+ to a size no 128 MiB control holds
r=$(unset PARITY_XATTR_SIZES; . "$here/lib/parity.sh"; echo "$PARITY_XATTR_SIZES")
expect census_xattr_sizes_default test "$r" = "131072 131073 262144 1048576 4194304 16777216 67108864 67108865 134217728"
# census_py_xattr: the sizes in order, stopping at the first refusal, which is said
r=$("$PARITY_PYTHON" -c "$census_py_xattr" "$T/no-such-file" 131072 262144 2>&1)
expect census_py_xattr_stops test "$(printf '%s\n' "$r" | sed 's/errno 2 .*/errno 2/')" = "$(printf '%s\n' '131072 bytes: errno 2' 'stopped at the first refusal')" -o "$r" = "$(printf '%s\n' '131072 bytes: no setxattr in this Python' '262144 bytes: no setxattr in this Python')"
# each size is written on its own space: the attribute is removed before each write (a fake xattr module logs the calls),
#   and a refusal (ENOSPC here) stops the climb
mkdir -p "$T/pyx"; : > "$T/pyx.log"; : > "$T/pyx-file"
cat > "$T/pyx/xattr.py" <<'EOF'
import errno, os
def _log(s):
    f = open(os.environ["PYX_LOG"], "a"); f.write(s + "\n"); f.close()
def setxattr(p, n, v, options=0):
    _log("set %d" % len(v))
    if len(v) >= 3: raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
def removexattr(p, n, options=0):
    _log("remove")
    raise KeyError(n)   # as 10.9's module does when there is none
EOF
r=$(PYX_LOG=$T/pyx.log PYTHONPATH=$T/pyx "$PARITY_PYTHON" -c "$census_py_xattr" "$T/pyx-file" 1 2 3 4 2>&1)
expect census_py_xattr_each_alone test "$(tr '\n' ' ' < "$T/pyx.log")" = "remove set 1 remove set 2 remove set 3 remove "
expect census_py_xattr_enospc_stops test "$(printf '%s\n' "$r" | sed 's/ (.*//')" = "$(printf '%s\n' '1 bytes: ok' '2 bytes: ok' '3 bytes: errno 28' 'stopped at the first refusal')"
rm -rf "$T/pyx" "$T/pyx.log" "$T/pyx-file"

# census_py_create: a name that cannot be made says its errno, and the next name is still tried
mkdir -p "$T/uc"; : > "$T/uc/file"
r=$("$PARITY_PYTHON" -c "$census_py_create" "$T/uc" 66696c652f78 79 2>&1)
expect census_py_create_goes_on test "$(printf '%s\n' "$r" | sed 's/errno [0-9]*$/errno N/')" = "$(printf '%s\n' '66696c652f78 errno N' '79 created')"
rm -rf "$T/uc"
bounded() { ( PARITY_TEST_BOUNDED=1; shift; "$@" ); }
sleep() { test -n "${PARITY_TEST_BOUNDED:-}" || { echo "sleep $* outside bounded" >> "$unbounded"; return 1; }; }
attached() { ls "$S/nodes" | grep -v '\.m$' | tr '\n' ' '; }

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
for f in "$S"/nodes/*; do case $f in *.m) ;; *) test -f "$f" || continue; case $(sed -n 's/^vol=//p' "$f") in da-ext4) rm -f "$f" "$f.m" ;; esac ;; esac; done

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
# past the deadline, no further iteration begins, and the counts say how many ran
r=$(CA_T0=$(($(date +%s) - 120)); PARITY_CENSUS_MIN=1; PARITY_STALL_N=2; census_stall 2>&1)
expect census_stall_cut grep -q '^hfs loop 1: 0 stalls, 0 automounts, 0 setup failures of 0 (stopped early, out of time: 2 asked)$' "$P/stall-summary.txt"
expect census_stall_cut_said grep -q '^# census: out of time (1 min), skipped: stall hfs loop 1 from iteration 1 of 2$' "$P/stall-summary.txt"
expect census_stall_cut_none test "$(grep -c '^[a-z0-9]*-loop' "$P/stall.txt")" -eq 0
expect census_stall_cut_recorded has "$r" "^# recorded stall loop 1: hfs 0/0, ext4 0/0"
expect census_stall_cut_stdout has "$r" "^# census: out of time (1 min), skipped: stall hfs loop 1 from iteration 1 of 2"
expect census_stall_cut_detached test -z "$(attached)"

# census_busy: 20 write-then-unmount cycles per volume (a busy one says who held it), the held-file cases through parity,
#   and the forced ones on the HFS+ side only
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
for s in force-unmount force-eject; do
  expect "census_busy_${s}_hfs_only" test -s "$P/busy.ext4.$s.hfs.txt" -a ! -e "$P/busy.ext4.$s.ext4.txt"
done
expect census_busy_textedit grep -q 'open -a TextEdit' "$S/calls"
expect census_busy_finder grep -q 'eject disk' "$S/calls"
expect census_busy_shot test "$(grep -c 'screencapture -x .*-busy-eject.png' "$S/calls")" -eq 2
expect census_busy_force_hfs grep -q '^diskutil unmount force .*/vols/busy-hfs-ext4$' "$S/calls"
expect census_busy_no_force_fs not grep -q '^diskutil unmount force .*/vols/busy-ext4$' "$S/calls"
expect census_busy_eject_retried grep -q '^# census: retrying diskutil eject /dev/disk' "$P/busy.ext4.cycles.txt"
expect census_busy_eject_lsof grep -q '^#   COMMAND PID USER (stub lsof lsof .*/vols/busy-ext4)' "$P/busy.ext4.cycles.txt"
expect census_busy_recorded has "$r" "^# recorded busy.ext4.cycles: hfs 0 of 20, ext4 1 of 20"
expect census_busy_quiet hasnt "$r" "not ok"
expect census_busy_sysctl test -s "$P/busy-ext4.sysctl.txt"
expect census_busy_detached test -z "$(attached)"
# census_finder_ask dismisses the console's alerts before osascript starts, never between it and its shot (osascript
#   runs in the background, so its line and the shot's come in either order: a dismissal finds both or neither)
ask_dismissed_first() { awk '/killall UserNotificationCenter$/ { if (o != s) bad = 1; o = 0; s = 0; d = 1; next } /osascript .*eject disk/ { if (!d || o) bad = 1; o = 1; d = 0 } /screencapture -x .*busy-eject.png$/ { if (s) bad = 1; s = 1 } END { exit bad || o != s }' "$S/calls"; }
expect census_busy_finder_dismissed_first ask_dismissed_first
expect census_busy_eject_failed_record grep -q '^#   COMMAND PID USER (stub lsof lsof .*/vols/busy-ext4)' "$P/eject-failed.txt"
# a linuxfs disk whose eject fails is recorded (lsof on its device, the lklfuse processes) and left attached, not
#   forced; the busy steps go on, each with a fresh copy
echo stuck6 > "$W/img/stuck6.img"; : > "$P/eject-failed.txt"
r=$(census_busy stuck6 2>&1)
for s in shell-unmount shell-eject textedit-unmount textedit-eject finder-eject; do
  expect "census_busy_stuck_$s" test -s "$P/busy.stuck6.$s.hfs.txt" -a -s "$P/busy.stuck6.$s.stuck6.txt"
done
for s in force-unmount force-eject; do expect "census_busy_stuck_$s" test -s "$P/busy.stuck6.$s.hfs.txt"; done
expect census_busy_stuck_lsof_dev grep -q '^#   COMMAND PID USER (stub lsof lsof /dev/disk[0-9]* /dev/rdisk[0-9]*)$' "$P/eject-failed.txt"
expect census_busy_stuck_lklfuse grep -q '^# census: lklfuse processes' "$P/eject-failed.txt"
expect census_busy_stuck_ps_stub grep -q '^#   stubuser 4242 1 .*stub-lklfuse-line$' "$P/eject-failed.txt"
expect census_busy_stuck_fresh has "$r" "^# census_busy stuck6: .* left attached; the steps go on with a fresh copy"
expect census_busy_stuck_quiet hasnt "$r" "not ok"
expect census_busy_stuck_df grep -q '^# census: df -k .*: [0-9]* KiB free, floor 1 KiB and [0-9]* KiB to copy' "$P/eject-failed.txt"
expect census_busy_stuck_lklfuse_count grep -q '^# census: lklfuse processes now: [0-9]*$' "$P/eject-failed.txt"
stuck_disks() { for f in "$S"/nodes/*; do case $f in *.m) ;; *) test -f "$f" || continue; case $(sed -n 's/^vol=//p' "$f") in *$1*) sed -n 's/^disk=//p' "$f" ;; esac ;; esac; done; }
drop_stuck() { for f in "$S"/nodes/*; do case $f in *.m) ;; *) test -f "$f" || continue; case $(sed -n 's/^vol=//p' "$f") in *$1*) rm -f "$f" "$f.m" ;; esac ;; esac; done; }
sd=$(stuck_disks stuck6); nf=
for d in $sd; do grep -qx "$d" "$S/fsdisks" || nf="$nf $d"; done
expect census_busy_stuck_count test "$(printf '%s\n' $sd | grep -c .)" -eq 7
expect census_busy_stuck_in_fsdisks test -n "$sd" -a -z "$nf"
drop_stuck stuck6
rm -f "$W/img/stuck6.img"
# below the free-space floor no fresh copy is made: said, recorded, and the busy steps stop for that filesystem
echo stuck7 > "$W/img/stuck7.img"; : > "$P/eject-failed.txt"
r=$(PARITY_FREE_FLOOR_KB=999999999999; census_busy stuck7 2>&1)
expect census_busy_floor_said has "$r" "^# census_busy stuck7: .* KiB free on .*, under the floor .*: no fresh copy, so the busy steps stop"
expect census_busy_floor_recorded grep -q 'under the floor' "$P/eject-failed.txt"
expect census_busy_floor_stops test ! -e "$P/busy.stuck7.shell-eject.stuck7.txt"
expect census_busy_floor_no_copy test ! -e "$W/census/busy-stuck7-2.img"
expect census_busy_floor_quiet hasnt "$r" "not ok"
drop_stuck stuck7
rm -f "$W/img/stuck7.img"

# census_spotlight: read-write, then read-only (HFS+ attach -readonly against ext4 with ReadOnly on)
: > "$S/calls"
r=$(census_spotlight ext4 2>&1)
for p in rw ro; do
  for s in mdutil mdfind dirs refusals privacy-off privacy-remount; do
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
expect census_spotlight_dirs grep -q '^.fseventsd: no$' "$P/spotlight.ext4.rw.dirs.ext4.txt"
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
expect census_spotlight_quiet hasnt "$r" "not ok"
expect census_spotlight_detached test -z "$(attached)"

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
expect census_finder_props grep -q '^capacity equals df -k' "$P/finder.ext4.properties.ext4.txt"
expect census_finder_props_ejectable grep -q '^ejectable: true$' "$P/finder.ext4.properties.hfs.txt"
expect census_finder_raw grep -q 'Mac OS Extended format' "$P/finder.ext4.raw.txt"
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
for f in "$S"/nodes/*; do case $f in *.m) ;; *) test "$(sed -n 's/^vol=//p' "$f")" != trash-stuck4 || rm -f "$f" "$f.m" ;; esac; done
rm -f "$W/img/stuck4.img"
# the oversized probe is bounded at 1 min a side (2 min for the step), so a trash/tags/case census stays in its envelope
r=$(census_xattr_big() { echo "${PARITY_BOUND:-unset}" > "$T/xb-bound"; }; census_trash_tags_case btrfs 2>&1)
expect census_ttc_oversized_bound test "$(cat "$T/xb-bound" 2>/dev/null)" = 600
r=$(census_trash_tags_case apfs 2>&1)
expect census_ttc_apfs_case test -s "$P/case.apfs.pathconf.apfs.txt" -a -s "$P/case.apfs.pathconf-hfsx.apfs.txt"
expect census_ttc_apfs_case_only test -z "$(ls "$P" | grep -E '^(trash|tags)\.apfs\.')"
expect census_ttc_apfs_detached test -z "$(attached)"

# census_later: Time Machine, the exFAT control against ext4 (each beside HFS+)
: > "$S/calls"
r=$(census_later 2>&1)
# tmutil isexcluded with no destination says [Excluded] for every volume: not asked, and said so
expect census_later_no_isexcluded not grep -q '^tmutil isexcluded' "$S/calls"
expect census_later_tm_note grep -q 'uninformative' "$P/later.tm-excluded.txt"
# alerts are dismissed before each attach, and never between an attach and its tm-offer shot (the offer comes after)
tm_dismissed() { awk '/killall UserNotificationCenter$/ { if (a) bad = 1; d = 1; next } /^hdiutil attach -imagekey / { if (!d) bad = 1; a = 1; d = 0 } /tm-offer.png$/ { a = 0 } END { exit bad }' "$S/calls"; }
expect census_later_dismissed_before_attach tm_dismissed
expect census_later_no_destination not grep -Eq 'tmutil (setdestination|removedestination)' "$S/calls"
expect census_later_shots test "$(grep -Ec 'screencapture -x .*/(hfs|exfat|ext4)-tm-offer.png$' "$S/calls")" -eq 3
expect census_later_quiet hasnt "$r" "not ok"
expect census_later_detached test -z "$(attached)"

# census_before_login: mdutil -s and .fseventsd only
mkdir -p "$T/bl/.fseventsd"
r=$(census_before_login "$T/bl" 2>&1)
expect census_before_login_mdutil grep -q '^<MP>:$' "$P/spotlight.before-login.txt"
expect census_before_login_fseventsd grep -q '^.fseventsd: yes$' "$P/spotlight.before-login.txt"
expect census_before_login_recorded has "$r" "^# recorded spotlight.before-login"

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
expect census_all_missing has "$r" "^# census: no .*/img/f2fs.img, so no census_finder f2fs"
expect census_all_controls test -f "$W/ctl/hfs.img" -a -f "$W/ctl/hfsx.img" -a -f "$W/ctl/fat32.img" -a -f "$W/ctl/exfat.img"
expect census_all_takeover_off test ! -f "$S/takeover"
expect census_all_left grep -q "^/dev/$left .*/census/left-stuck.img\$" "$P/census-left-attached.txt"
expect census_all_left_said has "$r" "^# census: left attached .*left-stuck.img"
expect census_all_cleans test ! -e "$W/census/old.img" -a -e "$W/census/left-stuck.img"
# a step begins only when, at its worst (the console hung: every AppleScript at its bound), it ends by
#   PARITY_CENSUS_MIN + 11; a step whose worst is 11 or less keeps the plain cutoff
expect census_worst_table test "$(for c in census_unicode census_busy census_spotlight census_finder census_trash_tags_case census_later census_stall stall; do census_worst_min "$c"; done | tr '\n' ' ')" = '13 17 24 24 13 5 11 11 '
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=20; census_due census_finder ext4 2>&1); rc=$?
expect census_due_worst_skips test "$rc" -ne 0
expect census_due_worst_said has "$r" "^# census: census_finder may take 24 min, past the census's end (31 min), skipped: census_finder ext4$"
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=24; census_due census_finder ext4 2>&1)
expect census_due_worst_fits test -z "$r"
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=11; census_due census_stall 2>&1)
expect census_due_plain_cutoff test -z "$r"
r=$(CA_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=10; census_due census_stall 2>&1)
expect census_due_plain_cutoff_said has "$r" "^# census: out of time (10 min), skipped: census_stall$"
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
# the deadline counts from the smoke's start, PARITY_T0
: > "$ran"
r=$(PARITY_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=9; census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; parity_census_all 2>&1)
expect census_all_from_smoke_start test ! -s "$ran"
r=$(PARITY_T0=$(($(date +%s) - 600)); PARITY_CENSUS_MIN=11; census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; parity_census_all 2>&1)
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
# push B's census runs without item 3's loop (it waits for push C)
expect smoke_stall_off ascending "$(first_line '^ *PARITY_STALL_N=0$')" "$(first_line '^ *parity_census_all$')"

# item 2 in the smoke: the six names exactly, never the macfuse_ prefix as a family, and no bundle under its old linuxfs name left
# smoke_fn NAME: the smoke's definition of the function NAME (one line, or up to its closing brace)
smoke_fn() { awk -v n="$1() " 'index($0, n) == 1 { p = 1; print; if ($0 !~ /[{] *(#.*)?$/) exit; next } p { print } p && /^}/ { exit }' "$sm"; }
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
printf '%s\n' 'linuxfs@disk4s1 on /Volumes/my data (macfuse_ext4, local, nodev, nosuid, synchronous, mounted by u)' \
  'linuxfs@disk5 on /Volumes/x (macfuse, local, nodev)' 'linuxfs@disk6 on /Volumes/y (macfuse_ext4x, local)' > "$T/mounts"
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

# no forced unmount, eject or detach ever targets a linuxfs disk (QEMU first)
forced=
for d in $(sort -u "$S/fsdisks"); do
  grep -Eq "^(hdiutil detach -force|diskutil unmountDisk force|diskutil unmount force) (/dev/)?$d(s1)?\$" "$S/calls.all" && forced="$forced $d"
done
expect census_no_force_on_fs test -z "$forced" -a -s "$S/fsdisks"
# a disk that never mounted may be detached by force when its eject fails; a mounted linuxfs disk never is:
#   census_attach's "not mounted within 60 s", a stalled plain attach in fl_iter, and fl_iter's no-UUID path (swept or not)
forced_on() { grep -q "^hdiutil detach -force $1\$" "$S/calls.all"; }
for c in nevermount-stuck-a nevermount-stuck-b nouuid-stuck nouuid-swept-stuck; do echo "$c" > "$W/census/$c.img"; done
census_attach "$W/census/nevermount-stuck-a.img" > /dev/null 2>&1; d=$(cat "$S/disks")
expect never_mounted_attach_forced forced_on "/dev/disk$d"
fl_iter ext4 2 1 "$W/census/nevermount-stuck-b.img" > /dev/null 2>&1; d=$(cat "$S/disks")
expect never_mounted_stall_forced forced_on "/dev/disk$d"
fl_iter ext4 1 1 "$W/census/nouuid-stuck.img" > /dev/null 2>&1; d=$(cat "$S/disks")
expect never_mounted_nouuid_forced forced_on "/dev/disk$d"
fl_iter ext4 1 1 "$W/census/nouuid-swept-stuck.img" > /dev/null 2>&1; d=$(cat "$S/disks")
expect swept_nouuid_not_forced not forced_on "/dev/disk$d"
expect swept_nouuid_retried test "$(grep -c "^diskutil eject /dev/disk$d\$" "$S/calls.all")" -ge 2
rm -f "$S/nodes/disk$d" "$S/nodes/disk$d.m"   # the leftover goes without a stub call, so no forced detach is logged
# item 7's recovery: the remount's linuxfs attach never mounts and cannot be detached: the case step is skipped, said,
#   and the stale disk is not ejected again
echo flaky5 > "$W/img/flaky5.img"; first=disk$(($(cat "$S/disks") + 2))
r=$(census_trash_tags_case flaky5 2>&1)
expect census_ttc_stale_said has "$r" "^# census_trash_tags_case flaky5: /dev/disk[0-9]* is attached but not mounted as the pair's volume, so no case step"
expect census_ttc_stale_no_case test ! -e "$P/case.flaky5.pathconf.flaky5.txt"
expect census_ttc_stale_not_ejected_again test "$(grep -c "^diskutil eject /dev/$first\$" "$S/calls.all")" -eq 1
for f in "$S"/nodes/*; do case $f in *.m) ;; *) test -f "$f" || continue; case $(sed -n 's/^vol=//p' "$f") in *flaky5*) rm -f "$f" "$f.m" ;; esac ;; esac; done
rm -f "$W/img/flaky5.img"
expect census_waits_bounded test ! -s "$unbounded"
test ! -s "$unbounded" || sed 's/^/# /' "$unbounded"

test "$fails" -eq 0
