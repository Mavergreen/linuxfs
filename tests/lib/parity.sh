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
