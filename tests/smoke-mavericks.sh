#!/bin/sh
# platform: macOS-only -- mounts Linux filesystems through Mavergreen macFUSE on a real Mac OS X 10.9 box (the acceptance job's guest)
# spec: .github/workflows/on-mavericks.yml -- the installed product on 10.9: the manifest is the run's version; the root
#       helper and the keychain keeper (linuxfs-agent) are running; `linuxfs mount` mounts ext4, btrfs, xfs, NTFS (ntfs3),
#       exFAT and f2fs images, writes through each, unmounts, mounts again and reads it all back. Then DiskArbitration's six
#       bundles: ext4, btrfs, xfs, f2fs, NTFS (NTFSTakeover on) and APFS, raw and GPT-wrapped, are mounted by an attach within 30 s (personality, reads, writes, unmount and mount, eject
#       leaves no lklfuse); NTFS with NTFSTakeover off is Apple's; `linuxfs ignore` (an /etc/fstab noauto entry: ext4 by device, NTFS by
#       label; ext4 by a label with a space, written as LABEL=my\040data) mounts nothing on a plain attach and never runs the mount program, `diskutil mount` mounts it, and after `linuxfs unignore` a plain attach does;
#       ReadOnly in the user's plist (read by the root mount program) mounts read-only; a label with a slash or a control
#       character gets a safe /Volumes name; the encrypted APFS fixture shows the password dialog (screenshot), times out
#       with no mount, mounts through --password-stdin and the keeper's --offer, then from the login keychain with no dialog;
#       last, before login (the user's console session ended), an attached ext4 disk is mounted by root with allow_other and
#       served by lklfuse as _linuxfs (with a macFUSE that cannot serve /dev/fd/N the mount program refuses, and that is what is
#       checked: nothing mounted, the reason in system.log); with that lklfuse killed, diskutil unmount still works. No lklfuse ever runs as root. exFAT keeps no symlinks, hard links, modes or xattrs, and ntfs3 keeps no
#       POSIX mode without its acl option, so those are not asked of them. Any hang, new panic or new lklfuse crash report
#       fails it. Linux checks the images afterwards (on-mavericks.yml's fsck job).
#   usage: smoke-mavericks.sh VERSION IN OUT
#          VERSION is the run's version (the pkg installed). IN holds ext4, btrfs, xfs, ntfs, exfat, f2fs and apfs .img.gz
#          from tests/lib/probe-images.sh, gpt-<fs>.img.gz (each in its own partition type), gpt-ext4-basic.img.gz and gpt-enc.img.gz (tests/lib/gpt-wrap.py), and ext4-slash and
#          ext4-ctl .img.gz (tests/lib/label-images.sh). OUT receives every image as it is after the run, gzipped (da-*.img.gz
#          are the disks DiskArbitration mounted), and the screenshots. Run as the guest's user over ssh, not root and not in
#          the console session: the steps that need it go through /usr/local/bin/guest-macosx-aqua.
#          Exits 77 where it cannot run (not 10.9, product not installed, wrong arguments); the job treats 77 as failure.
set -u
case "$(sw_vers -productVersion 2>/dev/null)" in 10.9*) ;; *) echo "not Mac OS X 10.9 -- skipping"; exit 77 ;; esac
[ $# -eq 3 ] || { echo "usage: smoke-mavericks.sh VERSION IN OUT -- skipping"; exit 77; }
P=/usr/local/mavergreen/linuxfs
[ -f "$P/mavergreen.plist" ] || { echo "Linux Filesystems for Mavericks is not installed -- skipping"; exit 77; }
VERSION=$1
IN=$(cd "$2" && pwd) || exit 1
mkdir -p "$3" && OUT=$(cd "$3" && pwd) || exit 1
L=$P/bin/linuxfs
W=/private/tmp/linuxfs-smoke
n=0 bad=0 disk=
tab=$(printf '\t')
ok() { n=$((n + 1)); echo "ok $n - $1"; }
notok() { n=$((n + 1)); echo "not ok $n - $1"; bad=1; }
check() {
  what=$1; shift
  if "$@" > "$W/step-$((n + 1)).log" 2>&1; then ok "$what"; return 0; fi
  notok "$what (log follows)"; sed 's/^/# /' "$W/step-$n.log"; return 1
}
die() { notok "$1"; finish; }
# spec: tests/smoke-mavericks.sh header -- a hang fails: every wait is bounded, in tenths of a second
bounded() {
  t=$1; shift
  "$@" & bp=$!
  i=0; while kill -0 "$bp" 2>/dev/null; do
    i=$((i + 1)); [ $i -le "$t" ] || { kill -9 "$bp" 2>/dev/null; echo "hung: $*"; return 124; }
    sleep 0.1
  done
  wait "$bp"
}
crashes() { ls "$HOME"/Library/Logs/DiagnosticReports/lklfuse_* /Library/Logs/DiagnosticReports/*.panic 2>/dev/null | wc -l | tr -d ' '; }
mountpoint_of() { "$L" status | awk -F"$tab" -v s="$1" '$2 == s { print $3; exit }'; }
pid_of() { "$L" status | awk -F"$tab" -v s="$1" '$2 == s { print $1; exit }'; }
finish() {
  for m in "$W"/mnt/*; do mount | grep -qF " on $m (" && { umount -f "$m" || diskutil unmount force "$m"; } > /dev/null 2>&1; done
  [ -z "$disk" ] || hdiutil detach -force "$disk" > /dev/null 2>&1
  defaults delete dev.mavergreen.linuxfs > /dev/null 2>&1
  [ "$(crashes)" = "$CRASH0" ] || { notok "no new panic or lklfuse crash report"; ls -l "$HOME"/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports 2>&1 | sed 's/^/# /'; }
  for f in "$W"/img/*.img; do [ -f "$f" ] && gzip -c "$f" > "$OUT/$(basename "$f").gz"; done
  # spec: .github/workflows/on-mavericks.yml -- the run's evidence comes back in OUT (copyback), uploaded even when this fails
  # platform: sudo logs every COMMAND= line to system.log, and OUT is uploaded publicly: nothing that names the keychain unlock or kcpassword goes in
  grep -v 'unlock-keychain\|kcpassword\|security -i' /var/log/system.log 2> /dev/null | tail -n 3000 > "$OUT/system.log"
  echo "# OUT: $(ls -l "$OUT" | awk 'NR > 1 { printf "%s (%s) ", $NF, $5 }')"
  echo "1..$n"
  exit "$bad"
}
[ "$(id -u)" != 0 ] || { echo "run this as the guest's user, not root: volumes are mounted by users" >&2; exit 1; }
rm -rf "$W"; mkdir -p "$W/img" "$W/mnt" || exit 1
CRASH0=$(crashes)

installed=$(awk '/<key>version<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }' "$P/mavergreen.plist")
[ "$installed" = "$VERSION" ] && ok "the installed manifest is $VERSION" || die "the installed manifest is '$installed', not $VERSION"
check "the root helper is running" pgrep -u 0 -f /Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.helper
check "linuxfs status runs" "$L" status
# spec: tests/smoke-mavericks.sh header -- ---- DiskArbitration: the six bundles mount attached disks themselves (Mac OS X 10.9, no agent in the loop) ----
AQUA=/usr/local/bin/guest-macosx-aqua
UUID_PART=6C696E75-7866-7370-6172-740000000001   # tests/lib/gpt-wrap.py's partition GUID: the keychain account of its volume
info() { diskutil info "$1" 2> /dev/null | sed -n "s/^ *$2: *//p" | head -n 1; }
# spec: tests/smoke-mavericks.sh header -- attach IMAGE with automount (no -nomount); disks = every /dev/disk node it made, disk = the whole disk
da_attach() {
  out=$(bounded 3000 hdiutil attach -imagekey diskimage-class=CRawDiskImage "$1" 2>&1) || { echo "$out" | sed 's/^/# /'; return 1; }
  disks=$(printf '%s\n' "$out" | awk '/^\/dev\/disk/ { print $1 }' | tr '\n' ' ')
  disk=${disks%% *}; [ -n "$disk" ]
}
# spec: tests/smoke-mavericks.sh header -- the mounted node of disks within T tenths of a second: dev and mp
da_attach_nomount() {
  out=$(bounded 3000 hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$1" 2>&1) || { echo "$out" | sed 's/^/# /'; return 1; }
  disks=$(printf '%s\n' "$out" | awk '/^\/dev\/disk/ { print $1 }' | tr '\n' ' ')
  disk=${disks%% *}; [ -n "$disk" ]
}
da_wait() {
  i=0; while :; do
    for d in $disks; do
      if [ "$(info "$d" Mounted)" = Yes ]; then dev=$d; mp=$(info "$d" "Mount Point"); [ -n "$mp" ] && return 0; fi
    done
    i=$((i + 10)); [ $i -le "$1" ] || return 1; sleep 1
  done
}
# spec: tests/smoke-mavericks.sh header -- lklfuse processes, as "USER PID COMMAND"
# spec: tests/smoke-mavericks.sh header -- the lklfuse lines whose command ends in exactly MNT as its last argument (a mount point may hold spaces)
lklfuse_on() { lklfuses | awk -v m=" $1" 'length($0) > length(m) && substr($0, length($0) - length(m) + 1) == m'; }
lklfuses() { ps -axww -o user=,pid=,command= | awk '/lklfuse/ && !/awk/'; }
lklfuse_user_is() { lklfuse_on "$2" | awk -v u="$1" '$1 == u { f = 1 } END { exit !f }'; }
lklfuse_has() { lklfuse_on "$2" | grep -q "$1"; }
no_root_lklfuse() { lklfuses | awk '$1 == "root" { f = 1 } END { exit f }'; }
# spec: tools/fs.c mount_by_root -- before login: the lklfuse lines run by _linuxfs whose mountpoint is /dev/fd/N (root's mount)
lklfuse_fd() { lklfuses | awk '$1 == "_linuxfs" && $NF ~ /^\/dev\/fd\/[0-9]+$/'; }
lklfuse_fd_runs() { [ -n "$(lklfuse_fd)" ]; }
# spec: tools/fs.c mount_by_root -- no mount_macfuse root started outlives the mount program (it stops one that lingers)
no_root_mount_macfuse() { ! ps -axww -o user=,pid=,command= | awk '$1 == "root" && /mount_macfuse/ && !/awk/' | grep -q .; }
# spec: tools/fs.c mount_by_root -- waits up to $1 s (default 90, past mount(2)'s own give-up on INIT after about 50 s) for no root
#       mount_macfuse; prints ps when one is left
root_mount_macfuse_gone() {
  j=0; while ! no_root_mount_macfuse; do
    j=$((j + 1)); [ $j -le "${1:-90}" ] || { ps -axww -o user,pid,ppid,stat,etime,command | grep -i 'fuse\|linuxfs' | grep -v grep | sed 's/^/# left: /'; return 1; }
    sleep 1
  done
}
# spec: components/macfuse/version -- macFUSE 5.5.0-mavericks.4 is the tested combination (build/package.sh's MACFUSE_MIN) and carries the
#       single-threaded-loop fix; lklfuse's ending on SIGTERM on 10.9 is LKL's (patches/0011), .2 and .3 with it untested: the version
#       in the guest's manifest, as 0 when it is at least .4
macfuse_term_fixed() {
  mfv=$(/usr/libexec/PlistBuddy -c 'Print :version' /usr/local/mavergreen/macfuse/mavergreen.plist 2> /dev/null) || return 1
  echo "$mfv" | sed 's/-mavericks[.]/./' | awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) { split("5 5 0 4", t, " "); if ($i + 0 != t[i] + 0) exit !($i + 0 > t[i] + 0) } exit 0 } { exit 1 }'
}
# spec: tools/fs.c mount_by_root -- a daemon that dies leaves the mount unserved (see its use below): SIGTERM through sudo (the
#       process is _linuxfs's), 5 s; where macFUSE has the fix (macfuse_term_fixed) that must end it, and term_clean says so; else
#       (or if it does not) it is said and SIGKILL follows, 30 s: only a process still there after SIGKILL fails this function
term_clean=
kill_lklfuse() {
  term_clean=
  sudo -n kill "$1" || return 1
  bounded 50 sh -c 'while ps -p "$1" > /dev/null; do sleep 0.1; done' _ "$1" && { term_clean=1; return 0; }
  echo "# lklfuse ($1) was still running 5 s after SIGTERM while serving; SIGKILL"
  sudo -n kill -KILL "$1" || return 1
  bounded 300 sh -c 'while ps -p "$1" > /dev/null; do sleep 0.1; done' _ "$1"
}
mounted_by_root() { l=$(mount | grep -F " on $1 ("); echo "$l"; [ -n "$l" ] && ! echo "$l" | grep -q "mounted by"; }
login_unmount() { bounded 600 sudo -n diskutil unmount "$1" && ! mount | grep -qF " on $1 ("; }
login_eject() {  # whole disk: ejected, and no _linuxfs lklfuse within 10 s
  bounded 600 sudo -n diskutil eject "$1" || return 1
  j=0; while [ -n "$(lklfuses | awk '$1 == "_linuxfs"')" ]; do j=$((j + 1)); [ $j -le 100 ] || { lklfuses; return 1; }; sleep 0.1; done
}
da_eject() {  # whole disk, mount point: leaves no lklfuse on it
  pids=$(lklfuse_on "$2" | awk '{ print $2 }')
  bounded 600 diskutil eject "$1" > /dev/null 2>&1 || return 1
  for p in $pids; do bounded 300 sh -c 'while ps -p "$1" > /dev/null; do sleep 0.1; done' _ "$p" || { echo "lklfuse $p still runs"; return 1; }; done
  j=0; while [ -n "$(lklfuse_on "$2")" ]; do
    j=$((j + 1)); [ $j -le 10 ] || { echo "lklfuse still on $2 ten seconds after the eject:"; lklfuses; ps -axww -o user=,pid=,command= | grep -i 'fuse' | grep -v grep; return 1; }
    sleep 1
  done
}
rw_works() { echo da > "$1/da-file" && [ "$(cat "$1/da-file")" = da ] && mkdir "$1/da-dir" && echo two > "$1/da-dir/f" && [ "$(cat "$1/da-dir/f")" = two ]; }
rw_reads() { [ "$(cat "$1/da-file")" = da ] && [ "$(cat "$1/da-dir/f")" = two ]; }

persona_is() {  # DEV PERSONALITY: on failure, what diskutil info said
  got=$(info "$1" 'File System Personality'); mnt=$(info "$1" Mounted)
  [ "$got" = "$2" ] && [ "$mnt" = Yes ] && return 0
  echo "personality '$got' (want '$2'), Mounted '$mnt'; diskutil info $1:"; diskutil info "$1" 2>&1; return 1
}
# spec: tests/smoke-mavericks.sh header -- the disk hdiutil attached IMAGE as, if it is still attached
image_disk() { hdiutil info 2> /dev/null | awk -v p="$1" '/^image-path/ { sub(/^image-path[ \t]*:[ \t]*/, ""); cur = ($0 == p) } cur && /^\/dev\/disk[0-9]+[ \t]/ { print $1; exit }'; }
# spec: tests/smoke-mavericks.sh header -- a failing section never ends the smoke: whatever it attached is ejected before the next
cleanup_disk() {
  [ -z "$disk" ] || { bounded 600 diskutil eject "$disk" > /dev/null 2>&1 || bounded 300 hdiutil detach "$disk" > /dev/null 2>&1; }
  disk=
}
# spec: tests/smoke-mavericks.sh header -- NAME IMAGE PERSONALITY KIND(rw|ro) VIA(raw|GPT): attach, mounted within 30 s, personality, reads and writes,
#       unmount then mount, eject leaves no lklfuse
da_cycle() {
  nm=$1 img=$2 want=$3 kind=$4 via=$5 tag="$1 ($5)"
  da_attach "$img" || { notok "$tag: hdiutil attach"; disk=$(image_disk "$img"); cleanup_disk; return 1; }
  if ! da_wait 300; then
    notok "$tag: mounted by DiskArbitration within 30 s"; diskutil list | sed 's/^/# /'; cleanup_disk; return 1
  fi
  ok "$tag: $dev mounted at $mp within 30 s"
  check "$tag: diskutil info shows the personality $want and Mounted: Yes" persona_is "$dev" "$want"
  check "$tag: no lklfuse runs as root" no_root_lklfuse
  if [ "$kind" = rw ]; then
    check "$tag: reads and writes work" rw_works "$mp"
  else
    check "$tag: it lists, and a write is refused (read-only)" sh -c 'ls "$1" > /dev/null && ! ( echo x > "$1/c" ) 2> /dev/null' _ "$mp"
  fi
  oldmp=$mp
  check "$tag: diskutil unmount" bounded 600 diskutil unmount "$mp"
  check "$tag: it is unmounted" sh -c '[ "$(diskutil info "$1" 2> /dev/null | sed -n "s/^ *Mounted: *//p")" = No ]' _ "$dev"
  check "$tag: diskutil mount" bounded 600 diskutil mount "$dev"
  if da_wait 300; then
    ok "$tag: mounted again at $mp"
    [ "$kind" != rw ] || check "$tag: what was written reads back after remount" rw_reads "$mp"
  else notok "$tag: mounted again within 30 s"; fi
  check "$tag: diskutil eject leaves no lklfuse" da_eject "$disk" "$mp"
  cleanup_disk
}


# ---- SPIKE spike/fstypename: ext4 as f_fstypename macfuse_ext4 (bundle macfuse_ext4.fs, -o fstypename=ext4,fssubtype=7) ----
# Evidence first: everything is recorded as "# " lines, and what can be a check is one. Early and always (a failing check never ends it).
rec() { "$@" 2>&1 | sed 's/^/#   /'; }
fstn_finder_kind() {  # VOLNAME MP: Finder's kind of the disk, by name and by the alias of its mount point
  k1=$(bounded 300 "$AQUA" osascript -e "tell application \"Finder\" to get kind of disk \"$1\"" 2>&1)
  k2=$(bounded 300 "$AQUA" osascript -e "tell application \"Finder\" to get kind of (POSIX file \"$2\" as alias)" 2>&1)
  echo "# Finder: kind of disk \"$1\": $k1"
  echo "# Finder: kind of the alias of $2: $k2"
  return 0   # Finder says Volume here; Format is in Get Info (screenshot)
}
fstn_getinfo_shot() {  # VOLNAME
  bounded 300 "$AQUA" osascript -e "tell application \"Finder\" to activate" -e "tell application \"Finder\" to open information window of disk \"$1\"" > "$W/getinfo.log" 2>&1
  echo "# Finder: open information window: $(tr '\n' ' ' < "$W/getinfo.log")"
  sleep 4
  bounded 300 "$AQUA" screencapture -x "$OUT/fstn-getinfo.png" > /dev/null 2>&1 && ok "fstypename: screenshot fstn-getinfo.png (Get Info: read Format)" || notok "fstypename: screencapture of Get Info"
  bounded 300 "$AQUA" osascript -e "tell application \"Finder\" to close every information window" > /dev/null 2>&1
}
fstn_mount_line() { test -n "$(mount | grep -F " on $1 (" | grep -F '(macfuse_ext4,')"; }
fstn_info_is() { test "$(info "$1" "$2")" = "$3"; }
fstn_ignore() {  # DISK: ignore writes the noauto entry with vfstype macfuse_ext4
  bounded 600 "$L" ignore "$1" || return 1
  echo "# /etc/fstab after linuxfs ignore:"; sed 's/^/#   /' /etc/fstab
  grep -q ' none macfuse_ext4 rw,noauto # linuxfs$' /etc/fstab || return 1
}
fstn_nested() {  # MP: lklfuse onto a directory inside the macfuse_ext4 volume
  cp "$W/img/spike-ext4.img" "$W/img/spike-inner.img" || return 1
  mkdir -p "$1/inner" || return 1
  out=$(bounded 600 "$L" mount "$W/img/spike-inner.img" "$1/inner" 2>&1); rc=$?
  echo "# nested: linuxfs mount IMG $1/inner: exit $rc: $(printf '%s' "$out" | tail -n 6 | tr '\n' ' ')"
  echo "# nested: mount: $(mount | grep -F "$1/inner" | tr '\n' '|')"
  bounded 300 "$L" unmount "$1/inner" > /dev/null 2>&1
  return 0
}
fstn_probe() {  # TAG: does a plain attach of a fresh copy still automount? (which step poisons the later ext4 attaches)
  cp "$W/img/spike-ext4.img" "$W/img/spike-probe.img" || return 1
  if da_attach "$W/img/spike-probe.img"; then
    if da_wait 150; then ok "fstypename probe $1: a plain attach automounts ($mp)"; else notok "fstypename probe $1: a plain attach automounts"; echo "# probe $1: diskutil info:"; rec diskutil info "$disk"; echo "# probe $1: diskutil mount $disk: $(diskutil mount "$disk" 2>&1 | tr '\n' ' ')"; rec mount; fi
  else notok "fstypename probe $1: hdiutil attach"; disk=$(image_disk "$W/img/spike-probe.img"); fi
  cleanup_disk
}
fstn_section() {
  echo "# fstypename: macFUSE tools and versions in this install:"
  rec ls -la /Library/Filesystems/macfuse.fs/Contents/Resources /usr/local/bin /System/Library/Filesystems/macfuse_ext4.fs/Contents /System/Library/Filesystems/macfuse_ext4.fs/Contents/Resources
  rec sh -c 'ls /Library/Filesystems /System/Library/Filesystems; ls /usr/local/bin /usr/local/sbin /usr/local/lib 2>/dev/null | grep -i "fuse"'
  rec sh -c 'plutil -p /System/Library/Filesystems/macfuse_ext4.fs/Contents/Info.plist 2>/dev/null || cat /System/Library/Filesystems/macfuse_ext4.fs/Contents/Info.plist'
  gunzip -c "$IN/ext4.img.gz" > "$W/img/spike-ext4.img" || { notok "fstypename: no $IN/ext4.img.gz"; return 1; }
  da_attach "$W/img/spike-ext4.img" || { notok "fstypename: hdiutil attach"; disk=$(image_disk "$W/img/spike-ext4.img"); cleanup_disk; return 1; }
  da_wait 300 || { notok "fstypename: DiskArbitration mounted a plain attach within 30 s"; diskutil list | sed 's/^/# /'; rec tail -n 60 /var/log/system.log; cleanup_disk; return 1; }
  ok "fstypename: DiskArbitration mounted a plain attach: $dev at $mp"
  echo "# mount: $(mount | grep -F " on $mp (")"
  echo "# stat -f %T $mp: $(stat -f %T "$mp")"
  echo "# df -T macfuse_ext4: $(df -T macfuse_ext4 2>&1 | tr '\n' '|')"
  check "fstypename: mount reports macfuse_ext4" fstn_mount_line "$mp"
  echo "# diskutil info $dev:"; rec diskutil info "$dev"
  echo "# diskutil list:"; rec diskutil list
  check "fstypename: diskutil info Type (Bundle) is macfuse_ext4" fstn_info_is "$dev" 'Type (Bundle)' macfuse_ext4
  check "fstypename: diskutil info File System Personality is ext4" fstn_info_is "$dev" 'File System Personality' ext4
  check "fstypename: diskutil info Name (User Visible) is Linux ext4 (linuxfs)" fstn_info_is "$dev" 'Name (User Visible)' 'Linux ext4 (linuxfs)'
  check "fstypename: the volume is writable and reads back" rw_works "$mp"
  vn=$(info "$dev" "Volume Name"); [ -n "$vn" ] || vn=$(basename "$mp")
  echo "# volume name: '$vn', mount point $mp"
  fstn_finder_kind "$vn" "$mp"
  fstn_getinfo_shot "$vn"
  bounded 300 "$AQUA" screencapture -x "$OUT/fstn-desktop.png" > /dev/null 2>&1
  echo "# processes:"; rec sh -c 'ps -axww -o user=,pid=,command= | grep -i "lklfuse\|mount_macfuse" | grep -v grep'
  fstn_nested "$mp"
  check "fstypename: diskutil unmount" bounded 600 diskutil unmount "$mp"
  check "fstypename: it is unmounted" fstn_info_is "$dev" Mounted No
  check "fstypename: diskutil mount (remount)" bounded 600 diskutil mount "$dev"
  if da_wait 300; then
    ok "fstypename: remounted at $mp"
    echo "# mount after remount: $(mount | grep -F " on $mp (")"
    check "fstypename: the remount reports macfuse_ext4 too" fstn_mount_line "$mp"
    check "fstypename: what was written reads back" rw_reads "$mp"
  else notok "fstypename: remounted within 30 s"; fi
  check "fstypename: diskutil eject, and no lklfuse is left on it" da_eject "$disk" "$mp"
  cleanup_disk
  fstn_probe A-after-eject
  if da_attach_nomount "$W/img/spike-ext4.img"; then
    sleep 6
    if mount | grep -qF "linuxfs@"; then echo "# the agent's login sweep mounted it first; unmounting"; bounded 600 diskutil unmount "$disk" > /dev/null 2>&1; fi
    check "fstypename: linuxfs ignore writes a noauto entry with vfstype macfuse_ext4" fstn_ignore "$disk"
    out=$(bounded 600 diskutil mount "$disk" 2>&1); rc=$?
    echo "# diskutil mount $disk with the noauto entry: exit $rc: $(printf '%s' "$out" | tr '\n' ' ')"
    test "$rc" -eq 0 && ok "fstypename: diskutil mount works with the noauto entry" || notok "fstypename: diskutil mount works with the noauto entry"
    echo "# mount: $(mount | grep -F linuxfs@ | tr '\n' '|')"
    rec tail -n 20 /var/log/system.log
    bounded 600 "$L" unignore "$disk" > /dev/null 2>&1
    echo "# /etc/fstab after unignore:"; sed 's/^/#   /' /etc/fstab
  else notok "fstypename: hdiutil attach -nomount"; disk=$(image_disk "$W/img/spike-ext4.img"); fi
  cleanup_disk
  fstn_probe B-after-ignore-unignore
  m=$W/mnt/spike; mkdir -p "$m"
  check "fstypename: linuxfs mount (the CLI's path)" bounded 600 "$L" mount "$W/img/spike-ext4.img" "$m"
  echo "# CLI path mount: $(mount | grep -F " on $m (")"
  echo "# CLI path stat -f %T: $(stat -f %T "$m")"
  check "fstypename: the CLI's mount reports macfuse_ext4" fstn_mount_line "$m"
  check "fstypename: the CLI's mount unmounts" unmount_and_wait "$W/img/spike-ext4.img" "$m"
  fstn_probe C-after-cli-mount
}

imgfs=
for fs in ext4 btrfs xfs ntfs exfat f2fs; do
  if gunzip -c "$IN/$fs.img.gz" > "$W/img/$fs.img" 2> /dev/null; then imgfs="$imgfs $fs"
  else notok "$fs: no $IN/$fs.img.gz (a required image)"; fi
done
dd if=/dev/urandom of="$W/payload" bs=1024 count=4096 2> /dev/null || die "cannot make the payload"
for fs in $imgfs; do
  case $fs in ntfs) want=ntfs3 ;; *) want=$fs ;; esac
  check "linuxfs-probe names $fs" sh -c '[ "$("$1" "$2" | cut -f 1)" = "$3" ]' _ "$P/libexec/linuxfs-probe" "$W/img/$fs.img" "$want"
done

posix() { case $1 in ext4|btrfs|xfs|f2fs) return 0 ;; *) return 1 ;; esac; }
links() { [ "$1" != exfat ]; }
write_through() {  # FS MOUNTPOINT
  cp "$W/payload" "$2/big" && cmp "$W/payload" "$2/big" &&
  mkdir "$2/d" && echo one > "$2/d/f1" && mv "$2/d/f1" "$2/d/moved" && [ ! -e "$2/d/f1" ] || return 1
  if links "$1"; then
    ln -s moved "$2/d/sym" && [ "$(readlink "$2/d/sym")" = moved ] &&
    ln "$2/d/moved" "$2/d/hard" && [ "$(stat -f %l "$2/d/moved")" = 2 ] &&
    xattr -w user.k v "$2/big" && [ "$(xattr -p user.k "$2/big")" = v ] || return 1
  fi
  if posix "$1"; then chmod 640 "$2/d/moved" && [ "$(stat -f %Lp "$2/d/moved")" = 640 ] || return 1; fi
}
read_back() {  # FS MOUNTPOINT
  cmp "$W/payload" "$2/big" && [ "$(cat "$2/d/moved")" = one ] && [ ! -e "$2/d/f1" ] || return 1
  if links "$1"; then
    [ "$(cat "$2/d/sym")" = one ] && [ "$(cat "$2/d/hard")" = one ] && [ "$(stat -f %l "$2/d/moved")" = 2 ] &&
    [ "$(xattr -p user.k "$2/big")" = v ] || return 1
  fi
  if posix "$1"; then [ "$(stat -f %Lp "$2/d/moved")" = 640 ] || return 1; fi
}
# platform: kill -0 on another user's pid (lklfuse as _linuxfs, root's sudo) fails with EPERM for this shell, so a wait on
#           such a pid asks ps -p instead; kill -0 stays only for this shell's own children (bounded's, the background attach)
unmount_and_wait() {  # IMAGE MOUNTPOINT
  p=$(pid_of "$1")
  bounded 600 "$L" unmount "$2" || return 1
  [ -z "$p" ] || bounded 300 sh -c 'while ps -p "$1" > /dev/null; do sleep 0.1; done' _ "$p" || { echo "lklfuse $p did not exit"; return 1; }
  ! mount | grep -qF " on $2 (" || { echo "$2 is still mounted"; return 1; }
}
fstn_section
disk=
for fs in $imgfs; do
  img=$W/img/$fs.img m=$W/mnt/$fs
  mkdir -p "$m"
  check "$fs: linuxfs mount" bounded 600 "$L" mount "$img" "$m"
  check "$fs: write, rename, symlink, hard link, chmod and xattr through the mount" write_through "$fs" "$m"
  check "$fs: linuxfs unmount, and lklfuse exits" unmount_and_wait "$img" "$m"
  check "$fs: mount again" bounded 600 "$L" mount "$img" "$m"
  check "$fs: everything reads back" read_back "$fs" "$m"
  check "$fs: unmount again" unmount_and_wait "$img" "$m"
done
# spec: cli/linuxfs --
#       APFS, which 10.9 cannot read: linuxfs mounts it read-only, unasked, and leaves the image as it found it
gunzip -c "$IN/apfs.img.gz" > "$W/img/apfs.img" || die "cannot unpack $IN/apfs.img.gz"
cp "$W/img/apfs.img" "$W/apfs.before"
img=$W/img/apfs.img m=$W/mnt/apfs; mkdir -p "$m"
check "apfs: linuxfs-probe names it, by its volume" sh -c '[ "$("$1" "$2")" = "$(printf "apfs\tTime Machine")" ]' _ "$P/libexec/linuxfs-probe" "$img"
check "apfs: linuxfs mount" bounded 600 "$L" mount "$img" "$m"
check "apfs: the volume lists" ls -la "$m"
check "apfs: mounted read-only; a write is refused" sh -c '! ( echo x > "$1/c" ) 2>/dev/null' _ "$m"
check "apfs: status says ro" sh -c '"$1" status | grep -F "$2" | grep -q "ro\$"' _ "$L" "$m"
check "apfs: unmount, and lklfuse exits" unmount_and_wait "$img" "$m"
check "apfs: not one byte of the image changed" cmp "$W/apfs.before" "$img"

# spec: tests/smoke-mavericks.sh header -- `diskutil listFilesystems` lists only formattable personalities, and phase 1 has no
#       format keys, so the six personalities are not listed there; that check returns with phase 2 (Erase)
check "the keychain keeper (linuxfs-agent) is running" pgrep -f "$P/libexec/linuxfs-agent"
check "no lklfuse runs as root before the disks" no_root_lklfuse
[ -x "$AQUA" ] && ok "the guest has $AQUA for the console user's session" || notok "no $AQUA: the dialog, screenshot and keychain checks cannot run"
defaults delete dev.mavergreen.linuxfs 2> /dev/null
disk=

# spec: tests/smoke-mavericks.sh header -- a raw image, and the same in a GPT wrapper (made on Linux with the filesystem's own partition type), for each filesystem; NTFS has NTFSTakeover on
defaults write dev.mavergreen.linuxfs NTFSTakeover -bool true
for c in ext4:ext4:rw btrfs:btrfs:rw xfs:XFS:rw f2fs:F2FS:rw ntfs:NTFS-linuxfs:rw apfs:APFS:ro; do
  fs=${c%%:*} rest=${c#*:} pers=${rest%%:*} kind=${rest#*:}
  if [ ! -f "$W/img/$fs.img" ] && ! gunzip -c "$IN/$fs.img.gz" > "$W/img/$fs.img" 2> /dev/null; then
    notok "$fs: no $IN/$fs.img.gz (a required image)"; continue
  fi
  if cp "$W/img/$fs.img" "$W/img/da-$fs.img"; then da_cycle "$fs" "$W/img/da-$fs.img" "$pers" "$kind" raw; else notok "$fs: cannot copy $fs.img"; fi
  if gunzip -c "$IN/gpt-$fs.img.gz" > "$W/gpt-$fs.img"; then da_cycle "$fs" "$W/gpt-$fs.img" "$pers" "$kind" GPT; else notok "$fs: cannot unpack $IN/gpt-$fs.img.gz"; fi
  rm -f "$W/gpt-$fs.img"
done
if gunzip -c "$IN/gpt-ext4-basic.img.gz" > "$W/gpt-ext4-basic.img"; then da_cycle ext4 "$W/gpt-ext4-basic.img" ext4 rw "GPT, basic-data type"
else notok "ext4: cannot unpack $IN/gpt-ext4-basic.img.gz"; fi
rm -f "$W/gpt-ext4-basic.img"
defaults delete dev.mavergreen.linuxfs NTFSTakeover

# spec: tests/smoke-mavericks.sh header -- NTFSTakeover off (the default): Apple's own ntfs mounts it
if da_attach "$W/img/ntfs.img"; then
  if da_wait 300; then
    check "ntfs, NTFSTakeover off: the Mac's own ntfs mounted it" sh -c 'mount | grep -F " on $1 (" | grep -q "(ntfs"' _ "$mp"
  else notok "ntfs, NTFSTakeover off: mounted within 30 s"; fi
else notok "ntfs, NTFSTakeover off: hdiutil attach"; disk=$(image_disk "$W/img/ntfs.img"); fi
cleanup_disk

# spec: tests/smoke-mavericks.sh header -- linuxfs ignore: an /etc/fstab noauto entry keeps one volume from mounting by itself
#       (ext4 by its device, so by UUID; NTFS, which has no UUID, by its label): a plain attach mounts nothing (hdiutil fails
#       with no mountable file systems), DiskArbitration never runs the mount program for it, and no "not readable" dialog
#       shows (screenshot); diskutil mount over ssh mounts it; after linuxfs unignore a plain attach mounts it again
noauto_cycle() {  # TAG IMAGE device|label LABEL
  tag=$1 img=$2 how=$3 lab=$4
  if ! da_attach_nomount "$img"; then notok "$tag: hdiutil attach -nomount"; disk=$(image_disk "$img"); cleanup_disk; return 1; fi
  if [ "$how" = spaced ]; then
    # spec: tools/fstab.c -- the entry the helper writes for a label with a space (\040, as fstab spells it), written here by hand
    #       because linuxfs ignore names an ext4 volume by its UUID: DiskArbitration must read \040 as the space and skip the volume
    check "$tag: an /etc/fstab noauto entry for LABEL=my\\040data" sudo -n sh -c 'printf "%s\n" "$1" >> /etc/fstab' _ 'LABEL=my\040data none macfuse_ext4 rw,noauto # linuxfs'
  else
    if [ "$how" = device ]; then arg=$disk; else arg=$lab; fi
    check "$tag: linuxfs ignore $arg" bounded 600 "$L" ignore "$arg"
  fi
  echo "# $tag: linuxfs ignore lists: $(bounded 600 "$L" ignore | tr '\n' '|')"
  check "$tag: /etc/fstab has linuxfs's noauto entry" sh -c 'grep -q " rw,noauto # linuxfs\$" /etc/fstab'
  cleanup_disk
  log0=$(wc -l < /var/log/system.log 2> /dev/null | tr -d ' ')
  out=$(bounded 600 hdiutil attach -imagekey diskimage-class=CRawDiskImage "$img" 2>&1); rc=$?
  bounded 600 "$AQUA" screencapture -x "$OUT/noauto-$tag.png" > /dev/null 2>&1 && ok "$tag: screenshot noauto-$tag.png (read it for a 'not readable' dialog)" || notok "$tag: screencapture"
  disk=$(image_disk "$img"); disks=$disk
  mounted=
  for d in $(printf '%s\n' "$out" | awk '/^\/dev\/disk/ { print $1 }') $disk; do [ "$(info "$d" Mounted)" != Yes ] || mounted=$d; done
  if [ -z "$mounted" ]; then ok "$tag: a plain attach mounted nothing (exit $rc: $(printf '%s' "$out" | tr '\n' ' '))"
  else notok "$tag: a plain attach mounted $mounted"; fi
  sleep 3
  # spec: tests/smoke-mavericks.sh header -- diagnostics only: DiskArbitration's view of this attach, whatever happened (the
  #       UUID it knows the volume by, from the util's -k; its and the util's lines since the attach)
  echo "# $tag: diskutil info $disk: $(diskutil info "$disk" 2>&1 | grep -i uuid | tr -s ' ' | tr '\n' '|')"
  tail -n +"$((${log0:-0} + 1))" /var/log/system.log 2> /dev/null | grep 'diskarbitrationd\|linuxfs-fs' | sed "s/^/# $tag: /"
  # spec: tests/smoke-mavericks.sh header -- anchored: system.log is readable and shows DiskArbitration probing the volume
  #       (linuxfs-fs's "claimed", from util -p) since log0, so the absence of linuxfs-mount after it means something
  if [ -r /var/log/system.log ] && [ -n "$log0" ] && tail -n +"$((log0 + 1))" /var/log/system.log | grep "linuxfs-fs" | grep -q "claimed"; then
    ok "$tag: DiskArbitration probed it (a linuxfs-fs claimed line in system.log since the attach)"
    check "$tag: DiskArbitration never ran the mount program for it (no linuxfs-mount in system.log)" sh -c '! tail -n +"$1" /var/log/system.log | grep -q "linuxfs-mount"' _ "$((log0 + 1))"
  else notok "$tag: system.log readable, with a linuxfs-fs claimed line since the attach (so the mount program's absence can be read)"; fi
  cleanup_disk
  if da_attach_nomount "$img"; then
    check "$tag: diskutil mount over ssh mounts it" bounded 600 diskutil mount "$disk"
    if da_wait 100; then ok "$tag: mounted at $mp by diskutil mount, the noauto entry notwithstanding"
    else notok "$tag: mounted within 10 s of diskutil mount"; tail -n 30 /var/log/system.log 2> /dev/null | grep 'linuxfs\|diskarbitrationd' | sed 's/^/# /'; fi
    [ "$how" != device ] || check "$tag: linuxfs unignore $disk" bounded 600 "$L" unignore "$disk"
  else notok "$tag: hdiutil attach -nomount, again"; disk=$(image_disk "$img"); fi
  case $how in label|spaced) check "$tag: linuxfs unignore $lab" bounded 600 "$L" unignore "$lab" ;; esac
  cleanup_disk
  check "$tag: /etc/fstab has no linuxfs entry left" sh -c '! grep -q "# linuxfs\$" /etc/fstab 2> /dev/null'
  if da_attach "$img"; then
    if da_wait 300; then ok "$tag: after unignore, a plain attach mounts it at $mp"
    else notok "$tag: after unignore, mounted by a plain attach within 30 s"; fi
  else notok "$tag: after unignore, hdiutil attach"; disk=$(image_disk "$img"); fi
  cleanup_disk
}
# spec: tests/smoke-mavericks.sh header -- an entry a failed step left is taken away (by the device: a UUID= entry has no label)
noauto_leftover() {  # IMAGE
  grep -q "# linuxfs\$" /etc/fstab 2> /dev/null || return 0
  echo "# a linuxfs entry was left in /etc/fstab: $(grep '# linuxfs$' /etc/fstab | tr '\n' '|')"
  if da_attach_nomount "$1"; then bounded 600 "$L" unignore "$disk" > /dev/null 2>&1; fi
  cleanup_disk
  # spec: tests/smoke-mavericks.sh header -- the by-hand entry of the label-with-a-space case, if unignore did not take it away
  if grep -q "# linuxfs\$" /etc/fstab 2> /dev/null; then sudo -n sed -i '' '/# linuxfs$/d' /etc/fstab 2> /dev/null; fi
}
if cp "$W/img/ext4.img" "$W/img/da-ext4-noauto.img"; then
  noauto_cycle "ignore ext4 by device" "$W/img/da-ext4-noauto.img" device "my data"
  noauto_leftover "$W/img/da-ext4-noauto.img"
else notok "ignore ext4 by device: cannot copy ext4.img"; fi
if cp "$W/img/ext4.img" "$W/img/da-ext4-space.img"; then
  noauto_cycle "ignore ext4 by a label with a space" "$W/img/da-ext4-space.img" spaced "my data"
  noauto_leftover "$W/img/da-ext4-space.img"
else notok "ignore ext4 by a label with a space: cannot copy ext4.img"; fi
defaults write dev.mavergreen.linuxfs NTFSTakeover -bool true
if cp "$W/img/ntfs.img" "$W/img/da-ntfs-noauto.img"; then
  noauto_cycle "ignore ntfs by label" "$W/img/da-ntfs-noauto.img" label Windows
  bounded 600 "$L" unignore Windows > /dev/null 2>&1
else notok "ignore ntfs by label: cannot copy ntfs.img"; fi
defaults delete dev.mavergreen.linuxfs NTFSTakeover

# spec: tests/smoke-mavericks.sh header -- root reads the console user's plist (the seteuid/setgroups drop): ReadOnly in the user's plist, ext4 mounts read-only
"$L" prefs ReadOnly on
if cp "$W/img/ext4.img" "$W/img/da-ext4-ro.img" && da_attach "$W/img/da-ext4-ro.img"; then
  if da_wait 300; then
    check "ReadOnly in the user's plist reaches the root mount program: mounted read-only" sh -c 'mount | grep -F " on $1 (" | grep -q "read-only" && ! ( echo x > "$1/c" ) 2> /dev/null' _ "$mp"
  else notok "ReadOnly on: mounted within 30 s"; fi
else notok "ReadOnly on: copy and attach the ext4 image"; disk=$(image_disk "$W/img/da-ext4-ro.img"); fi
cleanup_disk
"$L" prefs ReadOnly off

# spec: tests/smoke-mavericks.sh header -- a control character or a slash in the label gets a safe /Volumes name
for c in slash ctl; do
  if [ ! -f "$W/img/ext4-$c.img" ] && ! gunzip -c "$IN/ext4-$c.img.gz" > "$W/img/ext4-$c.img" 2> /dev/null; then
    n=$((n + 1)); echo "ok $n - # SKIP label $c: no ext4-$c.img.gz (the image tools made no such label)"; continue
  fi
  if da_attach "$W/img/ext4-$c.img"; then
    if da_wait 300; then
      check "label $c: the volume's name is one safe component under /Volumes (mounted at $mp)" sh -c 'case $1 in /Volumes/*/*) exit 1 ;; /Volumes/?*) ;; *) exit 1 ;; esac; [ -z "$(printf "%s" "$1" | LC_ALL=C tr -d "[:print:]")" ]' _ "$mp"
    else notok "label $c: mounted within 30 s"; fi
  else notok "label $c: hdiutil attach"; disk=$(image_disk "$W/img/ext4-$c.img"); fi
  cleanup_disk
done

# spec: tests/smoke-mavericks.sh header -- the encrypted APFS fixture (password linuxfs-test), in its GPT wrapper (the keychain wants the partition's UUID)
if gunzip -c "$IN/gpt-enc.img.gz" > "$W/gpt-enc.img"; then
  # platform: 10.9 hdiutil attach blocks until the mount program returns, and the dialog takes up to 120 s, so the plain attach waits on the mount program's dialog, so it runs in the background while the screenshot is taken
  hdiutil attach -imagekey diskimage-class=CRawDiskImage "$W/gpt-enc.img" > "$W/enc-attach.out" 2>&1 &
  ap=$!
  sleep 5
  bounded 600 "$AQUA" screencapture -x "$OUT/apfs-dialog.png" > /dev/null 2>&1 && ok "encrypted apfs: screenshot apfs-dialog.png 5 s after the attach (the mount program's password dialog)" || notok "encrypted apfs: screencapture"
  echo "# the dialog's process, if any: $(ps -axww -o user=,pid=,command= | grep -i 'UserNotificationCenter\|CFUserNotification' | grep -v grep | tr '\n' '|')"
  check "encrypted apfs: the mount program is waiting on its dialog" pgrep -f mount_linuxfs_apfs
  disk=$(image_disk "$W/gpt-enc.img")
  disks="$disk $(diskutil list "$disk" 2> /dev/null | awk '{ print $NF }' | grep -E '^disk[0-9]+s[0-9]+$' | sed 's|^|/dev/|' | tr '\n' ' ')"
  # spec: tools/fs.c DIALOG_SECONDS -- the dialog times out after 120 s: exit 4, no mount
  i=5; while kill -0 "$ap" 2> /dev/null && [ $i -lt 170 ]; do i=$((i + 1)); sleep 1; done
  if kill -0 "$ap" 2> /dev/null; then notok "encrypted apfs: the attach was still waiting after 170 s"; kill "$ap" 2> /dev/null
  else ok "encrypted apfs: the attach finished after about ${i} s ($(tr '\n' ' ' < "$W/enc-attach.out"))"; fi
  check "encrypted apfs: the dialog's timeout ended the mount program" sh -c '! pgrep -f mount_linuxfs_apfs > /dev/null'
  check "encrypted apfs: and left nothing mounted (exit 4, no mount)" sh -c 'for d in $1; do [ "$(diskutil info "$d" 2>/dev/null | sed -n "s/^ *Mounted: *//p")" != Yes ] || exit 1; done' _ "$disks"
  echo "# system.log, linuxfs lines:"; grep -i 'linuxfs' /var/log/system.log 2> /dev/null | tail -n 8 | sed 's/^/# /'
  cleanup_disk
  # platform: 10.9 hdiutil detaches the image when the plain attach fails, so it is attached again with -nomount and the password offered to its partition
  if da_attach_nomount "$W/gpt-enc.img"; then
    part=${disk}s1
    check "encrypted apfs: linuxfs mount --password-stdin mounts it read-only, through the keeper's --offer" sh -c 'printf linuxfs-test | "$1" mount --password-stdin "$2"' _ "$L" "$part"
    if disks=$part da_wait 100; then
      check "encrypted apfs: it is mounted read-only at $mp" sh -c 'mount | grep -F " on $1 (" | grep -q "read-only"' _ "$mp"
      check "encrypted apfs: no lklfuse runs as root" no_root_lklfuse
    else notok "encrypted apfs: mounted after --password-stdin"; fi
  else notok "encrypted apfs: attach -nomount"; disk=$(image_disk "$W/gpt-enc.img"); fi
  cleanup_disk
  # spec: tools/agent.c -- the keeper's item: service dev.mavergreen.linuxfs, account the partition's UUID, in the login keychain
  # platform: through guest-macosx-aqua the login keychain is locked ("User interaction is not allowed"); the account's password
  #           is the one mavericks-vm's guest-aqua.sh made and put in /etc/kcpassword, which root can decode
  # platform: 10.9 sudo logs COMMAND= to system.log, so root opens /etc/kcpassword itself (an ssh shell cannot); the password is never on an argv, in the log or in OUT
  kcpw=$(sudo -n perl -e 'open(F, "<", "/etc/kcpassword") or exit 1; binmode F; local $/; my $d = <F>; my @k = (0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F); my $o = ""; for my $i (0 .. length($d) - 1) { my $c = ord(substr($d, $i, 1)) ^ $k[$i % 11]; last if $c == 0; $o .= chr($c); } print $o;' 2> /dev/null)
  kc_ok=
  # spec: tests/smoke-mavericks.sh header -- the unlock goes to `security -i` on stdin through the aqua helper (sudo -E keeps stdin), from a 0600 file
  #       removed at once; sudo's COMMAND= lines in system.log never carry the password
  if [ -n "$kcpw" ] && ( umask 077; printf 'unlock-keychain -p %s %s\n' "$kcpw" "$HOME/Library/Keychains/login.keychain" > "$W/kc.in" ) &&
     KCIN=$W/kc.in bounded 600 sh -c 'exec "$@" < "$KCIN"' _ "$AQUA" security -i > "$W/kc-unlock.log" 2>&1; then
    rm -f "$W/kc.in"
    ok "encrypted apfs: the login keychain is unlocked in the console session"
    if bounded 600 "$AQUA" security add-generic-password -U -s dev.mavergreen.linuxfs -a "$UUID_PART" -w linuxfs-test -T "$P/libexec/linuxfs-agent" login.keychain > "$W/kc-add.log" 2>&1; then
      ok "encrypted apfs: the password goes into the login keychain"; kc_ok=1
    else notok "encrypted apfs: the password goes into the login keychain"; sed 's/^/# /' "$W/kc-add.log"; fi
  else
    rm -f "$W/kc.in"
    n=$((n + 1)); echo "ok $n - # SKIP the keychain checks: the login keychain cannot be unlocked through the harness ($(KCPW=$kcpw awk 'length(ENVIRON["KCPW"]) == 0 || index($0, ENVIRON["KCPW"]) == 0' "$W/kc-unlock.log" 2> /dev/null | tr '\n' ' '))"
  fi
  kcpw=
  if [ -n "$kc_ok" ]; then
    if da_attach "$W/gpt-enc.img"; then
      if da_wait 300; then
        ok "encrypted apfs: a plain attach mounts it at $mp with the keychain's password"
        bounded 600 "$AQUA" screencapture -x "$OUT/apfs-keychain.png" > /dev/null 2>&1
        check "encrypted apfs: no mount program is left waiting on a dialog" sh -c '! pgrep -f mount_linuxfs_apfs > /dev/null'
      else notok "encrypted apfs: mounted within 30 s from the keychain, with no dialog"; fi
    else notok "encrypted apfs: attach again"; disk=$(image_disk "$W/gpt-enc.img"); fi
    cleanup_disk
  fi
  bounded 600 "$AQUA" security delete-generic-password -s dev.mavergreen.linuxfs -a "$UUID_PART" > /dev/null 2>&1
else notok "encrypted apfs: unpack the fixture"; fi
rm -f "$W/gpt-enc.img"
check "the keychain keeper is still running" pgrep -f "$P/libexec/linuxfs-agent"
check "no lklfuse runs as root, after everything" no_root_lklfuse

# spec: tests/smoke-mavericks.sh header -- ---- before login: nobody at the console, ssh the only way in. Last, because the console session does not come back by itself ----
# platform: mavericks-vm README -- on 10.9 loginwindow logs in by itself only at boot, so the user does not return in this job;
#           that is a logged SKIP, never a failure, and nothing is rebooted.
LW=/Library/Preferences/com.apple.loginwindow
AD=/Library/Preferences/SystemConfiguration/autodiskmount
me=$(id -un)
console() { stat -f %Su /dev/console; }
oldauto=$(sudo -n defaults read "$LW" autoLoginUser 2> /dev/null) olddisks=$(sudo -n defaults read "$AD" AutomountDisksWithoutUserLogin 2> /dev/null)
restore_login() {
  if [ -n "$oldauto" ]; then sudo -n defaults write "$LW" autoLoginUser "$oldauto"; fi
  if [ -n "$olddisks" ]; then sudo -n defaults write "$AD" AutomountDisksWithoutUserLogin -bool "$( [ "$olddisks" = 1 ] && echo true || echo false )"
  else sudo -n defaults delete "$AD" AutomountDisksWithoutUserLogin 2> /dev/null; fi
}
if [ -n "$oldauto" ] && sudo -n true 2> /dev/null; then
  cp "$W/img/ext4.img" "$W/img/login-ext4.img" || notok "before login: cannot copy ext4.img"
  sudo -n defaults write "$AD" AutomountDisksWithoutUserLogin -bool true
  sudo -n defaults delete "$LW" autoLoginUser
  sudo -n killall loginwindow
  i=0; until [ "$(console)" = root ]; do i=$((i + 1)); [ $i -le 30 ] || break; sleep 1; done
  if [ "$(console)" = root ]; then ok "before login: the console is root's (the login window), after about $i s"
  else notok "before login: /dev/console is still owned by $(console) after 30 s (loginwindow restarted; the checks below may not be before-login)"; fi
  bounded 600 sudo -n screencapture -x "$OUT/before-login.png" > /dev/null 2>&1 && echo "# before-login.png taken as root" || echo "# NOTE: screencapture as root over ssh failed; no before-login.png"
  bad0=$bad; loglog=$(wc -l < /var/log/system.log 2> /dev/null | tr -d ' ')
  out=$(bounded 3000 sudo -n hdiutil attach -imagekey diskimage-class=CRawDiskImage "$W/img/login-ext4.img" 2>&1)
  disks=$(printf '%s\n' "$out" | awk '/^\/dev\/disk/ { print $1 }' | tr '\n' ' '); disk=${disks%% *}
  # spec: tools/fs.c macfuse_serves_fd -- the mount program logs which way it mounts: root's mount needs a macFUSE whose
  #       libfuse serves /dev/fd/N (MACFUSE_FD_MOUNTPOINT_SINCE); before that the before-login mount is not this release's to check
  gate= i=0
  while [ -n "$disk" ] && [ -z "$gate" ] && [ $i -lt 30 ]; do
    gate=$(tail -n +"$((${loglog:-0} + 1))" /var/log/system.log 2> /dev/null | sed -n -e 's/.*mount_[a-z0-9]*: \(macFUSE .* serves .*\)$/\1/p' -e 's/.*mount_[a-z0-9]*: \(macFUSE .* is before .*\)$/\1/p' | tail -n 1)
    [ -n "$gate" ] || { i=$((i + 1)); sleep 1; }
  done
  echo "# before login: ${gate:-the mount program logged no macFUSE gate within 30 s}"
  case $gate in
    *"is before"*)
      # spec: tools/fs.c mount_as_root -- an older macFUSE cannot mount before login at all (_linuxfs with allow_other is always refused,
      #       VM-proven): the mount program refuses with a fixed reason, and nothing is mounted and no lklfuse runs
      j=0; until tail -n +"$((${loglog:-0} + 1))" /var/log/system.log 2> /dev/null | grep -q "refused: macFUSE is too old to mount before login; update macFUSE"; do
        j=$((j + 1)); [ $j -le 30 ] || break; sleep 1
      done
      check "before login (older macFUSE): the mount program refused, saying macFUSE is too old ($gate)" sh -c 'tail -n +"$1" /var/log/system.log | grep -q "refused: macFUSE is too old to mount before login; update macFUSE"' _ "$((${loglog:-0} + 1))"
      check "before login (older macFUSE): nothing is mounted from $disk" sh -c '! mount | grep -qF "linuxfs@$1 "' _ "${disk#/dev/}"
      check "before login (older macFUSE): no lklfuse runs as root" no_root_lklfuse
      if [ -n "$disk" ]; then check "before login (older macFUSE): eject leaves no lklfuse" login_eject "$disk" && disk=; fi
      check "before login (older macFUSE): no lklfuse runs as root, after the eject" no_root_lklfuse ;;
    *)
      if [ -n "$disk" ] && da_wait 300; then
        ok "before login: $dev mounted at $mp"
        echo "# before login: $(stat -f '%Sp %Su' "$mp") is the mount's mode and owner (right after the mount); lklfuse:"
        lklfuses | sed 's/^/# /'
        mount | grep -F " on $mp (" | sed 's/^/# /'
        check "before login: the mount at $mp is root's (no 'mounted by')" mounted_by_root "$mp"
        echo "# before login: mount: $(mount | grep -F " on $mp (")"
        check "before login: the lklfuse serving it runs as _linuxfs, on a /dev/fd/N mountpoint" lklfuse_fd_runs
        check "before login: no lklfuse runs as root" no_root_lklfuse
        # spec: tools/open.c fuse_chan -- the opener holds the lock from before "ready" on fd 7, which lklfuse's lock= names
        check "before login: lklfuse's lock is the descriptor the opener holds (lock=/dev/fd/7)" sh -c 'ps -axww -o command= | grep "lklfuse.*lock=/dev/fd/7" | grep -qv grep'
        check "before login: the user can write and read the volume over ssh" rw_works "$mp"
        # spec: macfuse DETAILS.md "A mount made for you" -- a daemon that dies leaves the mount with nobody serving it: macFUSE
        #       answers it with an error (ENXIO, the dead file system) instead of a hang, and its owner still unmounts it
        lp=$(lklfuse_fd | awk '{ print $2 }' | head -n 1)
        if [ -n "$lp" ] && kill_lklfuse "$lp"; then
          ok "before login: lklfuse ($lp) is killed"
          if macfuse_term_fixed; then check "before login: with macFUSE 5.5.0-mavericks.4 or later, SIGTERM ends lklfuse within 5 s, no SIGKILL" test "$term_clean" = 1
          else echo "# before login: this macFUSE predates 5.5.0-mavericks.4, the tested one: SIGTERM may be ignored ($([ "$term_clean" = 1 ] && echo ended || echo ignored))"; fi
          check "before login: with lklfuse dead, a read of $mp fails at once instead of hanging" bounded 100 sh -c '! ls "$1"' _ "$mp"
          check "before login: with lklfuse dead, diskutil unmount still unmounts $mp" login_unmount "$mp"
          if bounded 600 sudo -n diskutil mount "$dev" > /dev/null 2>&1 && da_wait 300; then
            ok "before login: diskutil mount mounts $dev again, at $mp"
            check "before login: what the user wrote reads back" rw_reads "$mp"
            # spec: tools/fs.c mount_by_root -- the CLI failing before lklfuse answers INIT (its lock held, so lklfuse exits at
            #       once): the mount fails, nothing is left mounted, and no root mount_macfuse survives (macFUSE's, if one does)
            # spec: tools/open.c fuse_chan -- (lklfuse's own command line names /dev/fd/7, the lock the opener holds; the file is the only one in _linuxfs's lock directory)
            lk=$(sudo -n sh -c 'ls "$1"/*.lock 2> /dev/null | head -n 1' _ /private/var/db/linuxfs/Library/Caches/dev.mavergreen.linuxfs/locks)
            if [ -n "$lk" ] && login_unmount "$mp"; then
              sudo -n -u _linuxfs /usr/bin/python -c 'import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); sys.stdout.write("held\n"); sys.stdout.flush(); time.sleep(300)' "$lk" > "$W/lockhold.out" 2>&1 &
              hold=$!
              j=0; while ! grep -q held "$W/lockhold.out" 2> /dev/null && [ $j -lt 100 ]; do j=$((j + 1)); sleep 0.1; done
              bounded 1800 sudo -n diskutil mount "$dev" > "$W/lockmount.log" 2>&1; lrc=$?
              check "before login: with lklfuse's lock held, diskutil mount $dev fails ($(head -n 1 "$W/lockmount.log"))" test "$lrc" -ne 0
              check "before login: and nothing is left mounted from $dev" sh -c '! mount | grep -qF "linuxfs@$1 "' _ "${dev#/dev/}"
              # spec: tools/open.c fuse_chan -- the CLI's own lock check fails before root runs mount_macfuse at all, so none lingers: within a few seconds
              check "before login: and no root mount_macfuse survives it" root_mount_macfuse_gone 5
              sudo -n kill "$hold" 2> /dev/null; sudo -n pkill -f "fcntl.flock" 2> /dev/null; wait "$hold" 2> /dev/null
              if bounded 600 sudo -n diskutil mount "$dev" > /dev/null 2>&1 && da_wait 300; then ok "before login: with the lock free, $dev mounts again"
              else notok "before login: with the lock free, $dev mounts again"; fi
            else notok "before login: find lklfuse's lock ($lk) and unmount $mp for the held-lock case"; fi
          else notok "before login: diskutil mount mounts $dev again"; fi
        else notok "before login: kill lklfuse ($lp)"; fi
        check "before login: eject unmounts and leaves no lklfuse" login_eject "$disk" && disk=
        check "before login: no lklfuse runs as root, after the eject" no_root_lklfuse
      else notok "before login: the ext4 image mounted within 30 s"; echo "$out" | sed 's/^/# /'; fi ;;
  esac
  if [ "$bad" != "$bad0" ]; then
    echo "# before login, what is left, to find why:"
    sudo -n ls -la /Volumes 2>&1 | sed 's/^/# /'; for m in /Volumes/*; do sudo -n ls -lad "$m" 2>&1 | sed 's/^/# /'; done
    ps -axo user,pid,command | grep -i fuse | grep -v grep | sed 's/^/# /'
    tail -n +"$((${loglog:-0} + 1))" /var/log/system.log 2> /dev/null | grep -i 'linuxfs\|diskarbitrationd\|fuse' | sed 's/^/# /'
    for f in $(sudo -n find /private/var/db/linuxfs -type f 2> /dev/null | head -n 8); do echo "# --- $f"; sudo -n head -c 4000 "$f" 2>&1 | sed 's/^/# /'; done
  fi
  restore_login
  # platform: 10.9 has no re-login without a reboot, and mavericks-vm has no mid-job reboot, so the user's return is not asked
  echo "# SKIP user return: mavericks-vm cannot re-login without a reboot (shipyard queued it); autoLoginUser is restored"
  [ -z "$disk" ] || { bounded 600 sudo -n diskutil eject "$disk" > /dev/null 2>&1 || notok "before login: eject"; }
  disk=
else notok "before login: no autoLoginUser to restore, or no sudo; the before-login checks cannot run safely"; fi
finish
