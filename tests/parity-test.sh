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
23:59:59   probed disk, id = /dev/disk3s1, with linuxfs_apfs, ongoing.
23:59:59   probed disk, id = /dev/disk3s1, with linuxfs_apfs, failure.
00:00:01   probed disk, id = /dev/disk3s1, with hfs, success.
00:00:02   probed disk, id = /dev/disk3s1, with hfs, success.
00:00:02   created disk, id = /Volumes/Control?owner=501.
00:00:05   created disk, id = /dev/disk4.
00:00:05   probed disk, id = /dev/disk4, with linuxfs_ext4, failure.
00:00:09   created disk, id = /dev/disk5.
EOF
r=$(census_probe_times < "$T/dalog")
expect probe_times test "$r" = "$(printf '%s\n' 'disk3s1 hfs 3s' 'disk4 none' 'disk5 none')"

# fat_names: check-names.py fat reads a FAT32 long name (UTF-16) from the FAT partition, found by its type GUID
if test "$(uname -s)" = Linux && command -v mkfs.vfat > /dev/null 2>&1 && command -v python3 > /dev/null 2>&1; then
  truncate -s 64M "$T/fat.img" && mkfs.vfat -F 32 -S 512 -s 1 "$T/fat.img" > /dev/null
  python3 -I - "$T/fat.img" <<'EOF'
import struct, sys
with open(sys.argv[1], "r+b") as f:
    bs = f.read(512)
    bps, spc, rsv, nfats = struct.unpack_from("<HBHB", bs, 11)
    fatsz, = struct.unpack_from("<I", bs, 36)
    rootc, = struct.unpack_from("<I", bs, 44)
    short = b"CAFE~1  TXT"
    s = 0
    for c in bytearray(short):
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    name = u"café".encode("utf-16-le") + b"\0\0"
    name += b"\xff" * (26 - len(name))
    lfn = struct.pack("<B10sBBB12sH4s", 0x41, name[:10], 0x0F, 0, s, name[10:22], 0, name[22:26])
    sde = struct.pack("<11sBBBHHHHHHHI", short, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    f.seek((rsv + nfats * fatsz + (rootc - 2) * spc) * bps)
    f.write(lfn + sde)
EOF
  python3 -I "$here/lib/gpt-wrap.py" "$T/fat.img" "$T/gpt-fat.img" EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" 2>&1)
  expect fat_names test "$r" = 63616665cc81
  python3 -I "$here/lib/gpt-wrap.py" "$T/fat.img" "$T/gpt-linux.img" 0FC63DAF-8483-4772-8E79-3D69D8477DE4
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-linux.img" 2>&1); rc=$?
  expect fat_names_by_type test "$rc" -ne 0 -a -n "$r"
  rm -f "$T/fat.img" "$T/gpt-fat.img" "$T/gpt-linux.img"
else echo "ok - fat_names # SKIP needs Linux, mkfs.vfat and python3"; fi

# unicode_image: unicode-images.sh's ext4-names.img holds both byte forms of one name in /pair, each file holding its name
if test "$(uname -s)" = Linux && command -v mkfs.ext4 > /dev/null 2>&1 && command -v debugfs > /dev/null 2>&1; then
  sh "$here/lib/unicode-images.sh" "$T/uni" > /dev/null 2>&1
  r=$(debugfs -R 'ls -p /pair' "$T/uni/ext4-names.img" 2> /dev/null)
  expect unicode_image_nfc has "$r" "/$(printf 'caf\303\251')/"
  expect unicode_image_nfd has "$r" "/$(printf 'cafe\314\201')/"
  r=$(debugfs -R 'ls -p /' "$T/uni/ext4-names.img" 2> /dev/null)
  expect unicode_image_root has "$r" "/$(printf 'nai\314\210ve')/"
  r=$(debugfs -R "cat /pair/$(printf 'cafe\314\201')" "$T/uni/ext4-names.img" 2> /dev/null)
  expect unicode_image_content test "$r" = "$(printf 'cafe\314\201')"
  rm -rf "$T/uni"
else echo "ok - unicode_image # SKIP needs Linux, mkfs.ext4 and debugfs"; fi

# census_dry: each census function against stub diskutil, hdiutil, osascript, guest-macosx-aqua, sudo, sysctl and linuxfs,
#   with directories for volumes. The stub bounded marks what runs under it, and a stub sleep outside it is a failure.
unset -f mkfile hdiutil diskutil
S=$T/stub; mkdir -p "$S/nodes" "$T/vols" "$T/in"
PARITY_FSTAB=$S/fstab PARITY_DALOG=$S/dalog PARITY_DAPL=$S/da.plist STUB=$S
export PARITY_FSTAB PARITY_DALOG STUB
: > "$PARITY_FSTAB"; : > "$PARITY_DALOG"; : > "$PARITY_DAPL"; : > "$S/calls"
for py in python3 /usr/bin/python; do command -v "$py" > /dev/null 2>&1 && PARITY_PYTHON=$py; done
cat > "$T/bin/stub" <<'EOF'
#!/bin/sh
# census_dry's stub of the Mac's disk tools: a node file per attached disk node (img, vol, mp, uuid, disk), .m when mounted
me=${0##*/}
printf '%s\n' "$me $*" >> "$STUB/calls"
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
    case $b in *hfs*|*fat32*) nd=${d}s1; echo "/dev/$d          	GUID_partition_scheme" ;; *) nd=$d ;; esac
    mp=$STUB/../vols/$b; mkdir -p "$mp"
    printf 'img=%s\nvol=%s\nmp=%s\nuuid=UUID-%s\ndisk=%s\n' "$img" "$b" "$mp" "$b" "$d" > "$N/$nd"
    log "created disk, id = /dev/$d."
    log "probed disk, id = /dev/$nd, with stub, success."
    if test -z "$nomount"; then : > "$N/$nd.m"; echo "/dev/$nd          	Stub	$mp"; else echo "/dev/$nd          	Stub"; fi ;;
  detach)
    for a; do case $a in disk*|/dev/disk*) d=${a#/dev/}; rm -f "$N/$d" "$N/$d.m" "$N/${d}s1" "$N/${d}s1.m" ;; esac; done ;;
  info)
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
    echo "   Volume UUID:              $(field "$nd" uuid)" ;;
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
    d=${2#/dev/}; rm -f "$N/$d" "$N/$d.m" "$N/${d}s1" "$N/${d}s1.m"; echo "Disk $d ejected" ;;
  esac ;;
linuxfs)
  case $1 in
  ignore) d=${2#/dev/}; echo "UUID=$(field "$d" uuid) none linuxfs_ext4 rw,noauto # linuxfs" >> "$PARITY_FSTAB" ;;
  unignore) d=${2#/dev/}; grep -v "^UUID=$(field "$d" uuid) " "$PARITY_FSTAB" > "$PARITY_FSTAB.t"; cat "$PARITY_FSTAB.t" > "$PARITY_FSTAB"; rm -f "$PARITY_FSTAB.t" ;;
  esac ;;
sudo)
  test "$1" != -n || shift
  case $1 in sh|tail|cat|wc) exec "$@" ;; lsof) echo "COMMAND PID USER (stub lsof $*)" ;; esac ;;
mkfile) : > "$2" ;;
sysctl) echo "$1.version.number: stub" ;;
esac
exit 0
EOF
chmod +x "$T/bin/stub"
for c in hdiutil diskutil osascript guest-macosx-aqua sudo sysctl mkfile linuxfs; do ln -sf stub "$T/bin/$c"; done
L=$T/bin/linuxfs; IN=$T/in
rm -rf "$W/ctl" "$OUT/parity"; mkdir -p "$W/img"
for f in ext4 btrfs; do echo "$f image" > "$W/img/$f.img"; done
echo names | gzip -c > "$IN/ext4-names.img.gz"
unbounded=$T/unbounded; : > "$unbounded"
bounded() { ( PARITY_TEST_BOUNDED=1; shift; "$@" ); }
sleep() { test -n "${PARITY_TEST_BOUNDED:-}" || { echo "sleep $* outside bounded" >> "$unbounded"; return 1; }; }
attached() { ls "$S/nodes" | grep -v '\.m$' | tr '\n' ' '; }

# census_unicode: the shell's and Finder's names on the pair, the FAT32 control once, the Linux-made names image for ext4
r=$(census_unicode ext4 2>&1)
P=$OUT/parity
for s in shell-create shell-listdir shell-open-other finder-newfolder finder-rename finder-listdir; do
  expect "census_unicode_$s" test -s "$P/unicode.ext4.$s.hfs.txt" -a -s "$P/unicode.ext4.$s.ext4.txt"
  expect "census_unicode_fat32_$s" test -s "$P/unicode.fat32.$s.hfs.txt" -a -s "$P/unicode.fat32.$s.fat32.txt"
done
for s in listdir-pair open-both; do expect "census_unicode_names_$s" test -s "$P/unicode.names.$s.ext4.txt"; done
expect census_unicode_listdir_bytes test "$(grep -c '^[0-9a-f][0-9a-f]*$' "$P/unicode.ext4.shell-listdir.ext4.txt")" -eq 2
expect census_unicode_open_other grep -Eq '^63616665cc81 (ok 636166c3a9|errno 2)$' "$P/unicode.ext4.shell-open-other.ext4.txt"
expect census_unicode_finder grep -q 'character id 233' "$S/calls"
expect census_unicode_shots test "$(grep -c 'screencapture -x .*-names.png' "$S/calls")" -eq 2
expect census_unicode_fat32_out test -s "$OUT/ctl-fat32.img.gz"
expect census_unicode_sysctl grep -q 'vfs.generic.macfuse' "$P/unicode-ext4.sysctl.txt"
expect census_unicode_recorded has "$r" "^# recorded unicode.ext4.shell-create"
expect census_unicode_quiet hasnt "$r" "not ok"
expect census_unicode_detached test -z "$(attached)"
: > "$S/calls"
census_unicode btrfs > /dev/null 2>&1
expect census_unicode_fat32_once not grep -q 'fat32' "$S/calls"
expect census_unicode_names_ext4_only not test -e "$P/unicode.names.listdir-pair.btrfs.txt"

# census_stall: not run at 0; at 2, both loops on both volumes, counted, with probe times and Fisher's p
: > "$S/calls"
r=$(census_stall 0 2>&1)
expect census_stall_zero test ! -e "$P/stall.txt" -a ! -s "$S/calls"
r=$(census_stall 2 2>&1)
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
expect census_busy_recorded has "$r" "^# recorded busy.ext4.cycles: hfs 0 of 20, ext4 1 of 20"
expect census_busy_quiet hasnt "$r" "not ok"
expect census_busy_sysctl test -s "$P/busy-ext4.sysctl.txt"
expect census_busy_detached test -z "$(attached)"

expect census_waits_bounded test ! -s "$unbounded"
test ! -s "$unbounded" || sed 's/^/# /' "$unbounded"

test "$fails" -eq 0
