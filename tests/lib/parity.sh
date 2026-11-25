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
#   census_spotlight FS                   item 5: read-write HFS+ against FS, then attach -readonly HFS+ against FS
#                                         with ReadOnly on: mdutil -s, an mdfind find (120 s), .Spotlight-V100 and
#                                         .fseventsd, system.log's refusals (each one's uid), who runs mds, mdworker
#                                         and fseventsd, Finder's refresh (read-write only), mdutil -i off kept across
#                                         a remount
#   census_finder FS                      item 6: screenshots (sidebar, getinfo, desktop-on, desktop-off, icon),
#                                         Finder's disk properties against df -k, diskutil info's fields, a custom
#                                         .VolumeIcon.icns
#   census_trash_tags_case FS             item 7: Finder's delete, .Trashes/<uid> and empty trash; a tag and a label
#                                         read back, after a remount too; a 128 KiB xattr; pathconf(_PC_CASE_SENSITIVE)
#                                         against HFS+ and against HFSX (FS apfs, read-only: the pathconf alone)
#   census_later                          Later: Time Machine (isexcluded, its offer) and the exFAT control, against ext4
#   census_before_login MP                item 5 before login: mdutil -s and .fseventsd only
#   parity_census_all                     the controls, then all of it (PARITY_STALL_N 50), within PARITY_CENSUS_MIN
#   Each records sysctl vfs.generic.macfuse once, as $OUT/parity/<census>.sysctl.txt. WHAT prefixes (the items whose
#   PARITY_MODE_ a later task sets): unicode, busy, spotlight, finder, trash, tags, case, later. What cannot be equal on
#   two volumes (pids, times, sizes, volume names) is a plain record, $OUT/parity/<what>.txt, never a parity step.

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

# census_attach IMAGE [nomount|readonly]: attaches (readonly: hdiutil attach -readonly); sets CA_DISK (the whole disk)
#   and CA_NODES (every node), and unless nomount waits for the mount: CA_DEV, CA_MP, CA_VOL. On failure says why and
#   detaches what it attached.
census_attach() {
  CA_DISK= CA_NODES= CA_DEV= CA_MP= CA_VOL=
  case ${2:-} in nomount) _ca_o=-nomount ;; readonly) _ca_o=-readonly ;; *) _ca_o= ;; esac
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

# census_shot STEP SIDE: parity_shot for one side, bounded. HFS+'s side of a step is taken once: the control is the same
#   for every filesystem, and a later census would overwrite it.
census_shot() {
  test "$2" != hfs || test ! -f "$OUT/hfs-$1.png" || return 0
  parity_side "$2"; bounded 300 parity_shot "$1" >/dev/null 2>&1
}

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
#   on ext4, each iteration begun only while census_due (one out of time stops the rest, and the counts say how many
#   ran); stall.txt has a line per iteration (the verdict and each probe's time), stall-summary.txt the counts and
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
      st_s=0 st_f=0 st_i=0 st_cut=
      while test "$st_i" -lt "$st_n"; do
        if ! st_due=$(census_due "stall $st_vol loop $st_loop from iteration $((st_i + 1)) of $st_n"); then
          printf '%s\n' "$st_due" | tee -a "$OUT/parity/stall-summary.txt"; st_cut=1; break
        fi
        st_i=$((st_i + 1))
        fl_iter "$st_vol" "$st_loop" "$st_i" "$st_img"
        case $? in 1) st_s=$((st_s + 1)) ;; 2) st_f=$((st_f + 1)) ;; esac
      done
      eval "st_s_${st_vol}_$st_loop=$st_s st_a_${st_vol}_$st_loop=$((st_i - st_s - st_f)) st_r_${st_vol}_$st_loop=$st_i"
      echo "$st_vol loop $st_loop: $st_s stalls, $((st_i - st_s - st_f)) automounts, $st_f setup failures of $st_i${st_cut:+ (stopped early, out of time: $st_n asked)}" >>"$OUT/parity/stall-summary.txt"
    done
  done
  da_debug_off stall
  for st_loop in 1 2; do
    eval "st_hs=\$st_s_hfs_$st_loop st_ha=\$st_a_hfs_$st_loop st_es=\$st_s_ext4_$st_loop st_ea=\$st_a_ext4_$st_loop st_hr=\$st_r_hfs_$st_loop st_er=\$st_r_ext4_$st_loop"
    st_p=$(bounded 300 "$PARITY_PYTHON" "$PARITY_LIB/fisher.py" "$st_hs" "$st_ha" "$st_es" "$st_ea" 2>&1 </dev/null)
    if test "$st_loop" = 1; then st_what="ignore, diskutil mount, unignore, eject, plain attach"; else st_what="attach, eject, attach"; fi
    echo "loop $st_loop ($st_what): Fisher p = $st_p (stalls: hfs $st_hs of $((st_hs + st_ha)), ext4 $st_es of $((st_es + st_ea)) attaches set up)" >>"$OUT/parity/stall-summary.txt"
    echo "# recorded stall loop $st_loop: hfs $st_hs/$st_hr, ext4 $st_es/$st_er, Fisher p = $st_p"
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

# census_finder_ask STEP MP SCRIPT: SCRIPT by osascript in the console session, in the background; MP's side is
#   photographed 4 s in (STEP), and osascript is given 20 s more: one still waiting is held by a dialog, and is said
#   and stopped. Run it under bounded (parity does).
census_finder_ask() {
  fe_o=$W/census/finder-ask.out
  mkdir -p "$W/census"
  guest-macosx-aqua osascript -e "$3" >"$fe_o" 2>&1 </dev/null &
  fe_p=$!
  sleep 4
  if test "$2" = "$PARITY_CTL_MP"; then census_shot "$1" hfs; else census_shot "$1" fs; fi
  fe_k=0; while kill -0 "$fe_p" 2>/dev/null && test "$fe_k" -lt 20; do fe_k=$((fe_k + 1)); sleep 1; done
  if kill -0 "$fe_p" 2>/dev/null; then kill "$fe_p" 2>/dev/null; echo "osascript still waiting 24 s after Finder's $1 (its dialog)"; fi
  wait "$fe_p"; fe_rc=$?
  cat "$fe_o"; rm -f "$fe_o"
  return "$fe_rc"
}

# census_finder_eject MP VOL: Finder's eject by AppleScript, its dialog photographed (busy-eject)
census_finder_eject() { census_finder_ask busy-eject "$1" "tell application \"Finder\" to eject disk \"$2\""; }

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

# ---- the census's shared steps for items 5 to 7 and Later ----
PARITY_SYSLOG=${PARITY_SYSLOG:-/var/log/system.log}
PARITY_SPOT_SECS=${PARITY_SPOT_SECS:-120}   # census_mdfind: once a second; the tests wait less
PARITY_ICNS=${PARITY_ICNS:-/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns}
# The guest job has 180 min. Before the smoke: the VM's boot and the installs, about 5. The census begins nothing after
#   PARITY_CENSUS_MIN = 140 min from the smoke's start (PARITY_T0, which the smoke sets first): then at most the census
#   step already begun (about 10: spotlight's two 120 s mdfind waits and remounts, or one stall iteration), before
#   login (about 5) and the copyback and uploads (about 5) remain: 5 + 140 + 10 + 5 + 5 = 165, leaving 15 to spare.
PARITY_CENSUS_MIN=${PARITY_CENSUS_MIN:-140}

# census_pair_up CTL-IMAGE FS-IMAGE FS [readonly]: attaches both (the control -readonly when readonly) and makes them
#   the pair; 1 when either fails, with what did attach ejected
census_pair_up() {
  census_attach "$1" ${4:-} || return 1
  _cp_hd=$CA_DISK _cp_hm=$CA_MP _cp_hv=$CA_VOL
  census_attach "$2" || { census_detach "$_cp_hd" apple; return 1; }
  parity_pair "$_cp_hd" "$_cp_hm" "$_cp_hv" "$3" "$CA_DISK" "$CA_MP" "$CA_VOL"
}
# census_pair_down: the pair ejected (the control as Apple's, the other as linuxfs's); 1 when the latter is left attached
census_pair_down() {
  census_detach "$PARITY_FS_DISK" fs "$PARITY_FS_MP"; _cpd_rc=$?
  census_detach "$PARITY_CTL_DISK" apple
  return "$_cpd_rc"
}
# census_remount_pair CTL-IMAGE FS-IMAGE [readonly]: the pair ejected and attached again
census_remount_pair() {
  census_pair_down || { echo "# census: $PARITY_FS_DISK is still attached, so no remount"; return 1; }
  census_pair_up "$1" "$2" "$PARITY_FS" ${3:-}
}
# census_both CMD...: CMD once with each volume of the pair's mount point as its last argument, each output headed
census_both() { for _cb_m in "$PARITY_CTL_MP" "$PARITY_FS_MP"; do echo "== $_cb_m"; "$@" "$_cb_m" 2>&1; done; }
# census_bound TENTHS CMD...: CMD with PARITY_BOUND set to TENTHS, PARITY_BOUND then as it was
census_bound() {
  _cbd_old=${PARITY_BOUND-unset}; PARITY_BOUND=$1; shift
  "$@"; _cbd_rc=$?
  if test "$_cbd_old" = unset; then unset PARITY_BOUND; else PARITY_BOUND=$_cbd_old; fi
  return "$_cbd_rc"
}
# census_osa LINE...: an AppleScript in the console session, bounded, its output dropped
census_osa() {
  _co_n=$#
  while test "$_co_n" -gt 0; do set -- "$@" -e "$1"; shift; _co_n=$((_co_n - 1)); done
  bounded 300 guest-macosx-aqua osascript "$@" >/dev/null 2>&1 </dev/null
}
census_finder_restart() { bounded 300 guest-macosx-aqua killall Finder >/dev/null 2>&1 </dev/null; census_pause 6; }
census_log_lines() { wc -l <"$PARITY_SYSLOG" 2>/dev/null | tr -d ' '; }
census_log_since() { tail -n +"$((${1:-0} + 1))" "$PARITY_SYSLOG" 2>/dev/null; }
census_refusal_re='Operation not permitted|Permission denied|EPERM|EACCES'

# ---- item 5: Spotlight and fsevents ----
# census_mdfind MP NAME SECONDS-FILE: up to PARITY_SPOT_SECS s (by the clock; each mdfind bounded at 10 s) for
#   mdfind -onlyin MP to find NAME; the seconds it took go
#   to SECONDS-FILE (they differ between volumes)
census_mdfind() {
  _cm_t0=$(date +%s)
  while :; do
    _cm_f=$(bounded 100 mdfind -onlyin "$1" -name "$2" 2>&1 </dev/null)
    _cm_k=$(($(date +%s) - _cm_t0))
    if test -n "$_cm_f"; then echo "found: $_cm_f"; echo "$1: found after $_cm_k s" >>"$3"; return 0; fi
    test "$_cm_k" -lt "$PARITY_SPOT_SECS" || break
    sleep 1
  done
  echo "not found within $PARITY_SPOT_SECS s"; echo "$1: not found within $PARITY_SPOT_SECS s" >>"$3"; return 1
}
# census_dirs MP NAME...: whether each MP/NAME exists
census_dirs() { _cd_m=$1; shift; for _cd_n; do if test -e "$_cd_m/$_cd_n"; then echo "$_cd_n: yes"; else echo "$_cd_n: no"; fi; done; }
# census_refusals LINE MP: system.log's refusals after line LINE that name MP
census_refusals() { census_log_since "$1" | grep -E "$census_refusal_re" | grep -F -- "$2"; return 0; }
# census_refusal_uids: filter: each line, then the uid and user of the process it names (name[pid]:), while it runs
census_refusal_uids() {
  while IFS= read -r _cr_l; do
    printf '%s\n' "$_cr_l"
    _cr_p=$(printf '%s\n' "$_cr_l" | sed -n 's/^[^[]*[A-Za-z0-9_.]\[\([0-9][0-9]*\)\]:.*/\1/p')
    test -n "$_cr_p" || continue
    _cr_u=$(ps -o uid=,user= -p "$_cr_p" 2>/dev/null | sed 's/^ *//; s/  */ /g')
    echo "#   pid $_cr_p: uid ${_cr_u:-unknown (it has exited)}"
  done
}
# census_md_users: the user, uid, pid and command of every mds, mds_stores, mdworker, mdflagwriter and fseventsd
census_md_users() {
  ps -axww -o user=,uid=,pid=,command= 2>/dev/null |
    awk '{ c = $4; sub(/.*\//, "", c) } c == "mds" || c == "mds_stores" || c == "mdworker" || c == "mdflagwriter" || c == "fseventsd"'
}
# census_refresh MP: a Finder window on MP/refresh (made empty), a file made there from the shell, 3 s, then Finder's
#   count of its items and a screenshot (refresh)
census_refresh() {
  rm -rf "$1/refresh"; mkdir "$1/refresh" || return 1
  census_osa "tell application \"Finder\" to open (POSIX file \"$1/refresh\" as alias)"
  sleep 3
  echo new >"$1/refresh/new.txt" || return 1
  sleep 3
  bounded 300 guest-macosx-aqua osascript -e 'tell application "Finder" to count items of (target of front Finder window)' 2>&1 </dev/null; _crf_rc=$?
  if test "$1" = "$PARITY_CTL_MP"; then census_shot refresh hfs; else census_shot refresh fs; fi
  census_osa 'tell application "Finder" to close every window'
  return "$_crf_rc"
}
# census_privacy_shot STEP: the Spotlight pane's Privacy tab, photographed for both sides (it lists every volume)
census_privacy_shot() {
  census_osa 'tell application "System Preferences"' 'activate' 'reveal anchor "privacy" of pane id "com.apple.preference.spotlight"' 'end tell'
  census_pause 3
  census_shot "$1" hfs; census_shot "$1" fs
  census_osa 'tell application "System Preferences" to quit'
}

# census_spotlight_steps FS PASS NAME LINE: item 5's steps on the current pair; NAME is the file mdfind looks for, LINE
#   system.log's length at the attach
census_spotlight_steps() {
  _ss_t=spotlight.$1.$2
  parity "$_ss_t.mdutil" mdutil -s @MP@
  census_bound $((PARITY_SPOT_SECS * 10 + 400)) parity "$_ss_t.mdfind" census_mdfind @MP@ "$3" "$OUT/parity/$_ss_t.mdfind-seconds.txt"
  parity "$_ss_t.dirs" census_dirs @MP@ .Spotlight-V100 .fseventsd
  parity "$_ss_t.refusals" census_refusals "$4" @MP@
  census_log_since "$4" | grep -E "$census_refusal_re" | census_refusal_uids >"$OUT/parity/$_ss_t.refusals-all.txt"
  census_md_users >"$OUT/parity/$_ss_t.processes.txt"
  for _ss_m in "$PARITY_CTL_MP" "$PARITY_FS_MP"; do echo "== sudo lsof $_ss_m"; bounded 900 sudo -n lsof "$_ss_m" 2>&1 </dev/null; done >"$OUT/parity/$_ss_t.lsof.txt"
}

# census_spotlight FS: item 5, twice on fresh copies: read-write HFS+ against FS; then attach -readonly HFS+ against FS
#   with ReadOnly on (the file mdfind looks for is made first, read-write). Each pass records census_spotlight_steps,
#   Finder's refresh (read-write only), then sudo mdutil -i off, a remount, mdutil -s and the Privacy pane.
census_spotlight() {
  sp_fs=$1
  census_sysctl "spotlight-$sp_fs"
  sp_c=$(parity_control hfs) || { echo "# census_spotlight $sp_fs: no HFS+ control"; return 1; }
  for sp_pass in rw ro; do
    sp_h=$(census_copy "$sp_c" "spotlight-hfs-$sp_fs-$sp_pass") && sp_i=$(census_copy "$W/img/$sp_fs.img" "spotlight-$sp_fs-$sp_pass") ||
      { echo "# census_spotlight $sp_fs: no images"; return 1; }
    sp_name=parity-spot-$$-$sp_pass sp_ro=
    if test "$sp_pass" = ro; then
      census_pair_up "$sp_h" "$sp_i" "$sp_fs" || { echo "# census_spotlight $sp_fs ro: cannot attach both to make the file"; continue; }
      echo spot >"$PARITY_CTL_MP/$sp_name"; echo spot >"$PARITY_FS_MP/$sp_name"
      census_pair_down || { echo "# census_spotlight $sp_fs ro: $PARITY_FS_DISK is still attached"; continue; }
      bounded 600 "$L" prefs ReadOnly on </dev/null; sp_ro=readonly
    fi
    sp_log=$(census_log_lines)
    if census_pair_up "$sp_h" "$sp_i" "$sp_fs" $sp_ro; then
      test "$sp_pass" = ro || parity "spotlight.$sp_fs.rw.create" sh -c 'echo spot > "$1/$2"' _ @MP@ "$sp_name"
      census_spotlight_steps "$sp_fs" "$sp_pass" "$sp_name" "${sp_log:-0}"
      # census_refresh's worst: four 30 s bounds (open, count, shot, close) and 6 s of pauses
      test "$sp_pass" = ro || census_bound 1500 parity "spotlight.$sp_fs.rw.refresh" census_refresh @MP@
      parity "spotlight.$sp_fs.$sp_pass.privacy-off" sudo -n mdutil -i off @MP@
      if census_remount_pair "$sp_h" "$sp_i" $sp_ro; then
        parity "spotlight.$sp_fs.$sp_pass.privacy-remount" mdutil -s @MP@
        if test "$sp_pass" = rw; then census_privacy_shot privacy; else census_privacy_shot privacy-ro; fi
        census_pair_down
      fi
    else echo "# census_spotlight $sp_fs $sp_pass: cannot attach both volumes"; fi
    test "$sp_pass" = rw || bounded 600 "$L" prefs ReadOnly off </dev/null
  done
}

# census_before_login MP: before login, mdutil -s and .fseventsd for the mount at MP (record-only), into
#   $OUT/parity/spotlight.before-login.txt
census_before_login() {
  mkdir -p "$OUT/parity" || return 1
  {
    echo "== mdutil -s"; bounded 300 mdutil -s "$1" 2>&1 </dev/null; echo "== status $?"
    if bounded 100 test -e "$1/.fseventsd"; then echo ".fseventsd: yes"; else echo ".fseventsd: no"; fi
  } | parity_norm "$1" "" >"$OUT/parity/spotlight.before-login.txt"
  echo "# recorded spotlight.before-login: $(tr '\n' ' ' <"$OUT/parity/spotlight.before-login.txt")"
}

# ---- item 6: Finder presentation ----
# census_finder_props MP RAW-FILE: Finder's ejectable, local volume and ignore privileges, and whether its capacity and
#   free space match df -k's; the raw values (and format) are appended to RAW-FILE
census_finder_props() {
  _fp_o=$(guest-macosx-aqua osascript -e 'tell application "Finder"' -e "set d to disk of (POSIX file \"$1\" as alias)" \
    -e 'set o to {ejectable of d, local volume of d, ignore privileges of d, capacity of d, free space of d, format of d}' \
    -e 'end tell' -e "set AppleScript's text item delimiters to \"|\"" -e 'return o as text' 2>&1 </dev/null); _fp_rc=$?
  _fp_df=$(df -P -k "$1" 2>&1 | awk 'NR == 2 { print $2, $4 }')
  { echo "== $1"; echo "Finder (ejectable|local volume|ignore privileges|capacity|free space|format): $_fp_o"; echo "df -k (size, available): $_fp_df"; } >>"$2"
  if test "$_fp_rc" -ne 0; then echo "Finder: $_fp_o"; return "$_fp_rc"; fi
  printf '%s\n' "$_fp_o" | awk -F'|' -v df="$_fp_df" '{
    n = split(df, k, " "); c = $4 + 0; f = $5 + 0
    print "ejectable: " $1; print "local volume: " $2; print "ignore privileges: " $3
    d = c - k[1] * 1024; if (d < 0) d = -d; print "capacity equals df -k size (within 1 KiB): " (n == 2 && d < 1024 ? "yes" : "no")
    d = f - k[2] * 1024; if (d < 0) d = -d; print "free space equals df -k available (within 1 MiB): " (n == 2 && d < 1048576 ? "yes" : "no")
  }'
}
# census_du_fields MP: diskutil info's Ejectable, Removable Media, Internal and Device Location
census_du_fields() { diskutil info "$1" 2>&1 </dev/null | grep -E '^ *(Ejectable|Removable Media|Internal|Device Location):' | sed 's/^ *//; s/:  */: /'; }
# FinderInfo with kHasCustomIcon (0x0400) in fdFlags, bytes 8 and 9 of the 32
census_finderinfo_icon=0000000000000000040000000000000000000000000000000000000000000000
# census_volume_icon MP: PARITY_ICNS as MP/.VolumeIcon.icns, and the root's FinderInfo custom-icon flag set, read back
census_volume_icon() {
  cp "$PARITY_ICNS" "$1/.VolumeIcon.icns" && xattr -wx com.apple.FinderInfo "$census_finderinfo_icon" "$1"; _vi_rc=$?
  echo "cp .VolumeIcon.icns and xattr -wx com.apple.FinderInfo: exit $_vi_rc"
  echo "FinderInfo: $(xattr -px com.apple.FinderInfo "$1" 2>&1 | tr -s ' \n' '  ')"
  return "$_vi_rc"
}
# census_finder_view SIDE STEP open|info: a Finder window (open) or Get Info window (info) on SIDE's volume, 3 s, the
#   screenshot STEP, and every window closed
census_finder_view() {
  if test "$1" = hfs; then _fv_m=$PARITY_CTL_MP; else _fv_m=$PARITY_FS_MP; fi
  if test "$3" = info; then _fv_v="open information window of (disk of (POSIX file \"$_fv_m\" as alias))"
  else _fv_v="open (POSIX file \"$_fv_m\" as alias)"; fi
  census_osa 'tell application "Finder"' 'activate' "$_fv_v" 'end tell'
  census_pause 3
  census_shot "$2" "$1"
  census_osa 'tell application "Finder" to close every window'
}
# census_desktop true|false STEP: ShowExternalHardDrivesOnDesktop set, Finder restarted, the Desktop photographed
census_desktop() {
  bounded 300 guest-macosx-aqua defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool "$1" >/dev/null 2>&1 </dev/null
  census_finder_restart
  census_shot "$2" hfs; census_shot "$2" fs
}

# census_finder FS: item 6 on the HFS+ control against FS: the sidebar and Get Info, photographed for each; Finder's
#   properties against df -k (raw values in finder.FS.raw.txt); diskutil info's fields; a custom .VolumeIcon.icns
#   (Get Info photographed as icon); the Desktop with external disks shown and hidden. ShowExternalHardDrivesOnDesktop
#   is put back as it was.
census_finder() {
  cf_fs=$1
  census_sysctl "finder-$cf_fs"
  cf_c=$(parity_control hfs) && cf_h=$(census_copy "$cf_c" "finder-hfs-$cf_fs") && cf_i=$(census_copy "$W/img/$cf_fs.img" "finder-$cf_fs") ||
    { echo "# census_finder $cf_fs: no images"; return 1; }
  census_pair_up "$cf_h" "$cf_i" "$cf_fs" || { echo "# census_finder $cf_fs: cannot attach both volumes"; return 1; }
  cf_old=$(bounded 300 guest-macosx-aqua defaults read com.apple.finder ShowExternalHardDrivesOnDesktop 2>/dev/null </dev/null)
  for cf_s in hfs fs; do census_finder_view "$cf_s" sidebar open; done
  : >"$OUT/parity/finder.$cf_fs.raw.txt"
  parity "finder.$cf_fs.properties" census_finder_props @MP@ "$OUT/parity/finder.$cf_fs.raw.txt"
  parity "finder.$cf_fs.diskutil-info" census_du_fields @MP@
  for cf_s in hfs fs; do census_finder_view "$cf_s" getinfo info; done
  parity "finder.$cf_fs.volumeicon" census_volume_icon @MP@
  census_desktop true desktop-on
  for cf_s in hfs fs; do census_finder_view "$cf_s" icon info; done
  census_desktop false desktop-off
  case $cf_old in
  1) set -- write com.apple.finder ShowExternalHardDrivesOnDesktop -bool true ;;
  0) set -- write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false ;;
  *) set -- delete com.apple.finder ShowExternalHardDrivesOnDesktop ;;
  esac
  bounded 300 guest-macosx-aqua defaults "$@" >/dev/null 2>&1 </dev/null
  census_finder_restart
  census_pair_down
}

# ---- item 7: Trash, tags and labels, case-sensitivity ----
# census_trash_delete MP: MP/trash-me made, then deleted by Finder (census_finder_ask: a "delete immediately?" dialog
#   leaves osascript waiting, photographed as trash-delete)
census_trash_delete() {
  echo trash >"$1/trash-me" || return 1
  census_finder_ask trash-delete "$1" "tell application \"Finder\" to delete (POSIX file \"$1/trash-me\" as alias)"
}
# census_trashes MP UID: .Trashes and .Trashes/UID: mode, owner and group, then what the latter holds
census_trashes() {
  for _ct_p in "$1/.Trashes" "$1/.Trashes/$2"; do
    if test -e "$_ct_p"; then stat -f '%N %Sp %u:%g' "$_ct_p" 2>&1; else echo "$_ct_p: absent"; fi
  done
  echo "-- in .Trashes/$2:"; ls -A "$1/.Trashes/$2" 2>&1
  return 0
}
# a binary plist of the one-tag array ("Parity"), as com.apple.metadata:_kMDItemUserTags holds it (plutil -convert binary1)
census_tag_plist=62706c6973743030a10156506172697479080a0000000000000101000000000000000200000000000000000000000000000011
# census_tag_set MP: MP/tagged made, given the tag by xattr -wx and the label red (label index 2) by Finder
census_tag_set() {
  echo tagged >"$1/tagged" || return 1
  xattr -wx com.apple.metadata:_kMDItemUserTags "$census_tag_plist" "$1/tagged" 2>&1; echo "tag (xattr -wx): exit $?"
  guest-macosx-aqua osascript -e "tell application \"Finder\" to set label index of (POSIX file \"$1/tagged\" as alias) to 2" 2>&1 </dev/null
  echo "label (Finder): exit $?"
}
# census_xattr_big MP: xattr writes of 128 KiB, and of 128 KiB and a byte, to MP/big-xattr: each one's error and status
census_xattr_big() {
  echo big >"$1/big-xattr" || return 1
  for _xb_n in 131072 131073; do
    xattr -w user.parity-big "$("$PARITY_PYTHON" -c "import sys; sys.stdout.write('x' * $_xb_n)")" "$1/big-xattr" 2>&1
    echo "$_xb_n bytes: exit $?"
  done
}
census_py_pathconf='import os, sys
try:
    print("pathconf(_PC_CASE_SENSITIVE) = %d" % os.pathconf(sys.argv[1], 11))
except (IOError, OSError) as e:
    print("errno " + str(e.errno))'

# census_trash_tags_case FS: item 7 on the HFS+ control against FS. Trash: Finder's delete (trash-delete photographed),
#   .Trashes/<uid>, then empty trash (once: it empties every volume; trash.FS.empty-trash.txt) and what is left. Tags: a
#   tag and a label, xattr -l, again after a remount, and the oversized xattr. Case: pathconf against HFS+ (case.FS.pathconf)
#   and against HFSX (case.FS.pathconf-hfsx, whose .hfs.txt is HFSX's). APFS is read-only: the case step alone.
census_trash_tags_case() {
  tt_fs=$1 tt_uid=$(id -u)
  census_sysctl "trash-$tt_fs"
  tt_c=$(parity_control hfs) && tt_cx=$(parity_control hfsx) && tt_h=$(census_copy "$tt_c" "trash-hfs-$tt_fs") &&
    tt_x=$(census_copy "$tt_cx" "trash-hfsx-$tt_fs") && tt_i=$(census_copy "$W/img/$tt_fs.img" "trash-$tt_fs") ||
    { echo "# census_trash_tags_case $tt_fs: no images"; return 1; }
  census_pair_up "$tt_h" "$tt_i" "$tt_fs" || { echo "# census_trash_tags_case $tt_fs: cannot attach both volumes"; return 1; }
  if test "$tt_fs" = apfs; then
    echo "# census_trash_tags_case apfs: read-only, so the case step alone"
  else
    # census_finder_ask's worst: 4 s, a 30 s shot, 20 s, and the rest
    census_bound 900 parity "trash.$tt_fs.finder-delete" census_trash_delete @MP@
    if grep -q '^osascript still waiting' "$OUT/parity/trash.$tt_fs.finder-delete.hfs.txt" "$OUT/parity/trash.$tt_fs.finder-delete.$tt_fs.txt"; then
      census_finder_restart   # a dialog was left up
    fi
    parity "trash.$tt_fs.trashes" census_trashes @MP@ "$tt_uid"
    tt_warn=$(bounded 300 guest-macosx-aqua osascript -e 'tell application "Finder" to get warns before emptying of trash' 2>/dev/null </dev/null)
    bounded 900 census_finder_ask trash-empty "$PARITY_CTL_MP" \
      'tell application "Finder"
set warns before emptying of trash to false
empty trash
end tell' >"$OUT/parity/trash.$tt_fs.empty-trash.txt" 2>&1
    echo "== status $?" >>"$OUT/parity/trash.$tt_fs.empty-trash.txt"
    grep -q '^osascript still waiting' "$OUT/parity/trash.$tt_fs.empty-trash.txt" && census_finder_restart
    case $tt_warn in true|false) census_osa "tell application \"Finder\" to set warns before emptying of trash to $tt_warn" ;; esac
    parity "trash.$tt_fs.after-empty" census_trashes @MP@ "$tt_uid"
    parity "tags.$tt_fs.set" census_tag_set @MP@
    parity "tags.$tt_fs.read" xattr -l @MP@/tagged
    parity "tags.$tt_fs.oversized" census_xattr_big @MP@
    if census_remount_pair "$tt_h" "$tt_i"; then
      parity "tags.$tt_fs.after-remount" xattr -l @MP@/tagged
    else
      echo "# census_trash_tags_case $tt_fs: no remount, so no tags read after one"
      tt_live=$(census_image_disk "$tt_i")
      if test -n "$tt_live" && { test "$tt_live" != "$PARITY_FS_DISK" || test "$(census_info "$PARITY_FS_MP" "Mount Point")" != "$PARITY_FS_MP"; }; then
        # a new attach that never mounted, and could not be detached: no live linuxfs mount to ask
        echo "# census_trash_tags_case $tt_fs: $tt_live is attached but not mounted as the pair's volume, so no case step"; return 1
      elif test -n "$tt_live"; then   # its eject failed: it is still mounted; the control comes back
        census_attach "$tt_h" || { echo "# census_trash_tags_case $tt_fs: no HFS+ control again, so no case step"; return 1; }
        parity_pair "$CA_DISK" "$CA_MP" "$CA_VOL" "$tt_fs" "$PARITY_FS_DISK" "$PARITY_FS_MP" "$PARITY_FS_VOL"
      else
        census_pair_up "$tt_h" "$tt_i" "$tt_fs" || { echo "# census_trash_tags_case $tt_fs: cannot attach both again, so no case step"; return 1; }
      fi
    fi
  fi
  parity "case.$tt_fs.pathconf" "$PARITY_PYTHON" -c "$census_py_pathconf" @MP@
  tt_hd=$PARITY_CTL_DISK tt_hm=$PARITY_CTL_MP tt_hv=$PARITY_CTL_VOL
  if census_attach "$tt_x"; then
    parity_pair "$CA_DISK" "$CA_MP" "$CA_VOL" "$tt_fs" "$PARITY_FS_DISK" "$PARITY_FS_MP" "$PARITY_FS_VOL"
    parity "case.$tt_fs.pathconf-hfsx" "$PARITY_PYTHON" -c "$census_py_pathconf" @MP@
    census_detach "$CA_DISK" apple
    parity_pair "$tt_hd" "$tt_hm" "$tt_hv" "$tt_fs" "$PARITY_FS_DISK" "$PARITY_FS_MP" "$PARITY_FS_VOL"
  else echo "# census_trash_tags_case $tt_fs: no HFSX control attached"; fi
  census_pair_down
}

# ---- Later: Time Machine (record-only, never checked) ----
# census_later: Later's Time Machine record: the HFS+ control beside the exFAT control (later.exfat.*), then beside
#   ext4 (later.ext4.*): tmutil isexcluded, and Time Machine's offer photographed 5 s after each attach (tm-offer).
#   No destination is ever set: that would replace the guest's, and backupd could remount a macFUSE volume (QEMU first).
census_later() {
  census_sysctl later
  cl_c=$(parity_control hfs) && cl_cx=$(parity_control exfat) && cl_h=$(census_copy "$cl_c" later-hfs) &&
    cl_x=$(census_copy "$cl_cx" later-exfat) && cl_i=$(census_copy "$W/img/ext4.img" later-ext4) ||
    { echo "# census_later: no images"; return 1; }
  census_attach "$cl_h" || { echo "# census_later: no HFS+ control attached"; return 1; }
  cl_hd=$CA_DISK cl_hm=$CA_MP cl_hv=$CA_VOL
  census_pause 5; census_shot tm-offer hfs
  for cl_k in exfat ext4; do
    if test "$cl_k" = exfat; then cl_img=$cl_x cl_side=apple; else cl_img=$cl_i cl_side=fs; fi
    census_attach "$cl_img" || { echo "# census_later: no $cl_k attached"; continue; }
    parity_pair "$cl_hd" "$cl_hm" "$cl_hv" "$cl_k" "$CA_DISK" "$CA_MP" "$CA_VOL"
    census_pause 5; census_shot tm-offer fs
    parity "later.$cl_k.tm-excluded" tmutil isexcluded @MP@
    census_detach "$PARITY_FS_DISK" "$cl_side" "$PARITY_FS_MP"
  done
  census_detach "$cl_hd" apple
}

# ---- all of it ----
# census_due WHAT...: true while within PARITY_CENSUS_MIN minutes of CA_T0 (the smoke's start; with no CA_T0, always);
#   else it says it skips WHAT. A census step is never cut short: the guest job's timeout would lose every record, the
#   smoke's too.
census_due() {
  test -n "${CA_T0:-}" || return 0
  test $(($(date +%s) - CA_T0)) -lt $((PARITY_CENSUS_MIN * 60)) && return 0
  echo "# census: out of time ($PARITY_CENSUS_MIN min), skipped: $*"; return 1
}
# census_on FS CMD...: CMD, when there is time and FS's image ($W/img/FS.img); NTFS with NTFSTakeover on, so linuxfs
#   mounts it rather than Apple's ntfs, and put back as it was after
census_on() {
  census_due "$2" "$1" || return 1
  test -f "$W/img/$1.img" || { echo "# census: no $W/img/$1.img, so no $2 $1"; return 1; }
  _con_fs=$1; shift
  if test "$_con_fs" = ntfs; then
    _con_old=$(bounded 300 defaults read dev.mavergreen.linuxfs NTFSTakeover 2>/dev/null </dev/null)
    bounded 300 defaults write dev.mavergreen.linuxfs NTFSTakeover -bool true >/dev/null 2>&1 </dev/null
  fi
  "$@"; _con_rc=$?
  if test "$_con_fs" = ntfs; then   # as it was
    case $_con_old in
    1) set -- write dev.mavergreen.linuxfs NTFSTakeover -bool true ;;
    0) set -- write dev.mavergreen.linuxfs NTFSTakeover -bool false ;;
    *) set -- delete dev.mavergreen.linuxfs NTFSTakeover ;;
    esac
    bounded 300 defaults "$@" >/dev/null 2>&1 </dev/null
  fi
  census_clean
  return "$_con_rc"
}
# census_info_ok TEXT: TEXT is hdiutil info's own answer (its framework and driver lines head it)
census_info_ok() { printf '%s\n' "$1" | grep -q '^framework *:' && printf '%s\n' "$1" | grep -q '^driver *:'; }
# census_clean: the census's copies no longer attached removed (each is up to 320 MB, on the guest's own disk)
#   (nothing, when hdiutil info fails or does not answer as itself)
census_clean() {
  _ccl_i=$(bounded 600 hdiutil info 2>/dev/null </dev/null) && census_info_ok "$_ccl_i" || { echo "# census: hdiutil info failed, so no copy is removed"; return 1; }
  _ccl_att=$(printf '%s\n' "$_ccl_i" | awk '/^image-path/ { sub(/^image-path[ \t]*:[ \t]*/, ""); print }')
  for _ccl_f in "$W"/census/*.img; do
    test -f "$_ccl_f" || continue
    printf '%s\n' "$_ccl_att" | grep -qxF -- "$_ccl_f" || rm -f "$_ccl_f"
  done
}
# census_left_attached: every census or control image still attached (a linuxfs disk whose eject failed is never
#   detached by force), into $OUT/parity/census-left-attached.txt ("none" when none is) and said
census_left_attached() {
  mkdir -p "$OUT/parity" || return 1
  _cla_i=$(bounded 600 hdiutil info 2>/dev/null </dev/null) && census_info_ok "$_cla_i" ||
    { echo "unknown: hdiutil info failed" >"$OUT/parity/census-left-attached.txt"; echo "# census: hdiutil info failed, so what is left attached is unknown"; return 1; }
  _cla=$(printf '%s\n' "$_cla_i" | awk -v c="$W/census/" -v k="$W/ctl/" '
    /^image-path/ { p = $0; sub(/^image-path[ \t]*:[ \t]*/, "", p); cur = (index(p, c) == 1 || index(p, k) == 1); next }
    cur && /^\/dev\/disk[0-9]+[ \t]/ { print $1 " " p; cur = 0 }')
  if test -z "$_cla"; then echo none >"$OUT/parity/census-left-attached.txt"; echo "# census: no census disk is left attached"; return 0; fi
  printf '%s\n' "$_cla" >"$OUT/parity/census-left-attached.txt"
  echo "# census: left attached (not detached by force): $(printf '%s\n' "$_cla" | tr '\n' ' ')"
}

# parity_census_all: the census, record-only: the four controls made, then item 3 (PARITY_STALL_N, 50 unless set; first,
#   as the longest), items 1 and 7 on ext4, btrfs, xfs, f2fs and NTFS, items 4 and 5 on ext4, item 6 on those and APFS,
#   item 7's case step on APFS too, then Later. Nothing is begun past PARITY_CENSUS_MIN (140) minutes from the smoke's
#   start (PARITY_T0; the census's own start without it).
parity_census_all() {
  : "${PARITY_STALL_N:=50}"
  CA_T0=${PARITY_T0:-$(date +%s)}
  for ca_k in hfs hfsx fat32 exfat; do parity_control "$ca_k" >/dev/null || echo "# census: cannot make the $ca_k control"; done
  census_due census_stall && { census_stall; census_clean; }
  for ca_fs in ext4 btrfs xfs f2fs ntfs; do census_on "$ca_fs" census_unicode "$ca_fs"; done
  census_on ext4 census_busy ext4
  census_on ext4 census_spotlight ext4
  for ca_fs in ext4 btrfs xfs f2fs ntfs apfs; do census_on "$ca_fs" census_finder "$ca_fs"; done
  for ca_fs in ext4 btrfs xfs f2fs ntfs apfs; do census_on "$ca_fs" census_trash_tags_case "$ca_fs"; done
  census_due census_later && { census_later; census_clean; }
  census_left_attached
}
