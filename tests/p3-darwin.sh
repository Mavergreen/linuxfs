#!/bin/sh
# platform: macOS-only -- linuxfs on 10.9 with Mavergreen macFUSE: CLI, root helper
#   usage: sh p3-darwin.sh       (from the P3 bundle's directory; build/p3-bundle.sh makes it)
#          Part A, as the user: `linuxfs mount` of ext4, btrfs, xfs, NTFS and exFAT images; write, rename, symlink,
#          hard link, chmod, xattr where the filesystem keeps them; files shown as the user's; unmount; remount and
#          read back; --ro refuses writes; a second mount of the same image is refused. Part A2: APFS read-only,
#          and APFSWrite. Part A3: encrypted APFS that macOS made, through --password-stdin, checked file by file.
#          Part B, with sudo (skipped, 77, without it): the root helper installed and loaded; an attached disk made
#          root-only, so the CLI must go through the helper; the boot partition refused; a busy unmount names its
#          holder and `unmount --force` works.
#          Images end in out/*.img.gz for tests/p3-check-bundle.sh (Linux fsck). Everything installed is removed.
set -u
cd "$(dirname "$0")" || exit 1
B=$PWD/bin W=$PWD/work O=$PWD/out
rm -rf "$W" "$O"; mkdir -p "$W" "$O"
export LINUXFS_LKLFUSE=$B/lklfuse LINUXFS_PROBE=$B/linuxfs-probe LINUXFS_OPEN=$B/linuxfs-open
export LINUXFS_STATE=$W/state LINUXFS_LOGS=$W/logs LINUXFS_LOCKS=$W/locks LINUXFS_DOMAIN=dev.mavergreen.linuxfs
export TMPDIR=$W/tmp; mkdir -p "$TMPDIR"   # anything's stderr files
L="sh $B/linuxfs"
H=dev.mavergreen.linuxfs.helper
PREFS=$HOME/Library/Preferences/$LINUXFS_DOMAIN.plist
# spec: tests/p3-bundle-README --
#       Leave the guest as it was found, on any exit: only what this run made is removed
had_prefs=0; [ ! -e "$PREFS" ] || { had_prefs=1; defaults export "$LINUXFS_DOMAIN" "$W/prefs-before.plist"; }
volumes_before=$(ls /Volumes)
mounts_before=$(mount | sed -n 's/^.* on \(.*\) (.*/\1/p')
helper=0
cleanup() {
  # spec: tests/p3-bundle-README --
  #       linuxfs mounts still up (a failed step): unmounted by force
  mount | sed -n 's/^linuxfs@.* on \(.*\) (.*/\1/p' | while IFS= read -r m; do
    printf '%s\n' "$mounts_before" | grep -qxF "$m" ||
      { sh "$B/linuxfs" unmount --force "$m" > /dev/null 2>&1 || umount -f "$m" 2>/dev/null; }; done
  # spec: tests/p3-bundle-README --
  #       images of this run still attached
  hdiutil info | awk -v w="$W/" '/^image-path/ { p = (index($0, w) > 0) } p && /^\/dev\/disk[0-9]+[ \t]/ { print $1 }' |
    while read -r d; do hdiutil detach -force -quiet "$d" 2>/dev/null; done
  # spec: tests/p3-bundle-README --
  #       mount points this run left in /Volumes: only new ones, and only when empty
  ls /Volumes | while IFS= read -r v; do
    printf '%s\n' "$volumes_before" | grep -qxF "$v" || rmdir "/Volumes/$v" 2>/dev/null; done
  # spec: tests/p3-bundle-README --
  #       the preferences: as they were, or no file at all when there was none
  defaults delete "$LINUXFS_DOMAIN" 2>/dev/null
  if [ "$had_prefs" = 1 ]; then defaults import "$LINUXFS_DOMAIN" "$W/prefs-before.plist"; else rm -f "$PREFS"; fi
  if [ "$helper" = 1 ]; then   # the root helper: loaded without -w, so launchd's overrides are untouched
    sudo launchctl unload /Library/LaunchDaemons/$H.plist 2>/dev/null
    sudo cp /var/log/$H.log "$O/helper.log" 2>/dev/null && sudo chown "$(id -u)" "$O/helper.log"
    sudo rm -f /Library/LaunchDaemons/$H.plist /Library/PrivilegedHelperTools/$H /var/run/$H.sock /var/log/$H.log
  fi
  # spec: work/: the raw images (gigabytes) go; the small files (errors, logs, askpass's count) are kept in out/work
  mkdir -p "$O/work" && find "$W" -type f -size -1024k ! -name '*.img' -exec cp {} "$O/work/" \; 2>/dev/null
  cp -R "$W/logs" "$O/" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
skip() { n=$((n + 1)); echo "ok $n - # SKIP $1"; }
mounted() { mount | grep -qF " on $1 ("; }
# platform: attach IMAGE [mount]: with no second argument hdiutil asks DA to mount nothing (-nomount) and does not wait on
#           it, and detaches again an image that got no DA mount ("no mountable file systems"). With "mount", DA mounts
#           it as it would a plugged-in disk. $dev is its whole disk, found by the image's
#           path; hdiutil's errors go into $attach_err.
attach() {
  attach_err=$(hdiutil attach $([ "${2:-}" = mount ] || echo -nomount) -imagekey diskimage-class=CRawDiskImage "$1" 2>&1 > /dev/null | grep -v "^/dev/" | tr "\n" " ")
  dev= i=0
  while [ -z "$dev" ] && [ $i -lt 50 ]; do
    dev=$(hdiutil info | awk -v img="$1" '/^image-path/ { sub(/^image-path *: */, ""); p = ($0 == img) } p && /^\/dev\/disk[0-9]+[ \t]/ { print $1; exit }')
    [ -n "$dev" ] || sleep 0.1; i=$((i + 1))
  done
  [ -n "$dev" ] || echo "# attach $1: no disk ($attach_err)"
}
owner() { stat -f %Su "$1"; }
me=$(id -un)
for i in ext4 btrfs xfs ntfs exfat apfs enc; do gzip -dc "images/$i.img.gz" > "$W/$i.img"; done

echo "# Part A: the CLI on images, as $me"
for i in ext4 btrfs xfs ntfs exfat; do
  img=$W/$i.img
  mnt=$($L mount "$img" 2> "$W/$i.mount.err"); rc=$?
  [ $rc -eq 0 ] && mounted "$mnt"; ok $? "$i: linuxfs mount -> '$mnt' ($(tr '\n' ' ' < "$W/$i.mount.err"))"
  [ $rc -eq 0 ] || continue
  echo "hello $i" > "$mnt/a.txt"; ok $? "$i: write"
  [ "$(owner "$mnt/a.txt")" = "$me" ]; ok $? "$i: a new file shows as $me"
  mv "$mnt/a.txt" "$mnt/b.txt"; ok $? "$i: rename"
  case $i in
    exfat) ;;
    *) ln -s b.txt "$mnt/l" && [ "$(readlink "$mnt/l")" = b.txt ]; ok $? "$i: symlink"
       ln "$mnt/b.txt" "$mnt/h" && [ "$(stat -f %l "$mnt/b.txt")" = 2 ]; ok $? "$i: hard link"
       xattr -w user.k v "$mnt/b.txt" 2>/dev/null && [ "$(xattr -p user.k "$mnt/b.txt" 2>/dev/null)" = v ]; ok $? "$i: xattr" ;;
  esac
  case $i in exfat|ntfs) ;; *) chmod 600 "$mnt/b.txt" && [ "$(stat -f %Lp "$mnt/b.txt")" = 600 ]; ok $? "$i: chmod" ;; esac
  $L mount "$img" > /dev/null 2> "$W/$i.twice"; [ $? -ne 0 ] && grep -q "already mounted" "$W/$i.twice"; ok $? "$i: a second mount is refused as already mounted"
  $L status | grep -qF "$mnt"; ok $? "$i: status lists it"
  $L unmount "$mnt"; ok $? "$i: linuxfs unmount"
  ! mounted "$mnt" && [ ! -e "$mnt" ]; ok $? "$i: gone, and the mount point removed"
  mnt=$($L mount --ro "$img" 2>/dev/null) && [ "$(cat "$mnt/b.txt")" = "hello $i" ]; ok $? "$i: remounted read-only, it reads back"
  ( echo x > "$mnt/c.txt" ) 2>/dev/null; [ $? -ne 0 ]; ok $? "$i: read-only refuses a write"
  $L unmount "$mnt" > /dev/null 2>&1
  gzip -c "$img" > "$O/a-$i.img.gz"
done

echo "# Part A2: APFS, read-only, on an image Linux filled"
img=$W/apfs.img
[ "$("$B/linuxfs-probe" "$img")" = "apfs	linuxfs" ]; ok $? "apfs: probed as APFS, named by its volume"
mnt=$($L mount "$img" 2> "$W/apfs.mount.err"); rc=$?
[ $rc -eq 0 ] && mounted "$mnt"; ok $? "apfs: linuxfs mount -> '$mnt' ($(tr '\n' ' ' < "$W/apfs.mount.err"))"
if [ $rc -eq 0 ]; then
  [ "$(cat "$mnt/hello.txt")" = "hello apfs" ] && [ "$(cat "$mnt/d/f50")" = 50 ]; ok $? "apfs: files read back"
  [ "$(ls "$mnt/d" | wc -l | tr -d ' ')" = 50 ]; ok $? "apfs: the directory lists all 50 entries"
  ( echo x > "$mnt/c.txt" ) 2>/dev/null; [ $? -ne 0 ]; ok $? "apfs: mounted read-only without asking; a write is refused"
  $L status | grep -F "$mnt" | grep -q "ro\$"; ok $? "apfs: status says ro"
  $L unmount "$mnt"; ok $? "apfs: linuxfs unmount"
fi
gzip -c "$img" > "$O/a-apfs.img.gz"
# spec: cli/linuxfs --
#       APFSWrite on: experimental writing, through the driver's readwrite; Linux's apfsck judges the result
cp "$img" "$W/apfsrw.img"; img=$W/apfsrw.img
defaults write dev.mavergreen.linuxfs APFSWrite -bool true
mnt=$($L mount "$img" 2> "$W/apfsrw.err"); rc=$?
[ $rc -eq 0 ] && grep -qi experimental "$W/apfsrw.err"; ok $? "apfs, APFSWrite on: mounts, warning it is experimental"
if [ $rc -eq 0 ]; then
  echo "written on 10.9" > "$mnt/new.txt" && mkdir "$mnt/nd" && mv "$mnt/hello.txt" "$mnt/nd/moved.txt"; ok $? "apfs: write, mkdir, rename"
  $L unmount "$mnt"; ok $? "apfs: unmount after writing"
  mnt=$($L mount --ro "$img" 2>/dev/null) && [ "$(cat "$mnt/new.txt")" = "written on 10.9" ] && [ "$(cat "$mnt/nd/moved.txt")" = "hello apfs" ]
  ok $? "apfs: what was written reads back"
  $L unmount "$mnt" > /dev/null 2>&1
fi
defaults delete dev.mavergreen.linuxfs APFSWrite
gzip -c "$img" > "$O/a-apfsrw.img.gz"

echo "# Part A3: encrypted APFS that macOS 27 made (volume Secret, password linuxfs-test, hint test; and Plain)"
img=$W/enc.img
# platform: the files macOS wrote, as `shasum -c` reads them, but not what its daemons rewrite at unmount
want() { grep "^$1 " images/enc-expected.txt | sed "s/^$1 //" | grep -v '  \./\.fseventsd/\|  \./\.Spotlight-V100/\|  \./\.Trashes/'; }
$L mount "$img" < /dev/null > /dev/null 2> "$W/enc.none"; rc=$?
[ $rc -eq 4 ] && grep -q -- --password-stdin "$W/enc.none"; ok $? "enc: with no password and no terminal, exit 4, saying how to give it ($rc: $(tr '\n' ' ' < "$W/enc.none"))"
printf 'wrong\n' | $L mount "$img" --password-stdin > /dev/null 2> "$W/enc.wrong"; rc=$?
[ $rc -eq 4 ] && grep -q "hint: test" "$W/enc.wrong"; ok $? "enc: a wrong password, exit 4 with the hint ($rc: $(tr '\n' ' ' < "$W/enc.wrong"))"
mnt=$(printf 'linuxfs-test\n' | $L mount "$img" --password-stdin 2> "$W/enc.err"); rc=$?
[ $rc -eq 0 ] && mounted "$mnt"; ok $? "enc: the password mounts Secret -> '$mnt' ($(tr '\n' ' ' < "$W/enc.err"))"
if [ $rc -eq 0 ]; then
  want Secret > "$W/enc.want"; (cd "$mnt" && shasum -a 256 -c "$W/enc.want" > "$W/enc.sha" 2>&1); ok $? "enc: every file reads back as macOS wrote it ($(grep -vc ': OK$' "$W/enc.sha") differ)"
  ( echo x > "$mnt/c.txt" ) 2>/dev/null; [ $? -ne 0 ]; ok $? "enc: read-only; a write is refused"
  $L unmount "$mnt"; ok $? "enc: unmount"
fi
mnt=$($L mount "$img" -o opts=vol=1 < /dev/null 2> "$W/plain.err"); rc=$?
[ $rc -eq 0 ] && mounted "$mnt"; ok $? "enc: the unencrypted volume beside it mounts with no password -> '$mnt' ($(tr '\n' ' ' < "$W/plain.err"))"
if [ $rc -eq 0 ]; then
  want Plain > "$W/plain.want"; (cd "$mnt" && shasum -a 256 -c "$W/plain.want" > "$W/plain.sha" 2>&1); ok $? "enc: Plain reads back too"
  $L unmount "$mnt" > /dev/null 2>&1
fi
gzip -c "$img" > "$O/a-enc.img.gz"

echo "# Part B: the root helper"
if ! sudo -n true 2>/dev/null; then
  skip "part B needs passwordless sudo on the guest"
else
  helper=1
  sudo cp "$B/linuxfs-helper" /Library/PrivilegedHelperTools/$H && sudo chmod 755 /Library/PrivilegedHelperTools/$H &&
    sudo cp "$PWD/$H.plist" /Library/LaunchDaemons/$H.plist && sudo chmod 644 /Library/LaunchDaemons/$H.plist &&
    sudo chown root:wheel /Library/PrivilegedHelperTools/$H /Library/LaunchDaemons/$H.plist &&
    sudo launchctl load /Library/LaunchDaemons/$H.plist
  i=0; while [ ! -S /var/run/$H.sock ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -S /var/run/$H.sock ]; ok $? "the helper is loaded and listening"
  gzip -dc images/ext4.img.gz > "$W/b-ext4.img"
  dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$W/b-ext4.img" | awk 'NR == 1 { print $1 }')
  sudo chown root:operator "$dev" "/dev/r${dev#/dev/}"; sudo chmod 640 "$dev" "/dev/r${dev#/dev/}"
  [ ! -r "/dev/r${dev#/dev/}" ]; ok $? "$dev is root-only now, like a real disk"
  [ "$("$B/linuxfs-open" --probe "$dev")" = "$(printf 'ext4\tmy data')" ]; ok $? "the helper probes it for the user"
  $L list | grep -q "^$dev	ext4	my data	-\$"; ok $? "linuxfs list shows it, through the helper"
  mnt=$($L mount "$dev" 2> "$W/b.err"); rc=$?
  [ $rc -eq 0 ] && mounted "$mnt"; ok $? "linuxfs mount $dev goes through the helper -> '$mnt' ($(tr '\n' ' ' < "$W/b.err"))"
  if [ $rc -eq 0 ]; then
    echo helped > "$mnt/h.txt" && [ "$(cat "$mnt/h.txt")" = helped ]; ok $? "write and read through the helper's descriptor"
    ( cd "$mnt" && sleep 30 ) & holder=$!
    sleep 1
    $L unmount "$mnt" > /dev/null 2> "$W/busy.err"; rc=$?
    [ $rc -ne 0 ] && grep -q "busy" "$W/busy.err"; ok $? "a busy unmount is refused and says who holds it: $(tr '\n' ' ' < "$W/busy.err")"
    $L unmount --force "$mnt"; ok $? "unmount --force unmounts it anyway"
    kill $holder 2>/dev/null; wait $holder 2>/dev/null
    ! mounted "$mnt" || false; ok $? "and it is gone"
  fi
  boot=$(df / | awk 'NR == 2 { print $1 }')
  "$B/linuxfs-open" --probe "$boot" > /dev/null 2> "$W/boot.err"; [ $? -ne 0 ] && grep -q "mounted by the Mac" "$W/boot.err"
  ok $? "the helper refuses the boot partition $boot: $(cat "$W/boot.err")"
  "$B/linuxfs-open" --probe "${boot%s[0-9]*}" > /dev/null 2> "$W/bootdisk.err"; [ $? -ne 0 ]
  ok $? "and the boot disk as a whole: $(cat "$W/bootdisk.err")"
  hdiutil detach -quiet "$dev"
  gzip -c "$W/b-ext4.img" > "$O/b-ext4.img.gz"
fi
if [ "$helper" = 1 ]; then
  sudo launchctl unload /Library/LaunchDaemons/$H.plist
  ! sudo launchctl list | grep -q "$H\$" || false; ok $? "the helper unloads"
fi
cp -R "$W/logs" "$O/" 2>/dev/null
echo "1..$n"
exit $bad
