#!/bin/sh
# platform: host-agnostic -- runs cli/linuxfs against stand-ins for lklfuse, the prober, mount, diskutil and lsof
#   usage: cli-test.sh
#          What cli/linuxfs asks of lklfuse and the Mac, without macFUSE: the options it passes, the mount point
#          it picks, the dirty-NTFS fallback, refusals, unmount through diskutil, list and status.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/cli-test.XXXXXX"); T=$(cd "$T" && pwd); trap 'pkill -f "$T/bin/lklfuse" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/Volumes"; : > "$T/mtab"
cat > "$T/bin/mount" <<EOF
#!/bin/sh
cat "$T/mtab"
EOF
cat > "$T/bin/lklfuse" <<EOF
#!/bin/sh
echo "\$*" >> "$T/calls"
mnt=\$(eval echo "\\\${\$#}")
case "\${FAKE_MODE:-ok}" in
  dirty) case "\$*" in *,ro\ *|*,ro) ;; *) echo "ntfs3: volume is dirty and \"force\" flag is not set!"; exit 1 ;; esac ;;
  locked) echo "unable to exclusively lock /tmp/x.lock: Resource temporarily unavailable"; exit 2 ;;
esac
if [ -n "\${FAKE_ENCRYPTED:-}" ]; then
  case "\$*" in
    *passfd=5*) IFS= read -r got <&5 || got=; printf '%s\n' "\$got" > "$T/pwgot"
      [ "\$got" = "\$FAKE_ENCRYPTED" ] || { echo "APFS: wrong password for the encrypted volume (hint: test)"; echo "can't mount disk: Key was rejected by service"; exit 1; } ;;
    *) echo "APFS: volume is encrypted: mount it with its password (hint: test)"; echo "can't mount disk: Required key not available"; exit 1 ;;
  esac
  case "\$*" in *opts=readwrite*) echo "APFS: an encrypted volume can only be mounted read-only"; echo "can't mount disk: Read-only file system"; exit 1 ;; esac
fi
lock=\$(echo "\$*" | tr , "\\n" | sed -n "s/^lock=//p")
mkdir "\$lock.held" 2>/dev/null || { echo "unable to exclusively lock \$lock: Resource temporarily unavailable"; exit 2; }
trap 'rmdir "\$lock.held"' EXIT
echo "linuxfs@x on \$mnt (macfuse, local, nodev, nosuid, synchronous, mounted by me)" >> "$T/mtab"
while grep -qF " on \$mnt (" "$T/mtab"; do sleep 0.1; done
exit 0
EOF
cat > "$T/bin/probe" <<EOF
#!/bin/sh
echo "\$1" >> "$T/probecalls"
case "\$1" in */rdisk3) echo unknown; exit 1 ;; esac
if [ -n "\${FAKE_FUSION:-}" ]; then
  case "\$1" in
    *ssd.img) printf 'apfs\tFused\tfusion-main 00112233445566778899aabbccddeeff\n'; exit 0 ;;
    *hdd.img) printf 'apfs\t\tfusion-tier2 00112233445566778899aabbccddeeff\n'; exit 0 ;;
  esac
fi
case "\${FAKE_PROBE:-ext4}" in
  none) echo unknown; exit 1 ;;
  unreadable) exit 2 ;;
  *) printf '%s\t%s\n' "\${FAKE_PROBE:-ext4}" "\${FAKE_LABEL-my data}" ;;
esac
EOF
cat > "$T/bin/diskutil" <<EOF
#!/bin/sh
case "\$1" in
  unmount) if [ "\$2" = force ]; then echo "diskutil unmount force \$3" >> "$T/calls"; shift; else [ -z "\${FAKE_BUSY:-}" ] || exit 1; fi
           grep -vF " on \$2 (" "$T/mtab" > "$T/mtab.new"; mv "$T/mtab.new" "$T/mtab"; echo "Unmount successful for \$2" ;;
  mount) shift; echo "diskutil mount \$*" >> "$T/dcalls"
         if [ "\${FAKE_DISKUTIL:-}" = busy ]; then echo "Volume on disk5 failed to mount: resource busy" >&2; exit 1; fi
         if [ "\${FAKE_DISKUTIL:-}" = already ]; then echo "Volume on disk5 failed to mount; it is already mounted" >&2; exit 1; fi
         echo "Volume NAME on \${2:-\$1} mounted" ;;
  info) printf '%s\n' "   Device Identifier:         \$2"
        case "\${FAKE_INFO:-}" in none) echo "   Mount Point:" ;; space) echo "   Mount Point:               /Volumes/My Disk" ;; *) echo "   Mount Point:               /Volumes/Fresh" ;; esac ;;
  list) printf '%s\n' "/dev/disk3" "   #:  TYPE NAME  SIZE  IDENTIFIER" "   0:  GUID_partition_scheme  *16 GB  disk3" "   1:  Linux  data  8.0 GB  disk3s1" "   2:  Microsoft Basic Data  win  8.0 GB  disk3s2" "/dev/disk4" "   #:  TYPE NAME  SIZE  IDENTIFIER" "   0:  stick  *4.0 GB  disk4" ;;
esac
EOF
cat > "$T/bin/umount" <<EOF
#!/bin/sh
echo "umount \$*" >> "$T/calls"
if [ "\$1" = -f ]; then shift; else [ -z "\${FAKE_BUSY:-}" ] || exit 1; fi
grep -vF " on \$1 (" "$T/mtab" > "$T/mtab.new"; mv "$T/mtab.new" "$T/mtab"
EOF
chmod 755 "$T/bin/umount"
cat > "$T/bin/hdiutil" <<EOF
#!/bin/sh
[ "\$1" = info ] || exit 1
[ -n "\${FAKE_HDIUTIL_IMAGE:-}" ] || { echo "framework       : 1"; exit 0; }
printf '%s\n' "framework       : 1" "================================================" "image-path      : /elsewhere/other.dmg" "/dev/disk6	GUID_partition_scheme" "/dev/disk6s1	Apple_HFS	/Volumes/Other" "================================================" "image-path      : \$FAKE_HDIUTIL_IMAGE" "/dev/disk7	GUID_partition_scheme	" "/dev/disk7s1	EFI	" "/dev/disk7s2	Linux	"
EOF
chmod 755 "$T/bin/hdiutil"
cat > "$T/bin/lsof" <<EOF
#!/bin/sh
echo "Finder 187 me cwd DIR 1,5 0 1 \$(tail -n 1 "$T/mtab" | sed 's/^.* on \(.*\) (.*/\1/')/d"
EOF
cat > "$T/bin/agent" <<EOF
#!/bin/sh
echo "agent \$*" >> "$T/dcalls"
cat > "$T/agent.pw"
exit \${FAKE_AGENT_RC:-0}
EOF
chmod 755 "$T/bin"/*
# platform: cli/linuxfs is macOS-only and leans on two BSD behaviours GNU coreutils lacks: stat -f FORMAT, and cut -c
#           counting characters, not bytes, in a UTF-8 locale. Off macOS these stand-ins supply both (stat's two formats
#           as GNU's -c; cut -c 1-N through perl), so the suite also runs on the Linux CI host
if [ "$(uname)" != Darwin ]; then
  cat > "$T/bin/stat" <<'EOF2'
#!/bin/sh
[ "$1" = -f ] || exec /usr/bin/stat "$@"
case $2 in %d) f=%d ;; %Lp) f=%a ;; *) echo "stat stand-in: no GNU form for -f $2" >&2; exit 2 ;; esac
shift 2; exec /usr/bin/stat -c "$f" "$@"
EOF2
  cat > "$T/bin/cut" <<'EOF2'
#!/bin/sh
case $#:$1:$2 in 2:-c:1-*) N=${2#1-} LC_ALL=C exec perl -CS -ne 'chomp; print substr($_, 0, $ENV{N}), "\n"' ;; esac
exec /usr/bin/cut "$@"
EOF2
  chmod +x "$T/bin/stat" "$T/bin/cut"
fi
export PATH="$T/bin:$PATH" LINUXFS_LKLFUSE="$T/bin/lklfuse" LINUXFS_PROBE="$T/bin/probe" LINUXFS_OPEN="$T/none"
export LINUXFS_MACHINE_DOMAIN=test.machine LINUXFS_AGENT="$T/bin/agent"
export LINUXFS_DOMAIN=test.linuxfs LINUXFS_STATE="$T/state" LINUXFS_LOGS="$T/logs" LINUXFS_VOLUMES="$T/Volumes" LINUXFS_LOCKS="$T/locks" LINUXFS_WAIT=50
L=$ROOT/cli/linuxfs
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
last() { tail -n 1 "$T/calls"; }
: > "$T/img"; : > "$T/img2"

out=$(sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "$T/Volumes/my data" ]; ok $? "mounts an image at /Volumes/<label> (got '$out')"
c=$(last)
for o in type=ext4 "uid=$(id -u)" "gid=$(id -g)" owner=root local "volname=my data" noappledouble "lock=$T/locks/linuxfs-image-"; do
  case $c in *"$o"*) r=0 ;; *) r=1 ;; esac; ok $r "lklfuse gets $o"
done
case $c in *" $T/img $T/Volumes/my data") r=0 ;; *) r=1 ;; esac; ok $r "lklfuse gets the image's absolute path and the mount point last"
case $c in -f\ *) r=0 ;; *) r=1 ;; esac; ok $r "lklfuse runs in the foreground (-f), since macFUSE does not fork"
sh "$L" status | grep -q "	$T/img	$T/Volumes/my data	ext4	rw\$"; ok $? "status lists the mount"
out=$(FAKE_LABEL="my data" sh "$L" mount "$T/img2" 2>&1)
[ "$out" = "$T/Volumes/my data 1" ]; ok $? "a second volume with the same label gets 'my data 1' (got '$out')"
out=$(sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -ne 0 ]; ok $? "mounting the same image twice is refused"
out=$(sh "$L" unmount "$T/Volumes/my data" 2>&1); rc=$?
[ $rc -eq 0 ] && ! grep -qF "on $T/Volumes/my data (" "$T/mtab"; ok $? "unmount by mount point goes through diskutil"
[ "$(sh "$L" status | grep -c "	$T/img	")" = 0 ]; ok $? "status forgets an unmounted volume"
sh "$L" unmount "$T/img2" > /dev/null 2>&1; ok $? "unmount by image path"

out=$(FAKE_LABEL="a/b" sh "$L" mount "$T/img" 2>&1)
[ "$out" = "$T/Volumes/a-b" ]; ok $? "a label with a slash makes a valid mount point (got '$out')"
out=$(FAKE_BUSY=1 sh "$L" unmount "$T/Volumes/a-b" 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "Finder (pid 187)"; ok $? "a busy unmount fails and names who holds it"
sh "$L" unmount "$T/Volumes/a-b" > /dev/null 2>&1
out=$(FAKE_LABEL="" sh "$L" mount "$T/img" 2>&1)
[ "$out" = "$T/Volumes/img" ]; ok $? "with no label the image's name is used (got '$out')"
sh "$L" unmount "$T/img" > /dev/null 2>&1

# spec: cli/linuxfs --
#       review M5: a long label is cut at a character, never inside one; a label the Mac cannot name a folder by
#       falls back to the image's (or device's) name
long="a$(printf 'é%.0s' $(seq 1 150))"
out=$(LC_ALL=C FAKE_LABEL="$long" sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 0 ] && printf '%s' "$(basename "$out")" | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1; ok $? "a long label is cut at a character boundary, even in the C locale (M5)"
sh "$L" unmount "$T/img" > /dev/null 2>&1
out=$(FAKE_LABEL="$(printf 'bad\377name')" sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "$T/Volumes/img" ]; ok $? "a label that is not UTF-8 falls back to the image's name (got '$out')"
sh "$L" unmount "$T/img" > /dev/null 2>&1
out=$(FAKE_LABEL="$(perl -CO -e 'print "\x{1F600}" x 200')" sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "$T/Volumes/img" ]; ok $? "a label too long for a Mac folder name falls back to the image's name (got '$out')"
sh "$L" unmount "$T/img" > /dev/null 2>&1

: > "$T/a,b=c.img"
out=$(FAKE_LABEL='x,allow_other\' sh "$L" mount "$T/a,b=c.img" 2>&1)
c=$(last)
case $c in *allow_other,*|*,allow_other\ *|*'\'*) r=1 ;; *) r=0 ;; esac; ok $r "a label or file name cannot inject lklfuse options (got: $c)"
case $c in *"volname=x-allow_other-,"*) r=0 ;; *) r=1 ;; esac; ok $r "commas, equals signs and backslashes in the label become -"
case $c in *"fsname=linuxfs@a-b-c.img,"*) r=0 ;; *) r=1 ;; esac; ok $r "and in the image's name"
sh "$L" unmount "$T/a,b=c.img" > /dev/null 2>&1
out=$(FAKE_LABEL="$(printf 'a\033b\177c\rd')" sh "$L" mount "$T/img" 2>&1)
c=$(last)
case $c in *"volname=a-b-c-d,"*) r=0 ;; *) r=1 ;; esac; ok $r "control characters in the label become - (got: $c)"
sh "$L" unmount "$T/img" > /dev/null 2>&1
mkdir -p "$T/home"
(unset LINUXFS_LOCKS; HOME=$T/home sh "$L" mount "$T/img" > /dev/null 2>&1)
case $(last) in *"lock=$T/home/Library/Caches/dev.mavergreen.linuxfs/locks/linuxfs-image-"*) r=0 ;; *) r=1 ;; esac
ok $r "locks live in the user's own cache, not world-writable /tmp (review I2)"
[ "$(stat -f %Lp "$T/home/Library/Caches/dev.mavergreen.linuxfs/locks" 2>/dev/null)" = 700 ]; ok $? "and that directory is the user's alone (700)"
(unset LINUXFS_LOCKS; HOME=$T/home sh "$L" unmount "$T/img" > /dev/null 2>&1)
sh "$L" mount --linux-ids "$T/img" > /dev/null 2>&1
case $(last) in *uid=*|*owner=*) r=1 ;; *) r=0 ;; esac; ok $r "--linux-ids passes no uid=, gid= or owner="
sh "$L" unmount "$T/img" > /dev/null 2>&1

out=$(FAKE_PROBE=ntfs3 FAKE_LABEL=Win FAKE_MODE=dirty sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "read-only" && sh "$L" status | grep -q "ntfs3	ro\$"
ok $? "a dirty NTFS volume mounts read-only, and says so"
case $(last) in *,ro\ *) r=0 ;; *) r=1 ;; esac; ok $r "the retry passes ro"
sh "$L" unmount "$T/img" > /dev/null 2>&1

out=$(FAKE_MODE=locked sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "already mounted by linuxfs" && [ ! -e "$T/Volumes/my data" ]
ok $? "a locked source is refused as already mounted, and the made mount point is removed"
out=$(FAKE_PROBE=none sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "no filesystem linuxfs knows"; ok $? "an unknown filesystem is refused"
echo "/dev/disk3s2 on /Volumes/win (ntfs, local, read-only)" >> "$T/mtab"
out=$(LINUXFS_DA=1 sh "$L" mount disk3s2 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "mounted by the Mac at /Volumes/win"; ok $? "a device the Mac has mounted is refused"
out=$(LINUXFS_DA=1 sh "$L" mount /dev/disk3s1 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "helper"; ok $? "an unreadable device without the helper is refused, naming the helper"
cat > "$T/bin/open" <<EOF
#!/bin/sh
echo "open \$*" >> "$T/calls"
echo "\${LINUXFS_OPEN_INHERITED:-0}" >> "$T/openenv"
case "\$1:\$2" in --probe:*/rdisk4) [ -z "\${FAKE_OPEN_SLEEP:-}" ] || sleep "\$FAKE_OPEN_SLEEP" ;; esac
if [ "\$1" = --probe ] && [ -n "\${FAKE_FUSION:-}" ]; then
  case "\$2" in
    */rdisk3s1) printf 'apfs\tFused\tfusion-main 00112233445566778899aabbccddeeff\n'; exit 0 ;;
    */rdisk4) { [ "\$FAKE_FUSION" = notier2 ] && [ ! -e "$T/tier2here" ]; } || { printf 'apfs\t\tfusion-tier2 00112233445566778899aabbccddeeff\n'; exit 0; } ;;
  esac
  echo unknown; exit 1
fi
if [ "\$1" = --probe ]; then t=\${FAKE_PROBE:-ext4}; [ "\$t" != unreadable ] || t=ext4; printf '%s\t%s\n' "\$t" helped; exit 0; fi
[ "\$1" != --ro ] || shift
shift
[ "\$1" != --also ] || shift 2
exec "\$@"
EOF
chmod 755 "$T/bin/open"
out=$(LINUXFS_OPEN="$T/bin/open" LINUXFS_DA=1 sh "$L" mount /dev/disk3s1 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "$T/Volumes/helped" ]; ok $? "a device mounts through the helper's linuxfs-open (got '$out')"
grep -q "^open /dev/rdisk3s1 $T/bin/lklfuse -f -o .* /dev/fd/3 $T/Volumes/helped\$" "$T/calls"
ok $? "lklfuse gets the raw device's descriptor as /dev/fd/3"
grep -q "lock=$T/locks/linuxfs-rdisk3s1.lock" "$T/calls"; ok $? "the lock is named for the raw device"
LINUXFS_OPEN="$T/bin/open" sh "$L" unmount disk3s1 > /dev/null 2>&1; ok $? "unmount by device name"
# spec: cli/linuxfs --
#       a whole disk being ejected (the agent, P3-2): what linuxfs mounted from its partitions is unmounted
mnt=$(LINUXFS_OPEN="$T/bin/open" LINUXFS_DA=1 sh "$L" mount /dev/disk3s1 2>/dev/null)
LINUXFS_OPEN="$T/bin/open" sh "$L" unmount --force disk3 > /dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ! grep -qF "on $mnt (" "$T/mtab" && [ "$(sh "$L" status | grep -c "/dev/rdisk3s1")" = 0 ]
ok $? "unmount of a whole disk unmounts its partitions' volumes ($rc)"
sh "$L" unmount --force disk3 > /dev/null 2>&1; [ $? -ne 0 ]; ok $? "and with none mounted it says so, as before"
# spec: cli/linuxfs --
#       review M6: an image attached with hdiutil is the same disk as the image file, so both take the image's lock
imglock=image-$(ls -i "$T/img" | awk '{ print $1 }')-$(stat -f %d "$T/img")
: > "$T/calls"
out=$(FAKE_HDIUTIL_IMAGE="$T/img" LINUXFS_OPEN="$T/bin/open" LINUXFS_DA=1 sh "$L" mount /dev/disk7 2>&1)
grep -q "lock=$T/locks/linuxfs-$imglock.lock" "$T/calls"; ok $? "an attached image's device takes the image file's lock (M6)"
LINUXFS_OPEN="$T/bin/open" sh "$L" unmount disk7 > /dev/null 2>&1; : > "$T/calls"
out=$(FAKE_HDIUTIL_IMAGE="$T/img" LINUXFS_OPEN="$T/bin/open" LINUXFS_DA=1 sh "$L" mount /dev/disk7s2 2>&1)
grep -q "lock=$T/locks/linuxfs-$imglock-s2.lock" "$T/calls"; ok $? "and its partition, that lock with the partition's number"
LINUXFS_OPEN="$T/bin/open" sh "$L" unmount disk7s2 > /dev/null 2>&1
out=$(LINUXFS_OPEN="$T/bin/open" FAKE_PROBE=ntfs3 FAKE_MODE=dirty LINUXFS_DA=1 sh "$L" mount /dev/disk3s1 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q "^open --ro /dev/rdisk3s1 " "$T/calls"; ok $? "a dirty NTFS device is opened read-only for the retry"
LINUXFS_OPEN="$T/bin/open" sh "$L" unmount /dev/rdisk3s1 > /dev/null 2>&1
out=$(FAKE_PROBE=unreadable LINUXFS_OPEN="$T/bin/open" sh "$L" list 2>&1)
echo "$out" | grep -q "^/dev/disk3s1	ext4	helped	-\$"; ok $? "list asks the helper for a partition it cannot read"
out=$(FAKE_PROBE=ext4 FAKE_LABEL=data sh "$L" list 2>&1)
echo "$out" | grep -q "^/dev/disk4	ext4	data	-\$" && ! echo "$out" | grep -q "^/dev/disk3	"
ok $? "list shows a disk with no partition table (a superfloppy, an attached image), not a partitioned one"
echo "$out" | grep -q "^/dev/disk3s1	ext4	data	-\$" && echo "$out" | grep -q "^/dev/disk3s2	ext4	data	/Volumes/win\$"
ok $? "list probes each partition and shows the Mac's mount (got: $(echo "$out" | tr '\n' '|'))"
cat > "$T/bin/defaults" <<EOF
#!/bin/sh
f="$T/defaults.\$2"; touch "\$f"
case \$1 in
  read) if [ \$# -eq 2 ]; then echo "{"; awk -F'\t' '{ k = \$1; if (k ~ /[^A-Za-z0-9]/) k = "\\"" k "\\""; print "    " k " = " \$2 ";" }' "\$f"; echo "}"; exit 0; fi
        v=\$(awk -F'\t' -v k="\$3" '\$1 == k { v = \$2 } END { print v }' "\$f"); [ -n "\$v" ] || exit 1; echo "\$v" ;;
  write) grep -v "^\$3	" "\$f" > "\$f.n"; mv "\$f.n" "\$f"; case \$4 in -bool) v=\$5 ;; *) v=\$4 ;; esac
         case \$v in true|yes|YES|1) v=1 ;; false|no|NO|0) v=0 ;; esac; printf '%s\t%s\n' "\$3" "\$v" >> "\$f" ;;
  delete) grep -v "^\$3	" "\$f" > "\$f.n"; mv "\$f.n" "\$f" ;;
esac
EOF
chmod 755 "$T/bin/defaults"
out=$(sh "$L" prefs)
echo "$out" | grep -q "^Automount	on\$" && echo "$out" | grep -q "^ReadOnly	off\$" && echo "$out" | grep -q "^NTFSTakeover	off\$"
ok $? "prefs shows the defaults: Automount on, ReadOnly off, NTFSTakeover off (got: $(echo "$out" | tr '\n' '|'))"
sh "$L" prefs NTFSTakeover on && sh "$L" prefs | grep -q "^NTFSTakeover	on\$"; ok $? "prefs KEY on sets it"
sh "$L" prefs Frobs on > /dev/null 2>&1; [ $? -eq 2 ]; ok $? "an unknown preference is misuse"
sh "$L" prefs ReadOnly maybe > /dev/null 2>&1; [ $? -eq 2 ]; ok $? "a value other than on or off is misuse"
sh "$L" ignore "my data" && sh "$L" prefs | grep -q "^Ignore	my data\$"; ok $? "ignore LABEL opts a volume out, and prefs lists it"
LO="$T/bin/open"
: > "$T/dcalls"
out=$(LINUXFS_OPEN=$LO FAKE_PROBE=ext4 sh "$L" automount disk3s1 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(cat "$T/dcalls")" = "diskutil mount disk3s1" ]; ok $? "automount asks diskutil to mount a Linux partition (got '$out')"
sh "$L" ignore helped; : > "$T/dcalls"
out=$(LINUXFS_OPEN=$LO sh "$L" automount disk3s1 2>&1); rc=$?
[ $rc -eq 3 ] && [ ! -s "$T/dcalls" ]; ok $? "automount skips an ignored volume (exit 3)"
sh "$L" unignore helped; sh "$L" prefs | grep -q "^Ignore	helped\$"; [ $? -ne 0 ]; ok $? "unignore takes it back"
for t in exfat vfat; do
  LINUXFS_OPEN=$LO FAKE_PROBE=$t sh "$L" automount disk3s1 > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "automount leaves $t to the Mac"
done
sh "$L" prefs NTFSTakeover off
LINUXFS_OPEN=$LO FAKE_PROBE=ntfs3 sh "$L" automount disk3s1 > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "automount leaves NTFS to the Mac unless NTFSTakeover is on"
sh "$L" prefs NTFSTakeover on
out=$(LINUXFS_OPEN=$LO FAKE_PROBE=ntfs3 sh "$L" automount disk3s1 2>&1); ok $? "with NTFSTakeover on, automount takes NTFS ($out)"
sh "$L" prefs Automount off
LINUXFS_OPEN=$LO sh "$L" automount disk3s1 > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "with Automount off, automount does nothing (exit 3)"
sh "$L" prefs Automount on
LINUXFS_OPEN=$LO sh "$L" automount "$T/img" > /dev/null 2>&1; [ $? -eq 2 ]; ok $? "automount takes only a disk"
LINUXFS_OPEN=$LO LINUXFS_DA=1 sh "$L" mount disk3s1 > /dev/null 2>&1
FAKE_BUSY=1 LINUXFS_OPEN=$LO sh "$L" unmount --force disk3s1 > /dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q "^umount -f $T/Volumes/helped\$" "$T/calls" && ! grep -q "^diskutil unmount force" "$T/calls" && [ ! -e "$T/Volumes/helped" ]
ok $? "unmount --force unmounts a busy volume (a yanked disk) with umount -f, not through DiskArbitration (P3-3)"
sh "$L" unmount --force disk3s1 > /dev/null 2>&1; [ $? -eq 1 ]; ok $? "unmount --force of what is not mounted fails"
out=$(FAKE_PROBE=apfs FAKE_LABEL="Time Machine" sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "$T/Volumes/Time Machine" ]; ok $? "APFS mounts at /Volumes/<volume name> (got '$out')"
case $(last) in *type=apfs*,ro\ *) r=0 ;; *) r=1 ;; esac; ok $r "APFS is always mounted read-only, unasked"
sh "$L" status | grep -q "apfs	ro\$"; ok $? "and status says ro"
sh "$L" unmount "$T/img" > /dev/null 2>&1
# spec: cli/linuxfs --
#       APFS writing: linux-apfs-rw's experimental write support, only when the user opts in (APFSWrite)
sh "$L" prefs | grep -q "^APFSWrite	off\$"; ok $? "APFSWrite is a preference, off by default"
sh "$L" prefs APFSWrite on
out=$(FAKE_PROBE=apfs FAKE_LABEL="Time Machine" sh "$L" mount "$T/img" 2> "$T/apfs.err"); rc=$?
case $(last) in *type=apfs*,ro\ *) r=1 ;; *opts=readwrite*) r=0 ;; *) r=1 ;; esac; ok $r "with APFSWrite on, APFS mounts read-write through the driver's readwrite (got: $(last))"
grep -qi "experimental" "$T/apfs.err"; ok $? "and the mount warns that APFS writing is experimental"
sh "$L" status | grep -q "apfs	rw\$"; ok $? "status says rw"
sh "$L" unmount "$T/img" > /dev/null 2>&1
FAKE_PROBE=apfs sh "$L" mount --ro "$T/img" > /dev/null 2>&1
case $(last) in *opts=readwrite*) r=1 ;; *,ro\ *) r=0 ;; *) r=1 ;; esac; ok $r "--ro still mounts APFS read-only, without readwrite"
sh "$L" unmount "$T/img" > /dev/null 2>&1
sh "$L" prefs APFSWrite off
LINUXFS_DA=1 LINUXFS_OPEN=$LO FAKE_PROBE=apfs sh "$L" mount disk3s1 > /dev/null 2>&1; ok $? "a device mount takes APFS"
grep "^open " "$T/calls" | grep -v -- "--probe" | tail -n 1 | grep -q "^open --ro /dev/rdisk3s1 "; ok $? "and asks the helper for a read-only descriptor"
LINUXFS_OPEN=$LO sh "$L" unmount disk3s1 > /dev/null 2>&1
# spec: cli/linuxfs --
#       APFS Fusion: one container on two devices, mounted read-only from both
: > "$T/ssd.img"; : > "$T/hdd.img"
out=$(FAKE_FUSION=1 sh "$L" mount "$T/ssd.img" --tier2 "$T/hdd.img" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "$T/Volumes/Fused" ]; ok $? "a Fusion image mounts with --tier2 naming its second device (got '$out')"
case $(last) in *type=apfs*",tier2file=$T/hdd.img"*",ro "*|*type=apfs*",ro"*",tier2file=$T/hdd.img "*) r=0 ;; *) r=1 ;; esac; ok $r "lklfuse gets tier2file= and ro (got: $(last))"
sh "$L" unmount "$T/ssd.img" > /dev/null 2>&1
out=$(FAKE_FUSION=1 sh "$L" mount "$T/ssd.img" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q -- "--tier2"; ok $? "a Fusion image without its second device is refused, saying how (got '$out')"
out=$(FAKE_FUSION=1 sh "$L" mount "$T/hdd.img" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "second device of an APFS Fusion container"; ok $? "the second device alone is refused, saying what it is"
: > "$T/calls"
out=$(FAKE_FUSION=1 LINUXFS_OPEN="$T/bin/open" LINUXFS_DA=1 sh "$L" mount /dev/disk3s1 2>&1); rc=$?
grep "^open " "$T/calls" | grep -v -- --probe | grep -q "^open --ro /dev/rdisk3s1 --also /dev/rdisk4 $T/bin/lklfuse -f -o .*tier2file=/dev/fd/4.* /dev/fd/3 "
ok $? "a Fusion disk finds its second device among the attached disks, and the helper opens both (got '$out')"
LINUXFS_OPEN="$T/bin/open" sh "$L" unmount disk3s1 > /dev/null 2>&1; : > "$T/calls"
: > "$T/dcalls"
FAKE_FUSION=1 LINUXFS_OPEN="$T/bin/open" sh "$L" automount disk4 > /dev/null 2>&1
[ "$(cat "$T/dcalls")" = "diskutil mount disk3s1" ]; ok $? "automount of the second device mounts the container from its main device"
LINUXFS_OPEN="$T/bin/open" sh "$L" unmount disk3s1 > /dev/null 2>&1
FAKE_FUSION=notier2 LINUXFS_OPEN="$T/bin/open" sh "$L" automount disk3s1 > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "automount of a main device whose second is not attached yet waits (exit 3)"
# spec: cli/linuxfs --
#       encrypted APFS: the password comes from the terminal or stdin, reaches lklfuse on a descriptor, never argv
: > "$T/enc.img"; : > "$T/calls"
out=$(FAKE_PROBE=apfs FAKE_ENCRYPTED=s3cret sh "$L" mount "$T/enc.img" < /dev/null 2>&1); rc=$?
[ $rc -eq 4 ] && echo "$out" | grep -q -- "--password-stdin"; ok $? "an encrypted volume with no terminal to ask at exits 4, saying how to give the password (got $rc: '$out')"
echo "$out" | grep -q "(hint: test)\$"; ok $? "and the first exit 4 carries the volume's hint, as the wrong-password message does ('$out')"
out=$(printf 's3cret\n' | FAKE_PROBE=apfs FAKE_ENCRYPTED=s3cret sh "$L" mount "$T/enc.img" --password-stdin 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(cat "$T/pwgot")" = s3cret ] && last | grep -q 'passfd=5'; ok $? "--password-stdin: the password reaches lklfuse on fd 5 (got $rc: '$out')"
! grep -q s3cret "$T/calls" || false; ok $? "and is on no command line"
sh "$L" unmount "$T/enc.img" > /dev/null 2>&1
out=$(printf 'nope\n' | FAKE_PROBE=apfs FAKE_ENCRYPTED=s3cret sh "$L" mount "$T/enc.img" --password-stdin 2>&1); rc=$?
[ $rc -eq 4 ] && echo "$out" | grep -q "wrong password" && echo "$out" | grep -q "hint: test"; ok $? "a wrong password exits 4 with the volume's hint (got $rc: '$out')"
sh "$L" prefs APFSWrite on > /dev/null
out=$(printf 's3cret\n' | FAKE_PROBE=apfs FAKE_ENCRYPTED=s3cret sh "$L" mount "$T/enc.img" --password-stdin 2>&1); rc=$?
case $(last) in *opts=readwrite*) r=1 ;; *,ro" "*|*,ro,*) r=$rc ;; *) r=1 ;; esac
[ $r -eq 0 ] && echo "$out" | grep -q "read-only"; ok $? "with APFSWrite on, an encrypted volume mounts read-only, saying so (got $rc: '$out'; $(last))"
sh "$L" unmount "$T/enc.img" > /dev/null 2>&1; sh "$L" prefs APFSWrite off > /dev/null
out=$(echo x | FAKE_PROBE=ext4 sh "$L" mount "$T/enc.img" --password-stdin 2>&1); rc=$?
[ $rc -eq 2 ] || { [ $rc -eq 1 ] && echo "$out" | grep -q "encrypted APFS"; }; ok $? "--password-stdin on a volume that is not APFS is refused (got $rc: '$out')"
sh "$L" unmount "$T/enc.img" > /dev/null 2>&1
mkdir -p "$T/dam"
LINUXFS_DA=1 FAKE_PROBE=apfs FAKE_ENCRYPTED=s3cret LINUXFS_OPEN="$T/bin/open" sh "$L" da-mount --asked /dev/disk2s1 "$T/dam" < /dev/null > /dev/null 2>&1; [ $? -eq 4 ]; ok $? "da-mount of an encrypted volume exits 4, for the bundle's mount program to ask"
# spec: tools/fs.c run_cli -- the mount program passes --password-stdin to da-mount, in any order with --asked and --ro
for order in "--asked --password-stdin" "--password-stdin --asked" "--ro --password-stdin --asked"; do
  rm -f "$T/pwgot"
  out=$(printf 's3cret\n' | LINUXFS_DA=1 FAKE_PROBE=apfs FAKE_ENCRYPTED=s3cret LINUXFS_OPEN="$T/bin/open" sh "$L" da-mount $order /dev/disk2s1 "$T/dam" 2>&1); rc=$?
  [ $rc -eq 0 ] && [ "$(cat "$T/pwgot" 2>/dev/null)" = s3cret ]; ok $? "da-mount $order mounts an encrypted volume with the password from stdin (got $rc: '$out')"
  sh "$L" unmount "$T/dam" > /dev/null 2>&1; sh "$L" unmount disk2s1 > /dev/null 2>&1
done
out=$(printf 'nope\n' | LINUXFS_DA=1 FAKE_PROBE=apfs FAKE_ENCRYPTED=s3cret LINUXFS_OPEN="$T/bin/open" sh "$L" da-mount --asked --password-stdin /dev/disk2s1 "$T/dam" 2>&1); rc=$?
[ $rc -eq 4 ] && echo "$out" | grep -q "wrong password"; ok $? "da-mount --password-stdin with a wrong password exits 4 (got $rc: '$out')"
# spec: cli/linuxfs --
#       review M7: after a reboot a record's pid may belong to some other process; it is not a mount
sleep 60 & sp=$!
printf '%s\t%s\t%s\t%s\n' "$T/gone.img" "$T/Volumes/gone" ext4 rw > "$T/state/$sp"
! sh "$L" status | grep -q gone || false; ok $? "a record whose pid is not that lklfuse is not listed (M7)"
[ ! -e "$T/state/$sp" ]; ok $? "and is forgotten"
kill $sp; wait $sp 2>/dev/null
# spec: cli/linuxfs --
#       a disk pulled out: lklfuse takes its mount down and exits, and its record goes stale; the empty folder linuxfs made
#       for it in /Volumes goes with the record, not a folder the user named, and not one with anything in it
sleep 60 & sp=$!; sleep 60 & sp2=$!; sleep 60 & sp3=$!
mkdir -p "$T/Volumes/pulled" "$T/mine" "$T/Volumes/full" && touch "$T/Volumes/full/keep"
printf '%s\t%s\t%s\t%s\n' /dev/rdisk7s1 "$T/Volumes/pulled" ext4 rw > "$T/state/$sp"
printf '%s\t%s\t%s\t%s\n' /dev/rdisk8s1 "$T/mine" ext4 rw > "$T/state/$sp2"
printf '%s\t%s\t%s\t%s\n' /dev/rdisk9s1 "$T/Volumes/full" ext4 rw > "$T/state/$sp3"
kill $sp $sp2 $sp3; wait $sp $sp2 $sp3 2>/dev/null
sh "$L" status > /dev/null
[ ! -e "$T/Volumes/pulled" ]; ok $? "a stale record's empty folder in /Volumes is removed with it (a pulled disk)"
[ -d "$T/mine" ] && [ -f "$T/Volumes/full/keep" ]; ok $? "but not a mount point the user chose, nor a folder with something in it"
rmdir "$T/mine"; rm -rf "$T/Volumes/full"
# spec: cli/linuxfs --
#       a device mounts through DiskArbitration (diskutil mount); the bundle's mount program calls back as da-mount
DU=$T/dcalls; : > "$DU"
out=$(sh "$L" mount /dev/disk5 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = /Volumes/Fresh ] && [ "$(cat "$DU")" = "diskutil mount disk5" ]; ok $? "mount DEVICE runs diskutil mount and prints the mount point (got '$out')"
: > "$DU"; sh "$L" mount --ro /dev/disk5 > /dev/null 2>&1
[ "$(cat "$DU")" = "diskutil mount readOnly disk5" ]; ok $? "mount --ro DEVICE runs diskutil mount readOnly"
for a in "-o x" --linux-ids "--tier2 $T/img" "$T/Volumes"; do
  : > "$DU"; out=$(sh "$L" mount /dev/disk5 $a 2>&1); rc=$?
  [ $rc -eq 2 ] && [ ! -s "$DU" ] && echo "$out" | grep -q "for a device, use linuxfs prefs; these options are for image files"; ok $? "mount DEVICE $a is misuse (exit 2)"
done
out=$(sh "$L" mount "$T/img" 2>&1); rc=$?
[ $rc -eq 0 ] && last | grep -q "$T/img "; ok $? "an image still mounts directly with lklfuse"
sh "$L" unmount "$T/img" > /dev/null 2>&1
out=$(FAKE_DISKUTIL=already sh "$L" mount /dev/disk5 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "already mounted"; ok $? "diskutil's 'already mounted' is passed through with a failure (got $rc: '$out')"
: > "$DU"; rm -f "$T/agent.pw"
out=$(printf 's3cret\n' | sh "$L" mount --password-stdin /dev/disk5 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(cat "$DU")" = "agent --offer disk5
diskutil mount disk5" ] && [ "$(cat "$T/agent.pw")" = s3cret ]; ok $? "--password-stdin offers the password to the agent, then mounts (got $rc)"
: > "$DU"
out=$(printf 's3cret\n' | FAKE_AGENT_RC=1 sh "$L" mount --password-stdin /dev/disk5 2>&1); rc=$?
[ $rc -eq 4 ] && echo "$out" | grep -q "no one is logged in at the console to unlock /dev/disk5" && ! grep -q diskutil "$DU"; ok $? "with no agent answering, --password-stdin exits 4 and diskutil never runs (got $rc: '$out')"
LINUXFS_OPEN=$LO sh "$L" da-mount --asked /dev/disk3s1 "$T/dam" > /dev/null 2>&1; [ $? -eq 2 ]; ok $? "da-mount without LINUXFS_DA is misuse (exit 2)"
DA() { LINUXFS_DA=1 LINUXFS_OPEN=$LO sh "$L" da-mount "$@"; }
sh "$L" prefs Automount off
DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "da-mount with Automount off exits 3"
DA --asked /dev/disk3s1 "$T/dam" > /dev/null 2>&1; ok $? "and with --asked it mounts"
sh "$L" unmount disk3s1 > /dev/null 2>&1; sh "$L" prefs Automount on
sh "$L" ignore helped
DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "da-mount of an ignored label exits 3"
DA --asked /dev/disk3s1 "$T/dam" > /dev/null 2>&1; ok $? "and with --asked it mounts"
sh "$L" unmount disk3s1 > /dev/null 2>&1; sh "$L" unignore helped
defaults write test.machine ReadOnly -bool true
DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1
case $(last) in *,ro\ *) r=0 ;; *) r=1 ;; esac; ok $r "ReadOnly set in the machine domain only mounts read-only"
sh "$L" unmount disk3s1 > /dev/null 2>&1; defaults delete test.machine ReadOnly
DA --ro /dev/disk3s1 "$T/dam" > /dev/null 2>&1
case $(last) in *,ro\ *) r=0 ;; *) r=1 ;; esac; ok $r "da-mount --ro mounts read-only"
sh "$L" unmount disk3s1 > /dev/null 2>&1
DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1
case $(last) in *,ro\ *|*,ro) r=1 ;; *) r=0 ;; esac; ok $r "and without either it is read-write"
sh "$L" unmount disk3s1 > /dev/null 2>&1
(FAKE_FUSION=1; export FAKE_FUSION; DA /dev/disk4 "$T/dam" > /dev/null 2>&1); [ $? -eq 3 ]; ok $? "da-mount of a Fusion tier2 device exits 3"
rm -f "$T/tier2here"; (sleep 1; touch "$T/tier2here") &
(FAKE_FUSION=notier2; export FAKE_FUSION; DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1); ok $? "a Fusion main device waits for its partner, then mounts"
wait; sh "$L" unmount disk3s1 > /dev/null 2>&1; rm -f "$T/tier2here"
(FAKE_FUSION=notier2 LINUXFS_FUSION_WAIT=5; export FAKE_FUSION LINUXFS_FUSION_WAIT; DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1); [ $? -eq 3 ]; ok $? "and without its partner it exits 3 after the wait"
(LINUXFS_ALL_USERS=1; export LINUXFS_ALL_USERS; DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1)
case $(last) in *allow_other,uid=99,gid=99*) r=0 ;; *) r=1 ;; esac; case $(last) in *owner=root*) r=1 ;; esac
ok $r "LINUXFS_ALL_USERS=1 mounts allow_other,uid=99,gid=99, without owner=root"
sh "$L" unmount disk3s1 > /dev/null 2>&1
sh "$L" unmount disk3s1 > /dev/null 2>&1
for t in exfat vfat; do
  (FAKE_PROBE=$t; export FAKE_PROBE; DA --asked /dev/disk3s1 "$T/dam" > /dev/null 2>&1); [ $? -eq 3 ]; ok $? "da-mount leaves $t to the Mac, even asked"
done
sh "$L" prefs NTFSTakeover off
(FAKE_PROBE=ntfs3; export FAKE_PROBE; DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1); [ $? -eq 3 ]; ok $? "da-mount leaves NTFS to the Mac unless NTFSTakeover is on"
(FAKE_PROBE=ntfs3; export FAKE_PROBE; DA --asked /dev/disk3s1 "$T/dam" > /dev/null 2>&1); ok $? "but an asked-for NTFS mount goes ahead"
sh "$L" unmount disk3s1 > /dev/null 2>&1
sh "$L" prefs NTFSTakeover on
(FAKE_PROBE=ntfs3; export FAKE_PROBE; DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1); ok $? "with NTFSTakeover on, da-mount takes NTFS"
sh "$L" unmount disk3s1 > /dev/null 2>&1; sh "$L" prefs NTFSTakeover off
(FAKE_DISKUTIL=busy; export FAKE_DISKUTIL; sh "$L" mount /dev/disk5 > "$T/out" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "resource busy" "$T/out"; ok $? "a diskutil failure other than 'already mounted' passes its message through with a failure"
out=$(FAKE_INFO=space sh "$L" mount /dev/disk5 2>&1)
[ "$out" = "/Volumes/My Disk" ]; ok $? "a mount point with a space is printed whole (got '$out')"
out=$(FAKE_INFO=none sh "$L" mount /dev/disk5 2>&1); rc=$?
[ $rc -ne 0 ] && [ -n "$out" ] && ! echo "$out" | grep -q '^/Volumes'; ok $? "a mount with no Mount Point afterwards fails, saying so (got $rc: '$out')"
: > "$DU"
out=$(printf 'pw\n' | FAKE_AGENT_RC=127 sh "$L" mount --password-stdin /dev/disk5 2>&1); rc=$?
[ $rc -eq 1 ] && ! grep -q diskutil "$DU" && ! echo "$out" | grep -q "no one is logged in"; ok $? "an agent that cannot be run is exit 1, not 4 (got $rc: '$out')"
sh "$L" prefs Automount on
defaults write test.machine Automount -bool true; sh "$L" prefs Automount off
DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "a user-domain off overrides a machine-domain on"
defaults delete test.machine Automount; sh "$L" prefs Automount on
defaults write test.machine "Ignore:helped" -bool true
DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "an Ignore:LABEL in the machine domain only is honoured"
defaults delete test.machine "Ignore:helped"
: > "$T/probecalls"; : > "$T/openenv"
(LINUXFS_OPEN_INHERITED=1; export LINUXFS_OPEN_INHERITED; DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1); ok $? "LINUXFS_OPEN_INHERITED=1 still mounts through the opener"
[ ! -s "$T/probecalls" ] && [ -s "$T/openenv" ] && ! grep -qv '^1$' "$T/openenv"; ok $? "and only through it: no direct probe, every opener call inherited"
sh "$L" unmount disk3s1 > /dev/null 2>&1
for f in 1 notier2; do
  s0=$(date +%s)
  (FAKE_FUSION=$f LINUXFS_OPEN_INHERITED=1; export FAKE_FUSION LINUXFS_OPEN_INHERITED; DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1); rc=$?
  (FAKE_FUSION=$f LINUXFS_OPEN_INHERITED=1; export FAKE_FUSION LINUXFS_OPEN_INHERITED; DA /dev/disk4 "$T/dam" > /dev/null 2>&1); rc2=$?
  [ $rc -eq 3 ] && [ $rc2 -eq 3 ] && [ $(( $(date +%s) - s0 )) -lt 5 ]; ok $? "inherited, da-mount of a Fusion main or tier2 device exits 3 at once ($f)"
done
s0=$(date +%s)
(FAKE_FUSION=notier2 LINUXFS_FUSION_WAIT=5 FAKE_OPEN_SLEEP=3; export FAKE_FUSION LINUXFS_FUSION_WAIT FAKE_OPEN_SLEEP; DA /dev/disk3s1 "$T/dam" > /dev/null 2>&1); rc=$?
[ $rc -eq 3 ] && [ $(( $(date +%s) - s0 )) -lt 8 ]; ok $? "the Fusion wait is wall-clock time, not iterations (took $(( $(date +%s) - s0 )) s)"
! sh "$L" help 2>&1 | grep -q da-mount; ok $? "usage does not list the internal da-mount"
sh "$L" frobnicate > /dev/null 2>&1; [ $? -eq 2 ]; ok $? "an unknown command is misuse (exit 2)"
echo "1..$n"; exit $bad
