#!/bin/sh
# platform: macOS-only -- mounts Linux filesystems through Mavergreen macFUSE on a real Mac OS X 10.9 box (the acceptance job's guest)
# spec: .github/workflows/on-mavericks.yml -- the installed product on 10.9: the manifest is the run's version; the root
#       helper and the keychain keeper (linuxfs-agent) are running; `linuxfs mount` mounts ext4, btrfs, xfs, NTFS (ntfs3),
#       exFAT and f2fs images, writes through each, unmounts, mounts again and reads it all back. Then DiskArbitration's six
#       bundles: ext4, btrfs, xfs, f2fs, NTFS (NTFSTakeover on) and APFS, raw and GPT-wrapped, are mounted by an attach within 30 s (personality, reads, writes, unmount and mount, eject
#       leaves no lklfuse); NTFS with NTFSTakeover off is Apple's; Automount off mounts nothing on a plain attach (refused for the prefs in system.log) and `diskutil mount` mounts it;
#       ReadOnly in the user's plist (read by the root mount program) mounts read-only; a label with a slash or a control
#       character gets a safe /Volumes name; the encrypted APFS fixture shows the password dialog (screenshot), times out
#       with no mount, mounts through --password-stdin and the keeper's --offer, then from the login keychain with no dialog;
#       last, before login (the user's console session ended), an attached ext4 disk is mounted by lklfuse as _linuxfs with
#       allow_other. No lklfuse ever runs as root. exFAT keeps no symlinks, hard links, modes or xattrs, and ntfs3 keeps no
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
  tail -n 3000 /var/log/system.log > "$OUT/system.log" 2> /dev/null
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
imgfs=
for fs in ext4 btrfs xfs ntfs exfat f2fs; do
  if gunzip -c "$IN/$fs.img.gz" > "$W/img/$fs.img" 2> /dev/null; then imgfs="$imgfs $fs"
  else n=$((n + 1)); echo "ok $n - # SKIP $fs: no $IN/$fs.img.gz"; fi
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
unmount_and_wait() {  # IMAGE MOUNTPOINT
  p=$(pid_of "$1")
  bounded 600 "$L" unmount "$2" || return 1
  [ -z "$p" ] || bounded 300 sh -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.1; done' _ "$p" || { echo "lklfuse $p did not exit"; return 1; }
  ! mount | grep -qF " on $2 (" || { echo "$2 is still mounted"; return 1; }
}
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

# spec: tests/smoke-mavericks.sh header -- ---- DiskArbitration: the six bundles mount attached disks themselves (Mac OS X 10.9, no agent in the loop) ----
AQUA=/usr/local/bin/guest-macosx-aqua
UUID_PART=6C696E75-7866-7370-6172-740000000001   # tests/lib/gpt-wrap.py's partition GUID: the keychain account of its volume
info() { diskutil info "$1" 2> /dev/null | sed -n "s/^ *$2: *//p" | head -n 1; }
# spec: tests/smoke-mavericks.sh header -- attach IMAGE with automount (no -nomount); disks = every /dev/disk node it made, disk = the whole disk
da_attach() {
  out=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage "$1" 2>&1) || { echo "$out" | sed 's/^/# /'; return 1; }
  disks=$(printf '%s\n' "$out" | awk '/^\/dev\/disk/ { print $1 }' | tr '\n' ' ')
  disk=${disks%% *}; [ -n "$disk" ]
}
# spec: tests/smoke-mavericks.sh header -- the mounted node of disks within T tenths of a second: dev and mp
da_attach_nomount() {
  out=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$1" 2>&1) || { echo "$out" | sed 's/^/# /'; return 1; }
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
lklfuses() { ps -axww -o user=,pid=,command= | awk '/lklfuse/ && !/awk/'; }
no_root_lklfuse() { lklfuses | awk '$1 == "root" { f = 1 } END { exit f }'; }
da_eject() {  # whole disk, mount point: leaves no lklfuse on it
  pids=$(lklfuses | awk -v m="$2" 'index($0, m) { print $2 }')
  bounded 600 diskutil eject "$1" > /dev/null 2>&1 || return 1
  for p in $pids; do bounded 300 sh -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.1; done' _ "$p" || { echo "lklfuse $p still runs"; return 1; }; done
  j=0; while lklfuses | grep -qF "$2"; do
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
    n=$((n + 1)); echo "ok $n - # SKIP $fs: no $IN/$fs.img.gz"; continue
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

# spec: tests/smoke-mavericks.sh header -- Automount off: nothing mounts a plain attach (hdiutil fails with no mountable file
#       systems, as it does for a disk the Mac cannot read), the log says prefs refused it, and diskutil mount mounts it
"$L" prefs Automount off
if cp "$W/img/ext4.img" "$W/img/da-ext4-off.img"; then
  img=$W/img/da-ext4-off.img
  log0=$(wc -l < /var/log/system.log 2> /dev/null | tr -d ' ')
  out=$(bounded 600 hdiutil attach -imagekey diskimage-class=CRawDiskImage "$img" 2>&1); rc=$?
  "$AQUA" screencapture -x "$OUT/automount-off.png" > /dev/null 2>&1 && ok "automount off: screenshot automount-off.png (read it for a 'not readable' dialog)" || notok "automount off: screencapture"
  disk=$(image_disk "$img"); disks=$disk
  mounted=
  for d in $(printf '%s\n' "$out" | awk '/^\/dev\/disk/ { print $1 }') $disk; do [ "$(info "$d" Mounted)" != Yes ] || mounted=$d; done
  if [ $rc -ne 0 ] || [ -z "$mounted" ]; then ok "automount off: a plain attach mounted nothing (exit $rc: $(printf '%s' "$out" | tr '\n' ' '))"
  else notok "automount off: a plain attach mounted $mounted"; fi
  sleep 3
  check "automount off: system.log shows the mount refused for the preferences (da-mount exited 3)" sh -c 'tail -n +"$1" /var/log/system.log | grep -q "da-mount exited 3"' _ "$((${log0:-0} + 1))"
  cleanup_disk
  if da_attach_nomount "$img"; then
    ok "automount off: attached -nomount as $disk"
    # spec: tests/smoke-mavericks.sh header -- the observation over ssh, then the check from the console user's session (the
    #       spike saw -o owners from diskutil, probably from the console); both print the mount program's arguments line
    log1=$(wc -l < /var/log/system.log 2> /dev/null | tr -d ' ')
    bounded 600 diskutil mount "$disk" > "$W/dm-ssh.log" 2>&1; rcs=$?
    sleep 2
    echo "# observation, diskutil mount over ssh: exit $rcs: $(tr '\n' ' ' < "$W/dm-ssh.log")"
    tail -n +"$((${log1:-0} + 1))" /var/log/system.log 2> /dev/null | grep 'linuxfs-mount.*\(arguments\|parsed\|exited\)' | sed 's/^/# ssh: /'
    if [ "$(info "$disk" Mounted)" = Yes ]; then echo "# observation: the ssh diskutil mount mounted it; unmounting for the console attempt"; bounded 600 diskutil unmount "$disk" > /dev/null 2>&1; fi
    log2=$(wc -l < /var/log/system.log 2> /dev/null | tr -d ' ')
    check "automount off: diskutil mount, run in the console user's session, mounts it" bounded 600 "$AQUA" diskutil mount "$disk"
    if da_wait 100; then ok "automount off: mounted at $mp after the console user's diskutil mount"
    else
      notok "automount off: mounted within 10 s of the console user's diskutil mount"
      echo "# system.log since the console diskutil mount:"
      tail -n +"$((${log2:-0} + 1))" /var/log/system.log 2> /dev/null | grep 'linuxfs\|diskarbitrationd' | sed 's/^/# /'
    fi
    tail -n +"$((${log2:-0} + 1))" /var/log/system.log 2> /dev/null | grep 'linuxfs-mount.*\(arguments\|parsed\)' | sed 's/^/# console: /'
  else notok "automount off: hdiutil attach -nomount"; disk=$(image_disk "$img"); fi
  cleanup_disk
else notok "automount off: cannot copy ext4.img"; fi
"$L" prefs Automount on

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
  "$AQUA" screencapture -x "$OUT/apfs-dialog.png" > /dev/null 2>&1 && ok "encrypted apfs: screenshot apfs-dialog.png 5 s after the attach (the mount program's password dialog)" || notok "encrypted apfs: screencapture"
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
  kcpw=$(sudo -n perl -e 'my @k = (0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F); local $/; my $d = <STDIN>; my $o = ""; for my $i (0 .. length($d) - 1) { my $c = ord(substr($d, $i, 1)) ^ $k[$i % 11]; last if $c == 0; $o .= chr($c); } print $o;' < /etc/kcpassword 2> /dev/null)
  kc_ok=
  if [ -n "$kcpw" ] && "$AQUA" security unlock-keychain -p "$kcpw" "$HOME/Library/Keychains/login.keychain" > "$W/kc-unlock.log" 2>&1; then
    ok "encrypted apfs: the login keychain is unlocked in the console session"
    if "$AQUA" security add-generic-password -U -s dev.mavergreen.linuxfs -a "$UUID_PART" -w linuxfs-test -T "$P/libexec/linuxfs-agent" login.keychain > "$W/kc-add.log" 2>&1; then
      ok "encrypted apfs: the password goes into the login keychain"; kc_ok=1
    else notok "encrypted apfs: the password goes into the login keychain"; sed 's/^/# /' "$W/kc-add.log"; fi
  else echo "ok $((n + 1)) - # SKIP the keychain checks: the login keychain cannot be unlocked through the harness ($(tr '\n' ' ' < "$W/kc-unlock.log" 2> /dev/null))"; n=$((n + 1)); fi
  kcpw=
  if [ -n "$kc_ok" ]; then
    if da_attach "$W/gpt-enc.img"; then
      if da_wait 300; then
        ok "encrypted apfs: a plain attach mounts it at $mp with the keychain's password"
        "$AQUA" screencapture -x "$OUT/apfs-keychain.png" > /dev/null 2>&1
        check "encrypted apfs: no mount program is left waiting on a dialog" sh -c '! pgrep -f mount_linuxfs_apfs > /dev/null'
      else notok "encrypted apfs: mounted within 30 s from the keychain, with no dialog"; fi
    else notok "encrypted apfs: attach again"; disk=$(image_disk "$W/gpt-enc.img"); fi
    cleanup_disk
  fi
  "$AQUA" security delete-generic-password -s dev.mavergreen.linuxfs -a "$UUID_PART" > /dev/null 2>&1
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
  sudo -n screencapture -x "$OUT/before-login.png" > /dev/null 2>&1 && echo "# before-login.png taken as root" || echo "# NOTE: screencapture as root over ssh failed; no before-login.png"
  bad0=$bad; loglog=$(wc -l < /var/log/system.log 2> /dev/null | tr -d ' ')
  out=$(sudo -n hdiutil attach -imagekey diskimage-class=CRawDiskImage "$W/img/login-ext4.img" 2>&1)
  disks=$(printf '%s\n' "$out" | awk '/^\/dev\/disk/ { print $1 }' | tr '\n' ' '); disk=${disks%% *}
  if [ -n "$disk" ] && da_wait 300; then
    ok "before login: $dev mounted at $mp"
    echo "# before login: $(stat -f '%Sp %Su' "$mp") is the mount's mode and owner (right after the mount); lklfuse:"
    lklfuses | sed 's/^/# /'
    check "before login: lklfuse runs as _linuxfs" sh -c '! [ -z "$(ps -axww -o user=,command= | awk "\$1 == \"_linuxfs\" && /lklfuse/")" ]'
    check "before login: lklfuse mounted with allow_other" sh -c 'ps -axww -o command= | grep lklfuse | grep -F "$1" | grep -q allow_other' _ "$mp"
    check "before login: no lklfuse runs as root" no_root_lklfuse
    check "before login: the user can read and write the volume over ssh" rw_works "$mp"
  else notok "before login: the ext4 image mounted within 30 s"; echo "$out" | sed 's/^/# /'; fi
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
