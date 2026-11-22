#!/bin/sh
# platform: macOS-only -- mounts Linux filesystems through Mavergreen macFUSE on a real Mac OS X 10.9 box (the acceptance job's guest)
# spec: .github/workflows/on-mavericks.yml -- the installed product on 10.9: the manifest is the run's version; the helper
#       daemon and the console user's agent are running; `linuxfs mount` mounts ext4, btrfs, xfs, NTFS (ntfs3) and exFAT
#       images, writes through each (a file, a directory, rename, symlink, hard link, chmod, xattr), unmounts, mounts again
#       and reads it all back; then an ext4 image attached as a disk (hdiutil -nomount) is mounted by the agent under
#       /Volumes without being asked. exFAT keeps no symlinks, hard links, modes or xattrs, and ntfs3 keeps no POSIX mode
#       without its acl option, so those are not asked of them. Any hang, new panic or new lklfuse crash report fails it.
#       Linux checks every image afterwards (on-mavericks.yml's fsck job).
#   usage: smoke-mavericks.sh VERSION IN OUT
#          VERSION is the run's version (the pkg installed). IN holds ext4, btrfs, xfs, ntfs and exfat .img.gz from
#          tests/lib/probe-images.sh. OUT receives every image as it is after the run, gzipped, plus ext4-auto.img.gz (the
#          automounted copy). Run as the guest's user in its console (Aqua) session, not root.
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
  [ "$(crashes)" = "$CRASH0" ] || { notok "no new panic or lklfuse crash report"; ls -l "$HOME"/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports 2>&1 | sed 's/^/# /'; }
  for f in "$W"/img/*.img; do [ -f "$f" ] && gzip -c "$f" > "$OUT/$(basename "$f").gz"; done
  echo "1..$n"
  exit "$bad"
}
[ "$(id -u)" != 0 ] || { echo "run this as the guest's user, not root: volumes are mounted by users" >&2; exit 1; }
rm -rf "$W"; mkdir -p "$W/img" "$W/mnt" || exit 1
CRASH0=$(crashes)

installed=$(awk '/<key>version<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }' "$P/mavergreen.plist")
[ "$installed" = "$VERSION" ] && ok "the installed manifest is $VERSION" || die "the installed manifest is '$installed', not $VERSION"
check "the root helper is running" pgrep -u 0 -f /Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.helper
check "the automount agent is running for this user" pgrep -u "$(id -u)" -f "$P/libexec/linuxfs-agent"
check "linuxfs status runs" "$L" status
for fs in ext4 btrfs xfs ntfs exfat; do
  gunzip -c "$IN/$fs.img.gz" > "$W/img/$fs.img" || die "cannot unpack $IN/$fs.img.gz"
done
cp "$W/img/ext4.img" "$W/img/ext4-auto.img" || die "cannot copy the ext4 image"
dd if=/dev/urandom of="$W/payload" bs=1024 count=4096 2> /dev/null || die "cannot make the payload"
for fs in ext4 btrfs xfs ntfs exfat; do
  case $fs in ntfs) want=ntfs3 ;; *) want=$fs ;; esac
  check "linuxfs-probe names $fs" sh -c '[ "$("$1" "$2" | cut -f 1)" = "$3" ]' _ "$P/libexec/linuxfs-probe" "$W/img/$fs.img" "$want"
done

posix() { case $1 in ext4|btrfs|xfs) return 0 ;; *) return 1 ;; esac; }
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
for fs in ext4 btrfs xfs ntfs exfat; do
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

disk=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$W/img/ext4-auto.img" | awk '/^\/dev\/disk/ { print $1; exit }')
[ -n "$disk" ] && ok "the ext4 image is attached as $disk, unmounted" || die "hdiutil cannot attach the ext4 image"
raw=/dev/r${disk#/dev/}
automounted() { i=0; until mp=$(mountpoint_of "$raw") && [ -n "$mp" ]; do i=$((i + 1)); [ $i -le 600 ] || return 1; sleep 0.1; done; }
if automounted; then
  case $mp in /Volumes/*) ok "the agent mounted $disk at $mp" ;; *) notok "the agent mounted $disk at $mp, not under /Volumes" ;; esac
  check "the automounted volume is the image's filesystem, writable" sh -c 'ls "$1/lost+found" > /dev/null && echo auto > "$1/auto" && [ "$(cat "$1/auto")" = auto ]' _ "$mp"
  check "linuxfs unmount of the automounted volume, and lklfuse exits" unmount_and_wait "$raw" "$mp"
else
  notok "the agent mounted $disk under /Volumes within 60 s"
  sed 's/^/# /' /var/log/dev.mavergreen.linuxfs.helper.log 2>/dev/null | tail -20
fi
check "the disk detaches" hdiutil detach "$disk" && disk=

# platform: review I6: a disk the user owns (as hdiutil makes it) never reaches the helper, so make one root-only, like a real
#           disk, with automount off so the agent leaves it to the CLI, and check lklfuse got the helper's descriptor.
defaults write dev.mavergreen.linuxfs Automount -bool false
cp "$W/img/ext4.img" "$W/img/ext4-helper.img" || die "cannot copy the ext4 image"
disk=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$W/img/ext4-helper.img" | awk '/^\/dev\/disk/ { print $1; exit }')
raw=/dev/r${disk#/dev/}
sudo chown root:operator "$disk" "$raw" && sudo chmod 640 "$disk" "$raw"
check "$raw is root-only, so the CLI must go through the helper" sh -c '! [ -r "$1" ]' _ "$raw"
mkdir -p "$W/mnt/helper"
check "linuxfs mount $disk, through the helper" bounded 600 "$L" mount "$disk" "$W/mnt/helper"
check "lklfuse was given the helper's descriptor (/dev/fd/3)" sh -c 'ps -axww -o command= | grep -F "/dev/fd/3 $1" | grep -q lklfuse' _ "$W/mnt/helper"
check "write and read through it" sh -c 'echo helped > "$1/h" && [ "$(cat "$1/h")" = helped ]' _ "$W/mnt/helper"
check "unmount, and lklfuse exits" unmount_and_wait "$raw" "$W/mnt/helper"
check "the helper refuses the boot partition" sh -c '! "$1" --probe "$(df / | awk "NR == 2 { print \$1 }")" 2>/dev/null' _ "$P/libexec/linuxfs-open"
check "the disk detaches" hdiutil detach "$disk" && disk=
defaults delete dev.mavergreen.linuxfs Automount
finish
