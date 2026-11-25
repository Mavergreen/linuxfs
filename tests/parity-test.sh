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
EOF
  python3 -I "$here/lib/gpt-wrap.py" "$T/fat.img" "$T/gpt-fat.img" EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" 2>&1)
  expect fat_names_root test "$r" = 756e692d6661743332
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" uni-fat32 2>&1)
  expect fat_names test "$r" = 63616665cc81
  r=$(python3 -I "$here/lib/check-names.py" fat "$T/gpt-fat.img" nowhere 2>&1); rc=$?
  expect fat_names_no_dir test "$rc" -ne 0 -a -n "$r"
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
PARITY_FSTAB=$S/fstab PARITY_DALOG=$S/dalog PARITY_DAPL=$S/da.plist STUB=$S PARITY_POLLS=3
PARITY_SYSLOG=$S/syslog PARITY_ICNS=$S/icon.icns PARITY_SPOT_SECS=3
export PARITY_FSTAB PARITY_DALOG PARITY_SYSLOG STUB
: > "$PARITY_FSTAB"; : > "$PARITY_DALOG"; : > "$PARITY_DAPL"; : > "$S/calls"; : > "$PARITY_SYSLOG"; echo icns > "$PARITY_ICNS"
for py in python3 /usr/bin/python; do command -v "$py" > /dev/null 2>&1 && PARITY_PYTHON=$py; done
cat > "$T/bin/stub" <<'EOF'
#!/bin/sh
# census_dry's stub of the Mac's disk tools: a node file per attached disk node (img, vol, mp, uuid, disk), .m when mounted
me=${0##*/}
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
    test -z "$(field "$nd" uuid)" || echo "   Volume UUID:              $(field "$nd" uuid)" ;;
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
  ignore) d=${2#/dev/}; echo "UUID=$(field "$d" uuid) none linuxfs_ext4 rw,noauto # linuxfs" >> "$PARITY_FSTAB" ;;
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
xattr)
  case $1 in -w) echo "${#3}" >> "$STUB/xattr-sizes" ;; -l) echo "com.apple.FinderInfo: stub" ;; -px) echo "00 00 04 00" ;; esac ;;
guest-macosx-aqua)
  case $1 in
  screencapture) : > "$3" ;;
  defaults) test "$2" != read || exit 1 ;;
  osascript)
    case "$*" in
    *ejectable*) echo "true|true|false|1.34217728E+8|1.0E+8|Mac OS Extended format" ;;
    *"count items"*) echo 1 ;;
    *"get warns before emptying"*) echo true ;;
    esac ;;
  esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/stub"
for c in hdiutil diskutil osascript guest-macosx-aqua sudo sysctl mkfile linuxfs mdutil mdfind tmutil defaults xattr; do ln -sf stub "$T/bin/$c"; done
L=$T/bin/linuxfs; IN=$T/in
rm -rf "$W/ctl" "$OUT/parity"; mkdir -p "$W/img"
for f in ext4 btrfs ntfs apfs; do echo "$f image" > "$W/img/$f.img"; done
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
expect census_unicode_fat32_copy grep -q '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/census/ctl-fat32.img$' "$S/calls"
expect census_unicode_fat32_control_kept not grep -q '^hdiutil attach -imagekey diskimage-class=CRawDiskImage .*/ctl/fat32.img$' "$S/calls"
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
for s in refresh privacy privacy-ro; do expect "census_spotlight_shot_$s" test "$(grep -Ec "screencapture -x .*/(hfs|ext4)-$s.png$" "$S/calls")" -eq 2; done
expect census_spotlight_pane grep -q 'com.apple.preference.spotlight' "$S/calls"
expect census_spotlight_sysctl test -s "$P/spotlight-ext4.sysctl.txt"
expect census_spotlight_recorded has "$r" "^# recorded spotlight.ext4.ro.mdfind"
expect census_spotlight_quiet hasnt "$r" "not ok"
expect census_spotlight_detached test -z "$(attached)"

# census_finder: the screenshot pairs, Finder's properties against df -k, diskutil info's fields, a custom volume icon
: > "$S/calls"
r=$(census_finder ext4 2>&1)
for s in properties diskutil-info volumeicon; do expect "census_finder_$s" test -s "$P/finder.ext4.$s.hfs.txt" -a -s "$P/finder.ext4.$s.ext4.txt"; done
for s in sidebar getinfo desktop-on desktop-off icon; do expect "census_finder_shot_$s" test "$(grep -Ec "screencapture -x .*/(hfs|ext4)-$s.png$" "$S/calls")" -eq 2; done
expect census_finder_props grep -q '^capacity equals df -k' "$P/finder.ext4.properties.ext4.txt"
expect census_finder_props_ejectable grep -q '^ejectable: true$' "$P/finder.ext4.properties.hfs.txt"
expect census_finder_raw grep -q 'Mac OS Extended format' "$P/finder.ext4.raw.txt"
expect census_finder_icon_flag grep -q '^xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 .*/vols/finder-ext4$' "$S/calls"
expect census_finder_icns test -s "$T/vols/finder-ext4/.VolumeIcon.icns"
expect census_finder_desktop_on grep -q '^guest-macosx-aqua defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool true$' "$S/calls"
expect census_finder_desktop_off grep -q '^guest-macosx-aqua defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false$' "$S/calls"
expect census_finder_desktop_restored test "$(grep 'ShowExternalHardDrivesOnDesktop' "$S/calls" | tail -n 1)" = "guest-macosx-aqua defaults delete com.apple.finder ShowExternalHardDrivesOnDesktop"
expect census_finder_restarts test "$(grep -c '^guest-macosx-aqua killall Finder$' "$S/calls")" -ge 3
expect census_finder_quiet hasnt "$r" "not ok"
expect census_finder_detached test -z "$(attached)"
: > "$S/calls"
census_finder btrfs > /dev/null 2>&1
expect census_finder_hfs_shots_once test "$(grep -c 'screencapture -x .*/hfs-sidebar.png$' "$S/calls")" -eq 0 -a "$(grep -c 'screencapture -x .*/btrfs-sidebar.png$' "$S/calls")" -eq 1

# census_trash_tags_case: Finder's delete, .Trashes and empty trash; a tag and a label, after a remount too; the
#   oversized xattr; pathconf against HFS+ and against HFSX. APFS, read-only, gets the case step alone.
: > "$S/calls"; : > "$S/xattr-sizes"
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
for f in hfs ext4; do expect "census_ttc_oversized_tried_$f" test "$(grep -c '^13107[23] bytes: exit [0-9]*$' "$P/tags.ext4.oversized.$f.txt")" -eq 2; done
# Linux caps one exec argument at 131072 bytes with its NUL (MAX_ARG_STRLEN), so there the stub never starts; a Mac
#   (and 10.9, ARG_MAX 262144) passes both
if /bin/sh -c : "$(printf '%0131073d' 0)" > /dev/null 2>&1; then   # the same per-argument limit, logging nothing
  expect census_ttc_oversized test "$(sort -u "$S/xattr-sizes" | tr '\n' ' ')" = "131072 131073 "
else echo "ok - census_ttc_oversized # SKIP this host cannot pass a 128 KiB argument (Linux MAX_ARG_STRLEN)"; fi
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
r=$(census_trash_tags_case apfs 2>&1)
expect census_ttc_apfs_case test -s "$P/case.apfs.pathconf.apfs.txt" -a -s "$P/case.apfs.pathconf-hfsx.apfs.txt"
expect census_ttc_apfs_case_only test -z "$(ls "$P" | grep -E '^(trash|tags)\.apfs\.')"
expect census_ttc_apfs_detached test -z "$(attached)"

# census_later: Time Machine, the exFAT control against ext4 (each beside HFS+)
: > "$S/calls"
r=$(census_later 2>&1)
for k in exfat ext4; do
  expect "census_later_${k}_tm-excluded" test -s "$P/later.$k.tm-excluded.hfs.txt" -a -s "$P/later.$k.tm-excluded.$k.txt"
done
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
# the stub images are ext4, btrfs, ntfs and apfs: xfs and f2fs are said to be missing, and skipped
want=$(printf '%s\n' "stall 0 50" "unicode ext4 off" "unicode btrfs off" "unicode ntfs on" "busy ext4 off" "spotlight ext4 off" \
  "finder ext4 off" "finder btrfs off" "finder ntfs on" "finder apfs off" \
  "trash_tags_case ext4 off" "trash_tags_case btrfs off" "trash_tags_case ntfs on" "trash_tags_case apfs off" "later 0")
expect census_all_order test "$(cat "$ran")" = "$want"
expect census_all_missing has "$r" "^# census: no .*/img/xfs.img, so no census_finder xfs"
expect census_all_controls test -f "$W/ctl/hfs.img" -a -f "$W/ctl/hfsx.img" -a -f "$W/ctl/fat32.img" -a -f "$W/ctl/exfat.img"
expect census_all_takeover_off test ! -f "$S/takeover"
expect census_all_left grep -q "^/dev/$left .*/census/left-stuck.img\$" "$P/census-left-attached.txt"
expect census_all_left_said has "$r" "^# census: left attached .*left-stuck.img"
expect census_all_cleans test ! -e "$W/census/old.img" -a -e "$W/census/left-stuck.img"
: > "$ran"
r=$(PARITY_CENSUS_MIN=0; census_stall() { echo stall >> "$ran"; }; census_later() { echo later >> "$ran"; }; parity_census_all 2>&1)
expect census_all_out_of_time test ! -s "$ran"
expect census_all_out_of_time_said has "$r" "^# census: out of time (0 min), skipped: census_stall"
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
