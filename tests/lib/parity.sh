# platform: host-agnostic
#   Parity library, sourced by tests/smoke-mavericks.sh, which provides ok, notok, bounded, OUT and W
#   (bounded takes tenths of a second, and on a timeout prints a "hung:" line and returns 124).
#   Runs one step on an HFS+ control volume and on the filesystem under test, then records or
#   compares what each did. POSIX sh, sed and diff only.
#
#   parity_control KIND                   makes $W/ctl/KIND.img once, prints its path
#                                         (KIND: hfs, hfsx, fat32 or exfat)
#   parity_pair CTL_DISK CTL_MP CTL_VOL FS FS_DISK FS_MP FS_VOL
#                                         sets the current pair; the HFS+ side is current
#   parity_side hfs|fs                    picks the side parity_shot photographs
#   parity WHAT CMD...                    runs CMD on each volume, @MP@ @VOL@ @DISK@ replaced, with no
#                                         stdin and bounded by PARITY_BOUND (default 600 = 60 s; a
#                                         timeout is status 124 in the record, so check says not ok);
#                                         mode is PARITY_MODE_<ITEM> (record|check), ITEM being
#                                         WHAT up to its first dot, upper-cased, other characters
#                                         becoming _; default record, anything else is not ok
#   parity_norm MP VOL DISK               filter: MP, VOL and diskNsM become <MP>, <VOL>, <DISK>
#   parity_shot STEP                      screenshot into $OUT/<side>-STEP.png, never compared
#
#   The census (record-only until an item's task sets PARITY_MODE_<ITEM>=check; also reads IN and L, the smoke's):
#   census_unicode FS                     item 1: names made in NFC and NFD from the shell and by Finder, on HFS+
#                                         against FS; for ext4, IN's ext4-names.img too; once, the FAT32 control,
#                                         returned as $OUT/ctl-fat32.img.gz
#   census_stall                          item 3: spike round 4's attach loops on HFS+ and ext4, PARITY_STALL_N times
#                                         each (unset or 0 runs nothing); counts, probe times and Fisher's p
#   census_busy FS                        item 4: write-then-unmount cycles, and a held file's unmount and ejects
#                                         (forced ones on HFS+ alone unless PARITY_BUSY_FORCE=1)
#   Each records sysctl vfs.generic.macfuse once, as $OUT/parity/<census>.sysctl.txt.

parity_control() {
  _pc_kind=$1
  case $_pc_kind in
  hfs) _pc_fs=JHFS+ ;;
  hfsx) _pc_fs=JHFSX ;;
  fat32) _pc_fs=FAT32 ;;
  exfat) _pc_fs=ExFAT ;;
  *) echo "parity_control: unknown kind $_pc_kind" >&2; return 2 ;;
  esac
  _pc_img=$W/ctl/$_pc_kind.img
  if test ! -f "$_pc_img"; then
    mkdir -p "$W/ctl" || return 1
    bounded "${PARITY_BOUND:-600}" mkfile 128m "$_pc_img" </dev/null || { rm -f "$_pc_img"; return 1; }
    _pc_out=$(bounded "${PARITY_BOUND:-600}" hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$_pc_img" 2>&1 </dev/null)
    _pc_dev=$(printf '%s\n' "$_pc_out" | sed -n 's,^/dev/\(disk[0-9][0-9]*\).*,\1,p' | head -1)
    if test -z "$_pc_dev"; then
      echo "parity_control: hdiutil attach of $_pc_img failed: $_pc_out" >&2
      rm -f "$_pc_img"; return 1
    fi
    bounded "${PARITY_BOUND:-600}" diskutil eraseDisk "$_pc_fs" Control GPT "$_pc_dev" </dev/null >&2
    _pc_rc=$?
    bounded "${PARITY_BOUND:-600}" hdiutil detach "$_pc_dev" </dev/null >&2 || _pc_rc=1
    if test "$_pc_rc" -ne 0; then rm -f "$_pc_img"; return 1; fi
  fi
  echo "$_pc_img"
}

parity_pair() {
  PARITY_CTL_DISK=$1 PARITY_CTL_MP=$2 PARITY_CTL_VOL=$3 PARITY_FS=$4
  PARITY_FS_DISK=$5 PARITY_FS_MP=$6 PARITY_FS_VOL=$7
  PARITY_SIDE=hfs
}

parity_side() { PARITY_SIDE=$1; }

# parity_sub STRING TOKEN VALUE: STRING with every TOKEN replaced by VALUE, as text
parity_sub() {
  _ps_in=$1 _ps_out=
  while :; do
    case $_ps_in in
    *"$2"*) _ps_out=$_ps_out${_ps_in%%"$2"*}$3; _ps_in=${_ps_in#*"$2"} ;;
    *) break ;;
    esac
  done
  printf '%s' "$_ps_out$_ps_in"
}

# parity_esc TEXT: TEXT escaped for the pattern side of a sed s command (delimiter /)
parity_esc() { printf '%s\n' "$1" | sed 's/[][\.*^$/]/\\&/g'; }

parity_norm() {
  _pn_sed=
  if test -n "$1"; then _pn_sed="s/$(parity_esc "$1")/<MP>/g"; fi
  if test -n "$2"; then _pn_sed="$_pn_sed;s/$(parity_esc "$2")/<VOL>/g"; fi
  # diskN or diskNsM as a whole word; twice, because neighbours share their boundary
  _pn_d='s/(^|[^A-Za-z0-9])disk[0-9]+(s[0-9]+)?([^A-Za-z0-9]|$)/\1<DISK>\3/g'
  sed "${_pn_sed#;}" | sed -E "$_pn_d;$_pn_d"
}

# parity_run SIDE MP VOL DISK CMD...: one run, normalized stdout, stderr and status on stdout
parity_run() {
  _pr_mp=$2 _pr_vol=$3 _pr_disk=$4; shift 4
  _pr_n=$#
  while test "$_pr_n" -gt 0; do
    _pr_a=$(parity_sub "$1" @MP@ "$_pr_mp")
    _pr_a=$(parity_sub "$_pr_a" @VOL@ "$_pr_vol")
    _pr_a=$(parity_sub "$_pr_a" @DISK@ "$_pr_disk")
    set -- "$@" "$_pr_a"; shift; _pr_n=$((_pr_n - 1))
  done
  _pr_t=$OUT/parity/.run.$$
  bounded "${PARITY_BOUND:-600}" "$@" >"$_pr_t.out" 2>"$_pr_t.err" </dev/null; _pr_st=$?
  { echo "== stdout"; awk 1 "$_pr_t.out"; echo "== stderr"; awk 1 "$_pr_t.err"; echo "== status $_pr_st"; } |
    parity_norm "$_pr_mp" "$_pr_vol"
  rm -f "$_pr_t.out" "$_pr_t.err"
}

parity() {
  _pw_what=$1; shift
  _pw_item=$(printf '%s' "${_pw_what%%.*}" | tr '[:lower:]' '[:upper:]')
  _pw_item=$(printf '%s' "$_pw_item" | tr -c 'A-Za-z0-9\n' _)
  eval "_pw_mode=\${PARITY_MODE_$_pw_item:-record}"
  case $_pw_mode in
  record|check) ;;
  *) notok "parity $_pw_what"; echo "parity: PARITY_MODE_$_pw_item is '$_pw_mode', not record or check"; return 1 ;;
  esac
  _pw_dir=$OUT/parity
  mkdir -p "$_pw_dir" || return 1
  parity_run hfs "$PARITY_CTL_MP" "$PARITY_CTL_VOL" "$PARITY_CTL_DISK" "$@" >"$_pw_dir/$_pw_what.hfs.txt"
  parity_run "$PARITY_FS" "$PARITY_FS_MP" "$PARITY_FS_VOL" "$PARITY_FS_DISK" "$@" >"$_pw_dir/$_pw_what.$PARITY_FS.txt"
  if test "$_pw_mode" = check; then
    # two timeouts leave identical records, which must not pass
    if grep -q '^== status 124$' "$_pw_dir/$_pw_what.hfs.txt" "$_pw_dir/$_pw_what.$PARITY_FS.txt"; then
      _pw_hung=1
    else
      _pw_hung=0
    fi
    if _pw_d=$(diff -u "$_pw_dir/$_pw_what.hfs.txt" "$_pw_dir/$_pw_what.$PARITY_FS.txt") && test "$_pw_hung" -eq 0; then
      ok "parity $_pw_what"
    else
      notok "parity $_pw_what"
      test "$_pw_hung" -eq 0 || echo "parity: $_pw_what timed out (status 124)"
      printf '%s\n' "$_pw_d"
    fi
  else
    echo "# recorded $_pw_what"
  fi
}

parity_shot() {
  if test "$PARITY_SIDE" = hfs; then _psh_side=hfs; else _psh_side=$PARITY_FS; fi
  guest-macosx-aqua screencapture -x "$OUT/$_psh_side-$1.png"
}

# ---- the census (items 1, 3 and 4): record-only until each item's task sets PARITY_MODE_<ITEM>=check ----
# Each function attaches copies of its images under $W/census (the HFS+ control from parity_control, the filesystem's
# from $W/img/FS.img), records into $OUT/parity, prints a "# recorded" line per step, and ejects what it attached.
# Every wait goes through bounded. Variables are kept apart by a prefix per function (bash 3.2 as sh has no local).
PARITY_LIB=${PARITY_LIB:-$(cd "$(dirname "$0")" && pwd)/lib}
PARITY_PYTHON=${PARITY_PYTHON:-/usr/bin/python}
PARITY_FSTAB=${PARITY_FSTAB:-/etc/fstab}
PARITY_DALOG=${PARITY_DALOG:-/var/log/diskarbitrationd.log}
PARITY_POLLS=${PARITY_POLLS:-60}   # census_wait_*: once a second; the tests poll fewer times

# census_pause SECONDS: a sleep, bounded like every other wait
census_pause() { bounded $(($1 * 10 + 20)) sleep "$1"; }

# census_sysctl TAG: macFUSE's tunables, once per census function (item 5 reads them)
census_sysctl() {
  mkdir -p "$OUT/parity" || return 1
  { echo "== sysctl vfs.generic.macfuse"; bounded 100 sysctl vfs.generic.macfuse 2>&1 </dev/null; echo "== status $?"; } >"$OUT/parity/$1.sysctl.txt"
}

# census_info NODE KEY: one field of diskutil info
census_info() { bounded 300 diskutil info "$1" 2>/dev/null </dev/null | sed -n "s/^ *$2: *//p" | head -n 1; }

# census_wait_mounted NODE...: waits up to PARITY_POLLS (60) s for one of the nodes to be mounted; prints its node,
#   then its mount point
census_wait_mounted() {
  _cw_k=0
  while test "$_cw_k" -lt "$PARITY_POLLS"; do
    for _cw_d; do
      if test "$(census_info "$_cw_d" Mounted)" = Yes; then
        _cw_m=$(census_info "$_cw_d" "Mount Point")
        if test -n "$_cw_m"; then printf '%s\n%s\n' "$_cw_d" "$_cw_m"; return 0; fi
      fi
    done
    _cw_k=$((_cw_k + 1)); sleep 1
  done
  return 1
}

# census_attach IMAGE [nomount]: attaches; sets CA_DISK (the whole disk) and CA_NODES (every node), and unless nomount
#   waits for the mount: CA_DEV, CA_MP, CA_VOL. On failure says why and detaches what it attached.
census_attach() {
  CA_DISK= CA_NODES= CA_DEV= CA_MP= CA_VOL=
  if test "${2:-}" = nomount; then _ca_o=-nomount; else _ca_o=; fi
  _ca_out=$(bounded 3000 hdiutil attach $_ca_o -imagekey diskimage-class=CRawDiskImage "$1" 2>&1 </dev/null); _ca_rc=$?
  CA_NODES=$(printf '%s\n' "$_ca_out" | awk '/^\/dev\/disk/ { print $1 }' | tr '\n' ' ')
  CA_DISK=${CA_NODES%% *}
  if test -z "$CA_DISK"; then echo "# census: hdiutil attach $1 failed (exit $_ca_rc): $(printf '%s' "$_ca_out" | tr '\n' ' ')"; return 1; fi
  test "${2:-}" != nomount || return 0
  # shellcheck disable=SC2086  # the nodes are words
  if ! _ca_m=$(bounded 900 census_wait_mounted $CA_NODES); then
    echo "# census: $1 attached as $CA_DISK, not mounted within 60 s"; census_detach_checked "$CA_DISK" fs; return 1
  fi
  CA_DEV=$(printf '%s\n' "$_ca_m" | sed -n 1p) CA_MP=$(printf '%s\n' "$_ca_m" | sed -n 2p)
  CA_VOL=${CA_MP##*/}
}

# census_detach DISK [apple|nomount|fs] [MP]: eject. When that fails, only a disk of Apple's filesystems (HFS+, FAT32) or one
#   attached -nomount and never mounted is detached by force; a linuxfs disk (fs, the default) is not, unless
#   PARITY_BUSY_FORCE=1 (a forced unmount of a busy macFUSE volume runs on the QEMU kit first): its failure is said, with
#   sudo lsof on MP, and the eject tried once more. Returns 1 when the disk is left attached.
census_detach() {
  test -n "$1" || return 0
  _cd_o=$(bounded 600 diskutil eject "$1" 2>&1 </dev/null) && return 0
  case ${2:-fs}:${PARITY_BUSY_FORCE:-0} in
  apple:* | nomount:* | *:1) bounded 300 hdiutil detach -force "$1" >/dev/null 2>&1 </dev/null; return ;;
  esac
  echo "# census: diskutil eject $1 failed: $(printf '%s' "$_cd_o" | tr '\n' ' ')"
  if test -n "${3:-}"; then echo "# census: sudo lsof $3:"; bounded 900 sudo -n lsof "$3" 2>&1 </dev/null | head -n 40 | sed 's/^/#   /'; fi
  census_pause 2
  echo "# census: retrying diskutil eject $1 (a linuxfs disk is not detached by force)"
  _cd_o=$(bounded 600 diskutil eject "$1" 2>&1 </dev/null) && return 0
  echo "# census: diskutil eject $1 failed again; left attached: $(printf '%s' "$_cd_o" | tr '\n' ' ')"
  return 1
}

# census_detach_checked DISK SIDE: census_detach of DISK as SIDE, with its mount point, when any node of it (the whole
#   disk, s1 to s4) is mounted; as nomount when none is
census_detach_checked() {
  for _cdc_n in "$1" "${1}s1" "${1}s2" "${1}s3" "${1}s4"; do
    if test "$(census_info "$_cdc_n" Mounted)" = Yes; then census_detach "$1" "$2" "$(census_info "$_cdc_n" "Mount Point")"; return; fi
  done
  census_detach "$1" nomount
}

# census_image_disk IMAGE: the whole disk IMAGE is attached as, if it is
census_image_disk() {
  bounded 600 hdiutil info 2>/dev/null </dev/null | awk -v p="$1" '/^image-path/ { sub(/^image-path[ \t]*:[ \t]*/, ""); cur = ($0 == p) } cur && /^\/dev\/disk[0-9]+[ \t]/ { print $1; exit }'
}

# census_copy SOURCE NAME: a fresh copy of SOURCE as $W/census/NAME.img; prints its path
census_copy() {
  mkdir -p "$W/census" && cp "$1" "$W/census/$2.img" || { echo "# census: cannot copy $1" >&2; return 1; }
  echo "$W/census/$2.img"
}

# census_shot STEP SIDE: parity_shot for one side, bounded
census_shot() { parity_side "$2"; bounded 300 parity_shot "$1" >/dev/null 2>&1; }

# census_hfs_only WHAT CMD...: one step on the HFS+ side alone, recorded as parity would (WHAT.hfs.txt)
census_hfs_only() {
  _ch_what=$1; shift
  parity_run hfs "$PARITY_CTL_MP" "$PARITY_CTL_VOL" "$PARITY_CTL_DISK" "$@" >"$OUT/parity/$_ch_what.hfs.txt"
  echo "# recorded $_ch_what (HFS+ only)"
}

# ---- item 1: Unicode names ----
# Python (2.7 in the guest, 3 in the tests) given hex names: create (each file holding its own leaf name), list (the
# directory's names as hex bytes, sorted) and open (each name: ok and its content, or the errno)
census_py_create='import binascii, os, sys
d = sys.argv[1]
d = d if isinstance(d, bytes) else os.fsencode(d)
for h in sys.argv[2:]:
    n = binascii.unhexlify(h)
    p = os.path.join(d, n)
    if not os.path.isdir(os.path.dirname(p)):
        os.makedirs(os.path.dirname(p))
    f = open(p, "wb"); f.write(os.path.basename(n)); f.close()
    print(h + " created")'
census_py_list='import binascii, os, sys
d = sys.argv[1]
d = d if isinstance(d, bytes) else os.fsencode(d)
for n in sorted(os.listdir(d)):
    print(binascii.hexlify(n).decode())'
census_py_open='import binascii, os, sys
d = sys.argv[1]
d = d if isinstance(d, bytes) else os.fsencode(d)
for h in sys.argv[2:]:
    try:
        f = open(os.path.join(d, binascii.unhexlify(h)), "rb"); c = f.read(); f.close()
        print(h + " ok " + binascii.hexlify(c).decode())
    except (IOError, OSError) as e:
        print(h + " errno " + str(e.errno))'

# census_unicode_steps TAG: on the current pair, in uni-TAG: NFC caf\xc3\xa9 and NFD nai\xcc\x88ve made from the shell,
#   listed, and opened by the other form; then a Finder New Folder with an NFC name and one renamed to another, listed
census_unicode_steps() {
  _cs_t=$1
  parity "unicode.$_cs_t.shell-create" "$PARITY_PYTHON" -c "$census_py_create" "@MP@/uni-$_cs_t" 636166c3a9 6e6169cc887665
  parity "unicode.$_cs_t.shell-listdir" "$PARITY_PYTHON" -c "$census_py_list" "@MP@/uni-$_cs_t"
  parity "unicode.$_cs_t.shell-open-other" "$PARITY_PYTHON" -c "$census_py_open" "@MP@/uni-$_cs_t" 63616665cc81 6e61c3af7665
  parity "unicode.$_cs_t.finder-newfolder" guest-macosx-aqua osascript \
    -e "tell application \"Finder\" to make new folder at (POSIX file \"@MP@/uni-$_cs_t\" as alias) with properties {name:\"caf\" & (character id 233) & \"-finder\"}"
  parity "unicode.$_cs_t.finder-rename" guest-macosx-aqua osascript -e 'tell application "Finder"' \
    -e "set f to make new folder at (POSIX file \"@MP@/uni-$_cs_t\" as alias)" \
    -e 'set name of f to "na" & (character id 239) & "ve-finder"' -e 'end tell'
  parity "unicode.$_cs_t.finder-listdir" "$PARITY_PYTHON" -c "$census_py_list" "@MP@/uni-$_cs_t"
}

# census_unicode_names HFS-DISK HFS-MP HFS-VOL: the Linux-made ext4-names.img against the same names made on HFS+ from
#   the shell: pair/ listed, every name opened by both forms, and pair/ shown in Finder (parity_shot names)
census_unicode_names() {
  if test ! -f "$IN/ext4-names.img.gz"; then echo "# census_unicode: no $IN/ext4-names.img.gz (tests/lib/unicode-images.sh)"; return 0; fi
  mkdir -p "$W/census" && gunzip -c "$IN/ext4-names.img.gz" >"$W/census/ext4-names.img" || return 1
  bounded 600 "$PARITY_PYTHON" -c "$census_py_create" "$2" 636166c3a9 6e6169cc887665 706169722f636166c3a9 706169722f63616665cc81 >/dev/null 2>&1 </dev/null
  census_attach "$W/census/ext4-names.img" || return 1
  parity_pair "$1" "$2" "$3" ext4 "$CA_DISK" "$CA_MP" "$CA_VOL"
  parity unicode.names.listdir-pair "$PARITY_PYTHON" -c "$census_py_list" @MP@/pair
  parity unicode.names.open-both "$PARITY_PYTHON" -c "$census_py_open" @MP@ \
    636166c3a9 63616665cc81 6e6169cc887665 6e61c3af7665 706169722f636166c3a9 706169722f63616665cc81
  for _cn_s in hfs fs; do
    if test "$_cn_s" = hfs; then _cn_m=$2; else _cn_m=$CA_MP; fi
    bounded 300 guest-macosx-aqua osascript -e "tell application \"Finder\" to open (POSIX file \"$_cn_m/pair\" as alias)" >/dev/null 2>&1 </dev/null
    census_pause 3
    census_shot names "$_cn_s"
    bounded 300 guest-macosx-aqua osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1 </dev/null
  done
  census_detach "$CA_DISK" fs "$CA_MP"
}

# census_unicode FS: item 1 on the HFS+ control against FS; for ext4 also the Linux-made names; and once, the FAT32
#   control (a copy) against HFS+, that copy then gzipped into OUT as ctl-fat32.img.gz for the fsck job's check-names.py
census_unicode() {
  _cu_fs=$1
  census_sysctl "unicode-$_cu_fs"
  _cu_c=$(parity_control hfs) && _cu_h=$(census_copy "$_cu_c" "unicode-hfs-$_cu_fs") && _cu_i=$(census_copy "$W/img/$_cu_fs.img" "unicode-$_cu_fs") ||
    { echo "# census_unicode $_cu_fs: no images"; return 1; }
  census_attach "$_cu_h" || return 1
  _cu_hd=$CA_DISK _cu_hm=$CA_MP _cu_hv=$CA_VOL
  if census_attach "$_cu_i"; then
    parity_pair "$_cu_hd" "$_cu_hm" "$_cu_hv" "$_cu_fs" "$CA_DISK" "$CA_MP" "$CA_VOL"
    census_unicode_steps "$_cu_fs"
    census_detach "$CA_DISK" fs "$CA_MP"
  fi
  test "$_cu_fs" != ext4 || census_unicode_names "$_cu_hd" "$_cu_hm" "$_cu_hv"
  if test ! -f "$W/census/ctl-fat32.done"; then
    if _cu_c=$(parity_control fat32) && _cu_f=$(census_copy "$_cu_c" ctl-fat32) && census_attach "$_cu_f"; then
      parity_pair "$_cu_hd" "$_cu_hm" "$_cu_hv" fat32 "$CA_DISK" "$CA_MP" "$CA_VOL"
      census_unicode_steps fat32
      census_detach "$CA_DISK" apple
      gzip -c "$_cu_f" >"$OUT/ctl-fat32.img.gz" && : >"$W/census/ctl-fat32.done"
    else echo "# census_unicode: no FAT32 control"; fi
  fi
  census_detach "$_cu_hd" apple
}

# ---- item 3: the plain-attach stall (spike round 4's loop, git show 8a34bc1:tests/smoke-mavericks.sh) ----
# DiskArbitration with -d logs to $PARITY_DALOG; da_debug_on restarts it so, da_debug_off restores it (diagnostics only:
#   without it the loop still counts)
DADL=/private/tmp/parity-da-debug.plist DADE=/private/tmp/parity-da-debug.log
da_debug_on() {
  PARITY_DAPL=${PARITY_DAPL:-$(ls /System/Library/LaunchDaemons/*diskarbitrationd*.plist 2>/dev/null | head -n 1)}
  test -n "$PARITY_DAPL" || { echo "# no diskarbitrationd launchd plist: no debug log"; return 1; }
  bounded 300 sudo -n rm -f "$DADL" "$DADE" </dev/null
  bounded 300 sudo -n cp "$PARITY_DAPL" "$DADL" </dev/null || return 1
  # spike round 2: the system plist names only Program, so ProgramArguments is built, -d added, stderr kept
  bounded 300 sudo -n /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' -c 'Add :ProgramArguments: string /usr/libexec/diskarbitrationd' \
    -c 'Add :ProgramArguments: string -d' -c "Add :StandardErrorPath string $DADE" -c "Add :StandardOutPath string $DADE" "$DADL" </dev/null 2>&1 | sed 's/^/# PlistBuddy: /'
  bounded 300 sudo -n launchctl unload "$PARITY_DAPL" </dev/null 2>&1 | sed 's/^/# unload: /'
  bounded 300 sudo -n killall diskarbitrationd >/dev/null 2>&1 </dev/null; census_pause 1
  bounded 300 sudo -n launchctl load "$DADL" </dev/null 2>&1 | sed 's/^/# load: /'
  census_pause 3
  bounded 300 diskutil list >/dev/null 2>&1 </dev/null || echo "# diskutil does not answer with the debug DiskArbitration"
}
da_debug_off() {  # TAG: restores DiskArbitration, and keeps its log as $OUT/parity/TAG.diskarbitrationd.log
  test -n "${PARITY_DAPL:-}" || return 0
  bounded 300 sudo -n launchctl unload "$DADL" >/dev/null 2>&1 </dev/null
  bounded 300 sudo -n killall diskarbitrationd >/dev/null 2>&1 </dev/null; census_pause 1
  bounded 300 sudo -n launchctl load "$PARITY_DAPL" </dev/null 2>&1 | sed 's/^/# reload: /'
  census_pause 3
  bounded 600 sudo -n cat "$PARITY_DALOG" >"$OUT/parity/$1.diskarbitrationd.log" 2>/dev/null </dev/null
}
da_mark() { bounded 100 sudo -n sh -c 'printf "=== %s ===\n" "$1" >> "$2"' _ "$1" "$PARITY_DALOG" >/dev/null 2>&1 </dev/null; }
census_dalog_size() { bounded 300 sudo -n sh -c 'wc -c < "$1"' _ "$PARITY_DALOG" 2>/dev/null </dev/null | tr -d ' '; }
census_dalog_since() { bounded 300 sudo -n tail -c +"$(($1 + 1))" "$PARITY_DALOG" 2>/dev/null </dev/null; }

# census_probe_times: filter of a DiskArbitration debug log: for each whole disk created, each node's first probe
#   success, "NODE BUNDLE Ns" (seconds after "created disk"), or "DISK none"
census_probe_times() {
  awk '
    function secs(t, a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
    / created disk, id = \/dev\/disk[0-9]+\.$/ {
      d = $0; sub(/.*id = \/dev\//, "", d); sub(/\.$/, "", d); t0[d] = secs($1); order[++n] = d; out[d] = ""; next
    }
    / probed disk, id = \/dev\/disk[0-9]+(s[0-9]+)?, with .*, success\.$/ {
      nd = $0; sub(/.*id = \/dev\//, "", nd); sub(/,.*/, "", nd); w = nd; sub(/s[0-9]+$/, "", w)
      if (!(w in t0) || ((w, nd) in seen)) next
      seen[w, nd] = 1
      b = $0; sub(/.*, with /, "", b); sub(/, success\.$/, "", b)
      e = secs($1) - t0[w]; if (e < 0) e += 86400
      out[w] = out[w] nd " " b " " e "s\n"
    }
    END { for (i = 1; i <= n; i++) printf "%s", (out[order[i]] != "" ? out[order[i]] : order[i] " none\n") }'
}

# fl_plain IMAGE LOG: a plain attach, then up to 60 s for the mount; sets PA_DISK PA_MP PA_VERDICT; 1 for a stall
fl_plain() {
  PA_DISK= PA_MP=; pa_t0=$(date +%s)
  bounded 6000 hdiutil attach -verbose -imagekey diskimage-class=CRawDiskImage "$1" >"$2" 2>&1 </dev/null; pa_rc=$?
  PA_DISK=$(awk '/^\/dev\/disk/ { print $1; exit }' "$2")
  if test "$pa_rc" -ne 0; then
    PA_VERDICT="stalled after $(($(date +%s) - pa_t0)) s: hdiutil exit $pa_rc: $(grep -i 'hdiutil:' "$2" | tail -n 1)"
    test -n "$PA_DISK" || PA_DISK=$(census_image_disk "$1"); return 1
  fi
  # shellcheck disable=SC2046  # the nodes are words
  if pa_m=$(bounded 900 census_wait_mounted $(awk '/^\/dev\/disk/ { print $1 }' "$2")); then
    PA_MP=$(printf '%s\n' "$pa_m" | sed -n 2p)
    PA_VERDICT="automounted in $(($(date +%s) - pa_t0)) s"; return 0
  fi
  PA_VERDICT="stalled after $(($(date +%s) - pa_t0)) s: attached as $PA_DISK, never mounted"; return 1
}

# fl_detach SIDE: fl_plain's disk detached; one that never mounted (a stall) is checked, so it may go as nomount
fl_detach() {
  if test -n "$PA_MP"; then census_detach "$PA_DISK" "$1" "$PA_MP"; else census_detach_checked "$PA_DISK" "$1"; fi >>"$OUT/parity/stall-detach.txt"
}

# fl_iter VOLUME(hfs|ext4) LOOP(1|2) NUMBER IMAGE: one iteration, appended to stall.txt; 1 for a stall, 2 for a setup failure
#   loop 1: attach -nomount, the noauto entry (HFS+: written by hand; ext4: linuxfs ignore), diskutil mount, the entry
#           taken away (linuxfs unignore), eject, then the plain attach that is counted
#   loop 2: a plain attach, eject, then the plain attach that is counted
fl_iter() {
  it_vol=$1 it_tag=$1-loop$2-$3 it_img=$4 it_via= it_fu= it_s3= it_mp=
  if test "$1" = hfs; then it_side=apple; else it_side=fs; fi
  if test "$2" = 1; then
    census_attach "$it_img" nomount || { echo "$it_tag: setup failed: no disk from attach -nomount" >>"$OUT/parity/stall.txt"; return 2; }
    it_disk=$CA_DISK
    # shellcheck disable=SC2086  # the nodes are words
    it_dv=$(bounded 900 census_wait_uuid $CA_NODES) || it_dv=
    it_dev=$(printf '%s\n' "$it_dv" | sed -n 1p) it_fu=$(printf '%s\n' "$it_dv" | sed -n 2p)
    if test -z "$it_fu"; then census_detach_checked "$it_disk" "$it_side"; echo "$it_tag: setup failed: no Volume UUID" >>"$OUT/parity/stall.txt"; return 2; fi
    census_pause 6   # as round 4 did: the agent's sweep may mount it first
    it_how=nomount
    if test "$(census_info "$it_dev" Mounted)" = Yes; then
      it_how=$it_side it_mp=$(census_info "$it_dev" "Mount Point"); bounded 6000 diskutil unmount "$it_dev" >/dev/null 2>&1 </dev/null
    fi
    if test "$it_vol" = hfs; then
      bounded 300 sudo -n sh -c 'printf "%s\n" "$2" >> "$1"' _ "$PARITY_FSTAB" "UUID=$it_fu none hfs rw,noauto" </dev/null
    else
      bounded 6000 "$L" ignore "$it_disk" >/dev/null 2>&1 </dev/null
    fi
    if ! grep -q "^UUID=$it_fu " "$PARITY_FSTAB" 2>/dev/null; then
      census_detach "$it_disk" "$it_how" "$it_mp"; echo "$it_tag: setup failed: no noauto entry for UUID $it_fu" >>"$OUT/parity/stall.txt"; return 2
    fi
    da_mark "$it_tag: diskutil mount"
    bounded 6000 diskutil mount "$it_dev" >/dev/null 2>&1 </dev/null; it_s3=$?
    if it_m=$(bounded 1300 census_wait_mounted "$it_dev"); then it_mp=$(printf '%s\n' "$it_m" | sed -n 2p); else it_s3="$it_s3, not mounted"; fi
    test "$it_vol" = hfs || bounded 6000 "$L" unignore "$it_disk" >/dev/null 2>&1 </dev/null
    if grep -q "^UUID=$it_fu " "$PARITY_FSTAB" 2>/dev/null; then
      bounded 300 sudo -n sh -c 'grep -v "^UUID=$2 " "$1" > "$1.parity"; cat "$1.parity" > "$1"; rm -f "$1.parity"' _ "$PARITY_FSTAB" "$it_fu" </dev/null
      test "$it_vol" = hfs || it_via=" | unignore left the entry: the harness took it away"
    fi
    census_detach "$it_disk" "$it_side" "$it_mp" >>"$OUT/parity/stall-detach.txt"
    it_first="ignore, diskutil mount (exit $it_s3), unignore, eject"
  else
    fl_plain "$it_img" "$W/census/fl-first.log"; it_first="first attach: $PA_VERDICT"
    fl_detach "$it_side"
  fi
  it_dal=$(census_dalog_size); : "${it_dal:=0}"
  da_mark "$it_tag: plain attach"
  fl_plain "$it_img" "$W/census/fl-plain.log"; it_ok=$?
  it_probe=$(census_dalog_since "$it_dal" | census_probe_times | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  if test "$it_ok" -ne 0; then census_dalog_since "$it_dal" | tail -n 400 >"$OUT/parity/stall-$it_tag.dalog"; fi
  fl_detach "$it_side"
  echo "$it_tag: $PA_VERDICT | probe ${it_probe:-none} | ${it_fu:+uuid $it_fu | }$it_first$it_via" >>"$OUT/parity/stall.txt"
  return "$it_ok"
}

# census_wait_uuid NODE...: waits up to PARITY_POLLS (60) s for a node with a Volume UUID; prints the last such node
#   (an EFI partition, if diskutil made one, comes before the volume's), then its UUID
census_wait_uuid() {
  _cv_k=0
  while test "$_cv_k" -lt "$PARITY_POLLS"; do
    _cv_n= _cv_v=
    for _cv_d; do
      _cv_u=$(census_info "$_cv_d" "Volume UUID")
      test -z "$_cv_u" || { _cv_n=$_cv_d _cv_v=$_cv_u; }
    done
    if test -n "$_cv_v"; then printf '%s\n%s\n' "$_cv_n" "$_cv_v"; return 0; fi
    _cv_k=$((_cv_k + 1)); sleep 1
  done
  return 1
}

# census_stall: item 3, PARITY_STALL_N iterations (unset or 0: nothing runs) of each loop on the HFS+ control and
#   on ext4; stall.txt has a line per iteration (the verdict and each probe's time), stall-summary.txt the counts and
#   Fisher's exact p per loop (tests/lib/fisher.py: the volumes differ when p < 0.05)
census_stall() {
  st_n=${PARITY_STALL_N:-0}
  case $st_n in '' | *[!0-9]*) st_n=0 ;; esac
  if test "$st_n" -eq 0; then echo "# census_stall: PARITY_STALL_N is 0, not run"; return 0; fi
  census_sysctl stall
  st_c=$(parity_control hfs) && st_hfs=$(census_copy "$st_c" stall-hfs) && st_ext4=$(census_copy "$W/img/ext4.img" stall-ext4) ||
    { echo "# census_stall: no images"; return 1; }
  : >"$OUT/parity/stall.txt"; : >"$OUT/parity/stall-summary.txt"; : >"$OUT/parity/stall-detach.txt"
  da_debug_on
  for st_vol in hfs ext4; do
    eval "st_img=\$st_$st_vol"
    for st_loop in 1 2; do
      st_s=0 st_f=0 st_i=0
      while test "$st_i" -lt "$st_n"; do
        st_i=$((st_i + 1))
        fl_iter "$st_vol" "$st_loop" "$st_i" "$st_img"
        case $? in 1) st_s=$((st_s + 1)) ;; 2) st_f=$((st_f + 1)) ;; esac
      done
      eval "st_s_${st_vol}_$st_loop=$st_s st_a_${st_vol}_$st_loop=$((st_n - st_s - st_f))"
      echo "$st_vol loop $st_loop: $st_s stalls, $((st_n - st_s - st_f)) automounts, $st_f setup failures of $st_n" >>"$OUT/parity/stall-summary.txt"
    done
  done
  da_debug_off stall
  for st_loop in 1 2; do
    eval "st_hs=\$st_s_hfs_$st_loop st_ha=\$st_a_hfs_$st_loop st_es=\$st_s_ext4_$st_loop st_ea=\$st_a_ext4_$st_loop"
    st_p=$(bounded 300 "$PARITY_PYTHON" "$PARITY_LIB/fisher.py" "$st_hs" "$st_ha" "$st_es" "$st_ea" 2>&1 </dev/null)
    if test "$st_loop" = 1; then st_what="ignore, diskutil mount, unignore, eject, plain attach"; else st_what="attach, eject, attach"; fi
    echo "loop $st_loop ($st_what): Fisher p = $st_p (stalls: hfs $st_hs of $((st_hs + st_ha)), ext4 $st_es of $((st_es + st_ea)) attaches set up)" >>"$OUT/parity/stall-summary.txt"
    echo "# recorded stall loop $st_loop: hfs $st_hs/$st_n, ext4 $st_es/$st_n, Fisher p = $st_p"
  done
}

# ---- item 4: busy volumes ----
# census_busy_cycles NAME IMAGE LOG: 20 times, a write and at once diskutil unmount; a busy unmount records who holds
#   the volume (sudo lsof on the mount point, ps, DiskArbitration's dissent), is tried once more, and the volume is
#   mounted again. Prints the busy count.
census_busy_cycles() {
  bc_name=$1 bc_busy=0 bc_k=0
  if test "$1" = hfs; then bc_side=apple; else bc_side=fs; fi
  census_attach "$2" || { echo "$bc_name: not attached" >>"$3"; echo 0; return 1; }
  bc_disk=$CA_DISK bc_dev=$CA_DEV bc_mp=$CA_MP
  while test "$bc_k" -lt 20; do
    bc_k=$((bc_k + 1))
    bc_dal=$(census_dalog_size); : "${bc_dal:=0}"
    bounded 600 dd if=/dev/zero of="$bc_mp/busy-$bc_k" bs=65536 count=16 >/dev/null 2>&1 </dev/null
    if bc_out=$(bounded 600 diskutil unmount "$bc_mp" 2>&1 </dev/null); then
      echo "cycle $bc_k: unmounted: $bc_out" >>"$3"
    else
      bc_busy=$((bc_busy + 1))
      {
        echo "cycle $bc_k: BUSY: $bc_out"
        echo "-- sudo lsof $bc_mp"; bounded 900 sudo -n lsof "$bc_mp" 2>&1 </dev/null
        echo "-- ps (mds, mdworker, fseventsd, Finder)"
        ps -axww -o user=,pid=,command= 2>&1 | grep '[m]ds\|[m]dworker\|[f]seventsd\|[F]inder'
        echo "-- dissenter (DiskArbitration's debug log since the write)"; census_dalog_since "$bc_dal" | grep -i 'dissent'
        census_pause 2
        echo "-- once more: $(bounded 600 diskutil unmount "$bc_mp" 2>&1 </dev/null)"
      } >>"$3" 2>&1
    fi
    bounded 600 diskutil mount "$bc_dev" >/dev/null 2>&1 </dev/null
    if ! bc_m=$(bounded 900 census_wait_mounted "$bc_dev"); then echo "cycle $bc_k: not mounted again; stopping" >>"$3"; break; fi
    bc_mp=$(printf '%s\n' "$bc_m" | sed -n 2p)
  done
  census_detach "$bc_disk" "$bc_side" "$bc_mp" >>"$3"
  echo "$bc_name: busy $bc_busy of 20" >>"$3"
  echo "$bc_busy"
}

# census_busy_up: both volumes of census_busy attached and mounted again, if a step unmounted or ejected one
census_busy_up() {
  if test "$(census_info "$PARITY_CTL_DEV" Mounted)" = Yes && test "$(census_info "$PARITY_FS_DEV" Mounted)" = Yes; then return 0; fi
  census_detach "$(census_image_disk "$cb_h")" apple
  census_detach "$(census_image_disk "$cb_i")" fs "$PARITY_FS_MP" || return 1
  census_attach "$cb_h" || return 1
  bu_hd=$CA_DISK bu_hdev=$CA_DEV bu_hm=$CA_MP bu_hv=$CA_VOL
  census_attach "$cb_i" || return 1
  parity_pair "$bu_hd" "$bu_hm" "$bu_hv" "$cb_fs" "$CA_DISK" "$CA_MP" "$CA_VOL"
  PARITY_CTL_DEV=$bu_hdev PARITY_FS_DEV=$CA_DEV
}

# census_busy_hold shell|textedit MP...: holds MP/held.txt open, in a background shell (exec 3<) or in TextEdit
census_busy_hold() {
  bh_how=$1; shift
  for bh_m; do
    echo held >"$bh_m/held.txt"
    if test "$bh_how" = shell; then
      sh -c 'exec 3< "$1"; exec sleep 300' _ "$bh_m/held.txt" </dev/null >/dev/null 2>&1 &
      CB_HOLDERS="$CB_HOLDERS $!"
    else
      bounded 300 guest-macosx-aqua open -a TextEdit "$bh_m/held.txt" >/dev/null 2>&1 </dev/null
    fi
  done
  census_pause 3
}
census_busy_release() {
  for br_p in $CB_HOLDERS; do kill -9 "$br_p" 2>/dev/null; wait "$br_p" 2>/dev/null; done
  CB_HOLDERS=
  bounded 300 guest-macosx-aqua osascript -e 'tell application "TextEdit" to if it is running then quit saving no' >/dev/null 2>&1 </dev/null
}

# census_finder_eject MP VOL: Finder's eject by AppleScript, its dialog photographed 4 s in; osascript is given 20 s more
census_finder_eject() {
  fe_o=$W/census/finder-eject.out
  guest-macosx-aqua osascript -e "tell application \"Finder\" to eject disk \"$2\"" >"$fe_o" 2>&1 </dev/null &
  fe_p=$!
  sleep 4
  if test "$1" = "$PARITY_CTL_MP"; then census_shot busy-eject hfs; else census_shot busy-eject fs; fi
  fe_k=0; while kill -0 "$fe_p" 2>/dev/null && test "$fe_k" -lt 20; do fe_k=$((fe_k + 1)); sleep 1; done
  if kill -0 "$fe_p" 2>/dev/null; then kill "$fe_p" 2>/dev/null; echo "osascript still waiting 24 s after Finder's eject (its dialog)"; fi
  wait "$fe_p"; fe_rc=$?
  cat "$fe_o"; rm -f "$fe_o"
  return "$fe_rc"
}

# census_busy FS: item 4 on the HFS+ control against FS. (a) census_busy_cycles on each, into busy.FS.cycles.txt.
#   (b) with a file held open (a shell, then TextEdit): diskutil unmount and eject, and Finder's eject (parity_shot
#   busy-eject). diskutil unmount force and Force Eject (unmountDisk force, then eject) run on HFS+ alone unless
#   PARITY_BUSY_FORCE=1: a forced unmount of a busy macFUSE volume runs on the QEMU kit first.
census_busy() {
  cb_fs=$1 CB_HOLDERS=
  census_sysctl "busy-$cb_fs"
  cb_c=$(parity_control hfs) && cb_h=$(census_copy "$cb_c" "busy-hfs-$cb_fs") && cb_i=$(census_copy "$W/img/$cb_fs.img" "busy-$cb_fs") ||
    { echo "# census_busy $cb_fs: no images"; return 1; }
  da_debug_on
  cb_log=$OUT/parity/busy.$cb_fs.cycles.txt; : >"$cb_log"
  cb_bh=$(census_busy_cycles hfs "$cb_h" "$cb_log" | tail -n 1)
  cb_bf=$(census_busy_cycles "$cb_fs" "$cb_i" "$cb_log" | tail -n 1)
  echo "# recorded busy.$cb_fs.cycles: hfs $cb_bh of 20, $cb_fs $cb_bf of 20"
  PARITY_CTL_DEV= PARITY_FS_DEV= PARITY_FS_MP=
  for cb_case in shell:unmount shell:eject textedit:unmount textedit:eject shell:finder-eject; do
    census_busy_up || { echo "# census_busy $cb_fs: cannot attach both volumes again"; break; }
    cb_how=${cb_case%%:*} cb_step=${cb_case#*:}
    census_busy_hold "$cb_how" "$PARITY_CTL_MP" "$PARITY_FS_MP"
    case $cb_step in
    unmount) parity "busy.$cb_fs.$cb_how-unmount" diskutil unmount @MP@ ;;
    eject) parity "busy.$cb_fs.$cb_how-eject" diskutil eject @DISK@ ;;
    finder-eject)
      parity "busy.$cb_fs.finder-eject" census_finder_eject @MP@ @VOL@
      bounded 300 guest-macosx-aqua killall Finder >/dev/null 2>&1 </dev/null; census_pause 6 ;;
    esac
    census_busy_release
  done
  for cb_step in force-unmount force-eject; do
    census_busy_up || break
    if test "${PARITY_BUSY_FORCE:-0}" = 1; then census_busy_hold shell "$PARITY_CTL_MP" "$PARITY_FS_MP"; else census_busy_hold shell "$PARITY_CTL_MP"; fi
    if test "$cb_step" = force-unmount; then set -- diskutil unmount force @MP@; else set -- sh -c 'diskutil unmountDisk force "$1" && diskutil eject "$1"' _ @DISK@; fi
    if test "${PARITY_BUSY_FORCE:-0}" = 1; then parity "busy.$cb_fs.$cb_step" "$@"; else census_hfs_only "busy.$cb_fs.$cb_step" "$@"; fi
    census_busy_release
  done
  census_detach "$(census_image_disk "$cb_h")" apple
  census_detach "$(census_image_disk "$cb_i")" fs "$PARITY_FS_MP"
  da_debug_off "busy-$cb_fs"
}
