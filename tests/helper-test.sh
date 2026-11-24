#!/bin/sh
# platform: macOS-only -- linuxfs-helper uses getpeereid, getmntinfo and SCM_RIGHTS as Darwin has them
#   usage: helper-test.sh
#          Builds linuxfs-helper and linuxfs-open for 10.9 and runs the policy test, then, with the helper on a
#          test socket (--test-files: regular files stand in for disks), checks what linuxfs-open gets: the
#          probe, a read-write or read-only descriptor on fd 3, a refusal for an unknown filesystem, and exit 3
#          with no helper; the UUID (--uuid), and the /etc/fstab edits (--noauto-add, --noauto-remove) on a file named by
#          LINUXFS_FSTAB; and the install's migration (--migrate-prefs) of Ignore:<LABEL> preferences to fstab entries.
#          Linux makes the ext4 image.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
D=$HOME/Library/Caches/mm-build/linuxfs-helper-test; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
cc() { "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld "$@"; }
cc -DLINUXFS_PROBE_NO_MAIN -o "$D/helper" "$ROOT/tools/helper.c" "$ROOT/tools/probe.c" "$ROOT/tools/fstab.c" "$ROOT/tools/fsrules.c" \
  "$ROOT/tools/plist.c" -framework IOKit -framework CoreFoundation || exit 1
cc -DLINUXFS_PROBE_NO_MAIN -o "$D/open" "$ROOT/tools/open.c" "$ROOT/tools/probe.c" || exit 1
cc -o "$D/probe" "$ROOT/tools/probe.c" "$ROOT/tools/fsrules.c" || exit 1
cc -DLINUXFS_PROBE_NO_MAIN -o "$D/policy" "$ROOT/tests/helper-policy-test.c" "$ROOT/tools/probe.c" "$ROOT/tools/fstab.c" "$ROOT/tools/fsrules.c" \
  "$ROOT/tools/plist.c" -framework IOKit -framework CoreFoundation || exit 1
sh "$ROOT/build/linux-host.sh" sh -c 'truncate -s 32M "$1/ext4.img" && mkfs.ext4 -q -F -L helped "$1/ext4.img" &&
  truncate -s 32M "$1/mydata.img" && mkfs.ext4 -q -F -L "my data" -U 0123abcd-4567-89ef-0123-456789abcdef "$1/mydata.img" &&
  truncate -s 64M "$1/ssd.img" && truncate -s 256M "$1/hdd.img" && mkapfs -L Fused -F "$1/hdd.img" "$1/ssd.img" > /dev/null' _ "$D" || exit 1
# spec: tools/helper.c LINUXFS_TEST_DISKS -- the disks attached, for noauto-add (tests only, not root: these files stand in
#       for /dev's raw disks): ext4 "helped", and ext4 "my data" with UUID 0123ABCD-4567-89EF-0123-456789ABCDEF
export LINUXFS_TEST_DISKS="$D/ext4.img:$D/mydata.img"
"$D/policy" > "$D/policy.tap"; bad=$?
grep -v '^1\.\.' "$D/policy.tap"
n=$(grep -c '^ok\|^not ok' "$D/policy.tap")
head -c 1048576 /dev/zero > "$D/zero.img"
S=$D/sock; export LINUXFS_HELPER_SOCKET=$S
F=$D/fstab; export LINUXFS_FSTAB=$F
"$D/helper" --socket "$S" --test-files --timeout 3 & hp=$!
att() { hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/$1" | awk 'NR == 1 { print $1 }'; }
e=$(att ext4.img); devs=$e
trap 'kill $hp 2>/dev/null; for d in $devs; do hdiutil detach -quiet -force "$d" 2>/dev/null; done' EXIT
i=0; while [ ! -S "$S" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
T=$(printf '\t')
[ "$("$D/open" --probe "$D/ext4.img")" = "ext4${T}helped" ]; ok $? "linuxfs-open --probe gets the helper's answer"
[ "$("$D/open" "$D/ext4.img" "$D/probe" /dev/fd/3)" = "ext4${T}helped" ]; ok $? "the program runs with the partition on fd 3"
"$D/open" "$D/ext4.img" /bin/sh -c 'printf x >&3' 2>/dev/null; ok $? "a read-write descriptor can be written"
"$D/open" --ro "$D/ext4.img" /bin/sh -c 'printf x >&3' 2>/dev/null; [ $? -ne 0 ]; ok $? "a read-only descriptor cannot"
out=$("$D/open" "$D/zero.img" /bin/echo 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "no filesystem linuxfs knows"; ok $? "an unknown filesystem is refused, and the program not run"
# spec: tools/helper.c --
#       review M2: a disk that never answers (a FIFO with no writer: open blocks) must not hold up anyone else,
#       and the stuck request must end by itself
mkfifo "$D/stuck"
start=$(date +%s); LINUXFS_OPEN_TIMEOUT=10 "$D/open" --probe "$D/stuck" > "$D/stuck.out" 2>&1 & sp=$!
sleep 1
[ "$("$D/open" --probe "$D/ext4.img")" = "ext4${T}helped" ]; ok $? "a stuck request does not hold up the next (M2)"
wait $sp; rc=$?; took=$(($(date +%s) - start))
[ $rc -ne 0 ] && [ $took -le 8 ]; ok $? "the stuck request ends by itself, refused (exit $rc after ${took}s)"
perl -MIO::Socket::UNIX -e '$s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die; $c = $s->accept; sleep 30' "$D/mute.sock" & mp=$!
i=0; while [ ! -S "$D/mute.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
start=$(date +%s); LINUXFS_HELPER_SOCKET=$D/mute.sock LINUXFS_OPEN_TIMEOUT=2 "$D/open" --probe "$D/ext4.img" > "$D/mute.out" 2>&1; rc=$?
took=$(($(date +%s) - start)); kill $mp 2>/dev/null; wait $mp 2>/dev/null
[ $rc -eq 3 ] && [ $took -le 5 ] && grep -q "did not answer" "$D/mute.out"; ok $? "linuxfs-open gives up on a helper that never answers (exit $rc after ${took}s: $(cat "$D/mute.out"))"
# spec: tools/helper.c --
#       APFS Fusion: the probe's third field comes through, and --also puts a second device on fd 4
"$D/open" --probe "$D/hdd.img" | grep -q "^apfs${T}${T}fusion-tier2 [0-9a-f]\{32\}\$"; ok $? "the helper passes on a Fusion device's role"
[ "$("$D/open" --ro "$D/ssd.img" --also "$D/hdd.img" "$D/probe" /dev/fd/4 | cut -f 3 | cut -d' ' -f 1)" = fusion-tier2 ]; ok $? "--also: the second device on fd 4"
"$D/open" --ro "$D/ssd.img" --also "$D/hdd.img" /bin/sh -c 'printf x >&4' 2>/dev/null; [ $? -ne 0 ]; ok $? "and read-only"
"$D/open" --ro "$D/ssd.img" --also "$D/zero.img" /bin/echo > /dev/null 2>&1; [ $? -ne 0 ]; ok $? "a second device the helper refuses stops the program from running"
# spec: tools/open.c --
#       inherited mode (LINUXFS_OPEN_INHERITED=1): fd 3 is the device already, opened by the mount program as root before
#       it dropped privileges; the helper is never contacted (its socket here is a path nothing listens on)
NS=$D/nobody.sock; I="env LINUXFS_OPEN_INHERITED=1 LINUXFS_HELPER_SOCKET=$NS"
[ "$($I "$D/open" --probe "$e" 3<"/dev/r${e#/dev/}")" = "ext4${T}helped" ]; ok $? "inherited --probe reads the label from fd 3 (the attached ext4 disk)"
[ "$($I "$D/open" "$e" "$D/probe" /dev/fd/3 3<"/dev/r${e#/dev/}")" = "ext4${T}helped" ]; ok $? "inherited exec form: the program gets fd 3 as it is"
[ "$($I "$D/open" --ro "$e" "$D/probe" /dev/fd/3 3<"/dev/r${e#/dev/}")" = "ext4${T}helped" ]; ok $? "inherited --ro is accepted"
cp "$D/ext4.img" "$D/patched.img"; printf WXYZ | dd of="$D/patched.img" conv=notrunc 2>/dev/null
[ "$($I "$D/open" --probe "$e" 3<"$D/patched.img" | cut -f 1)" = ext4 ]; ok $? "inherited --probe works on a patched copy too"
[ "$( { $I "$D/open" --probe "$e" > /dev/null; dd bs=4 count=1 <&3 2>/dev/null; } 3<"$D/patched.img" )" = WXYZ ]; ok $? "inherited --probe does not move fd 3's offset"
[ "$($I "$D/open" "$e" /bin/sh -c 'dd bs=4 count=1 <&3 2>/dev/null' 3<"$D/patched.img")" = WXYZ ]; ok $? "the exec form leaves fd 3's offset alone too"
$I "$D/open" "$e" --also "$e" /bin/echo ran 3<"/dev/r${e#/dev/}" > "$D/also.out" 2>&1; rc=$?
[ $rc -eq 1 ] && ! grep -q ran "$D/also.out"; ok $? "inherited --also exits 1 and does not run the program (rc $rc)"
$I "$D/open" "$e" /bin/echo ran 3<&- > "$D/nofd.out" 2>&1; rc=$?
[ $rc -eq 1 ] && ! grep -q '^ran' "$D/nofd.out" && grep -qi 'fd 3\|descriptor 3' "$D/nofd.out"; ok $? "inherited with fd 3 closed exits 1 and says so (rc $rc: $(head -1 "$D/nofd.out"))"
$I "$D/open" --probe "$e" 3<&- > "$D/nofd.out" 2>&1; rc=$?
[ $rc -eq 1 ]; ok $? "inherited --probe with fd 3 closed exits 1 (rc $rc)"
env LINUXFS_OPEN_INHERITED=0 LINUXFS_HELPER_SOCKET=$NS "$D/open" --probe "$e" 3<"/dev/r${e#/dev/}" > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "LINUXFS_OPEN_INHERITED other than 1 is the helper's way (no helper: exit 3)"
$I "$D/open" "$e" /bin/echo 3<"/dev/r${e#/dev/}" > /dev/null 2>&1; rc=$?
[ $rc -eq 0 ]; ok $? "inherited exec form never touches the helper socket (rc $rc)"
$I "$D/open" 3<"/dev/r${e#/dev/}" > /dev/null 2>&1; [ $? -eq 2 ]; ok $? "inherited misuse still exits 2"
# spec: tools/open.c fuse_chan -- --fuse-chan CHAN:FD [--lock FILE]: before the mount, the lock is checked, "R" goes to root, and the
#       one descriptor root sends comes back as FD for the program; a lock held, or anything but one descriptor, runs nothing
cc -o "$D/chanroot" "$ROOT/tests/lib/chan-root.c" || exit 1
cr() { MODE=$1; shift; env LINUXFS_OPEN_INHERITED=1 "$D/chanroot" "$MODE" "$D/open" "$@" 3<"/dev/r${e#/dev/}" 2>&1; }
out=$(cr device --fuse-chan 6:4 --lock "$D/chan.lock" "$e" /bin/sh -c 'printf x >&4'); echo "$out" | tr '\n' ' ' > "$D/cr.txt"
[ "$(echo "$out" | tr '\n' ' ')" = "ready byte x exit 0 " ]; ok $? "--fuse-chan: ready, the device comes back as fd 4, the program writes to it ($(cat "$D/cr.txt"))"
out=$(cr device --fuse-chan 6:4 "$e" /bin/sh -c 'ls -l /dev/fd/6 > /dev/null 2>&1; echo chan-closed=$?'); echo "$out" | grep -q 'chan-closed=1'
ok $? "and the channel is closed for the program"
perl -e 'use Fcntl ":flock"; open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; print "held\n"; $| = 1; sleep 20' "$D/held.lock" > "$D/held.out" 2>&1 & lkp=$!
i=0; while ! grep -q held "$D/held.out" 2> /dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
out=$(cr device --fuse-chan 6:4 --lock "$D/held.lock" "$e" /bin/echo ran); kill $lkp 2>/dev/null; wait $lkp 2>/dev/null
echo "$out" | grep -q '^not ready$' && echo "$out" | grep -q 'unable to exclusively lock' && echo "$out" | grep -q '^exit 1$' && ! echo "$out" | grep -q '^ran'
ok $? "a lock held elsewhere: no \"R\", the program does not run, exit 1 ($(echo "$out" | tr '\n' ' '))"
out=$(cr two --fuse-chan 6:4 "$e" /bin/echo ran); echo "$out" | grep -q '^exit 1$' && ! echo "$out" | grep -q '^ran'; ok $? "two descriptors from root: refused, the program does not run ($(echo "$out" | tr '\n' ' '))"
out=$(cr device --fuse-chan 4:4 "$e" /bin/echo ran); echo "$out" | grep -q '^not ready$' && echo "$out" | grep -q '^exit 1$'; ok $? "--fuse-chan CHAN:FD with the same number twice is refused"
out=$(cr device --fuse-chan 6:3 "$e" /bin/echo ran); echo "$out" | grep -q '^not ready$' && echo "$out" | grep -q '^exit 1$'; ok $? "--fuse-chan with FD 3 (the disk) is refused"
# spec: tools/helper.c -- the UUID, through the helper (the CLI's linuxfs ignore, when it cannot read the raw node)
[ "$("$D/open" --uuid "$D/ext4.img")" = "$("$D/probe" --uuid "$D/ext4.img")" ]; ok $? "linuxfs-open --uuid gets the helper's answer, the probe's UUID"
"$D/open" --uuid "$D/zero.img" > /dev/null 2>&1; [ $? -eq 1 ]; ok $? "a disk with no filesystem has no UUID: exit 1"
# spec: tools/helper.c -- /etc/fstab edits over the socket (LINUXFS_FSTAB here), through linuxfs-open
printf '# the Mac'"'"'s\nLABEL=Backup none hfs ro\n' > "$F"
"$D/open" --noauto-add "LABEL=my data" linuxfs_ext4; ok $? "linuxfs-open --noauto-add LABEL=<label> BUNDLE exits 0"
[ "$(cat "$F")" = "# the Mac's
LABEL=Backup none hfs ro
LABEL=my\\040data none linuxfs_ext4 rw,noauto # linuxfs" ]; ok $? "the helper appends the escaped entry, keeping the rest ($(tr '\n' '|' < "$F"))"
out=$("$D/open" --noauto-add "LABEL=a#b" linuxfs_ext4 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "a label with #"; ok $? "a refusal is printed and exits 1 (got $rc: '$out')"
"$D/open" --noauto-remove "LABEL=my data"; ok $? "linuxfs-open --noauto-remove LABEL=<label> exits 0"
[ "$(cat "$F")" = "# the Mac's
LABEL=Backup none hfs ro" ]; ok $? "and the entry is gone"
"$D/open" --noauto-add "LABEL=x" > /dev/null 2>&1; [ $? -eq 2 ]; ok $? "--noauto-add with no bundle is misuse (exit 2)"
# spec: tools/helper.c -- noauto-add only for a volume attached now: the helper itself (root) probes the attached disks for one of
#       the stated bundle's type with that UUID or volume name; a console user cannot keep any other volume from mounting
out=$("$D/open" --noauto-add "LABEL=nowhere" linuxfs_ext4 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "no attached linuxfs volume matches" && ! grep -q nowhere "$F"; ok $? "noauto-add for a volume not attached is refused (got $rc: '$out')"
out=$("$D/open" --noauto-add "LABEL=helped" linuxfs_btrfs 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "no attached linuxfs volume matches"; ok $? "noauto-add with another filesystem's bundle is refused (got $rc: '$out')"
"$D/open" --noauto-add "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF" linuxfs_ext4 && grep -q "^UUID=0123ABCD-4567-89EF-0123-456789ABCDEF none linuxfs_ext4" "$F"; ok $? "noauto-add by the attached disk's UUID is done"
"$D/open" --noauto-remove "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF"
out=$(LINUXFS_TEST_DISKS= "$D/open" --noauto-add "LABEL=helped" linuxfs_ext4 2>&1); [ "$out" = "" ]; ok $? "the helper's disks are its own, not the client's environment (got '$out')"
# spec: tools/helper.c -- the disk scan (noauto-add's, the migration's) is bounded: each disk is probed in a child, and past the
#       scan's deadline (10 s; LINUXFS_SCAN_SECONDS when not root) the rest are skipped, "(a disk did not answer)"
mkfifo "$D/hang"
HS=$D/hang.sock; LINUXFS_TEST_DISKS="$D/hang:$D/ext4.img" LINUXFS_SCAN_SECONDS=1 "$D/helper" --socket "$HS" --test-files --timeout 5 & hp2=$!
i=0; while [ ! -S "$HS" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
cp "$F" "$D/fstab.before"
start=$(date +%s); out=$(LINUXFS_HELPER_SOCKET=$HS LINUXFS_OPEN_TIMEOUT=10 "$D/open" --noauto-add "LABEL=helped" linuxfs_ext4 2>&1); rc=$?; took=$(($(date +%s) - start))
kill $hp2; wait $hp2 2>/dev/null
[ $rc -eq 1 ] && [ "$out" = "linuxfs-open: no attached linuxfs volume matches (a disk did not answer)" ] && [ $took -le 3 ]; ok $? "a disk that never answers ends the scan at its deadline, saying so (got $rc in ${took}s: '$out')"
cmp -s "$F" "$D/fstab.before"; ok $? "and the fstab is untouched"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Ignore:helped</key><true/></dict></plist>\n' > "$D/hang.plist"
start=$(date +%s); out=$(LINUXFS_TEST_DISKS="$D/hang:$D/ext4.img" LINUXFS_SCAN_SECONDS=1 LINUXFS_FSTAB=$D/hang-fstab LINUXFS_PREFS_USER=$D/hang.plist \
  LINUXFS_PREFS_MACHINE=$D/none.plist "$D/helper" --migrate-prefs 2> "$D/hang.err"); rc=$?; took=$(($(date +%s) - start))
[ $rc -eq 0 ] && [ -z "$out" ] && grep -q "did not answer" "$D/hang.err" && [ $took -le 3 ]; ok $? "the migration's scan too: the label is left, saying a disk did not answer (got $rc in ${took}s: $(tr '\n' '|' < "$D/hang.err"))"
# spec: tools/helper.c helper_migrate -- the install's migration (the postinstall runs it as root): each Ignore:<LABEL> = true,
#       in the console user's and the machine's plists, becomes a LABEL= entry when a disk of that name is attached (its bundle
#       from the probe), printed as DOMAIN<TAB>LABEL for the postinstall to delete; what cannot be converted is left and logged
plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$2" > "$1"; }
plist "$D/user.plist" "<key>Automount</key><false/><key>Ignore:helped</key><true/><key>Ignore:nowhere</key><true/><key>Ignore:kept</key><false/>"
plist "$D/machine.plist" "<key>Ignore:a#b</key><true/><key>ReadOnly</key><true/><key>Ignore:$(printf '%01200d' 0)</key><true/>"
M=$D/mfstab; : > "$M"
out=$(LINUXFS_FSTAB=$M LINUXFS_PREFS_USER=$D/user.plist LINUXFS_PREFS_MACHINE=$D/machine.plist "$D/helper" --migrate-prefs 2> "$D/migrate.err"); rc=$?
[ $rc -eq 0 ] && [ "$out" = "user${T}helped" ]; ok $? "--migrate-prefs converts Ignore:helped (attached as $e) and prints it (got $rc: '$out')"
[ "$(cat "$M")" = "LABEL=helped none linuxfs_ext4 rw,noauto # linuxfs" ]; ok $? "as a LABEL= entry with the probed disk's bundle ($(cat "$M"))"
grep -q "nowhere" "$D/migrate.err" && grep -q "a#b" "$D/migrate.err" && grep -q "too long" "$D/migrate.err" && ! grep -q kept "$D/migrate.err"; ok $? "a label with no disk attached, not writable, or too long is logged and left ($(tr '\n' '|' < "$D/migrate.err"))"
out=$(LINUXFS_FSTAB=$M LINUXFS_PREFS_USER=$D/none.plist LINUXFS_PREFS_MACHINE=$D/none.plist "$D/helper" --migrate-prefs 2>&1); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ]; ok $? "with no preferences there is nothing to migrate (got $rc: '$out')"
# spec: tools/helper.c -- noauto-remove-all (pre-uninstall runs --noauto-remove-all as root): every linuxfs line goes, no other
printf '# the Mac'"'"'s\nLABEL=Backup none hfs ro\n' > "$F"
"$D/open" --noauto-add "LABEL=my data" linuxfs_ext4 && "$D/open" --noauto-add "LABEL=helped" linuxfs_ext4 && echo "LABEL=after none hfs ro" >> "$F"
"$D/open" --noauto-remove-all; ok $? "linuxfs-open --noauto-remove-all exits 0"
[ "$(cat "$F")" = "# the Mac's
LABEL=Backup none hfs ro
LABEL=after none hfs ro" ]; ok $? "every linuxfs line is gone, the others kept in order ($(tr '\n' '|' < "$F"))"
"$D/open" --noauto-add "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF" linuxfs_ext4
"$D/helper" --noauto-remove-all; rc=$?
[ $rc -eq 0 ] && ! grep -q linuxfs "$F" && grep -q "LABEL=after none hfs ro" "$F"; ok $? "linuxfs-helper --noauto-remove-all does the same, without the socket (rc $rc)"
LINUXFS_FSTAB=$D/no-fstab "$D/helper" --noauto-remove-all; rc=$?
[ $rc -eq 0 ] && [ ! -e "$D/no-fstab" ]; ok $? "with no fstab it is ok and makes none (rc $rc)"
ln -s "$F" "$D/link-fstab"
LINUXFS_FSTAB=$D/link-fstab "$D/helper" --noauto-remove-all 2> "$D/rmall.err"; rc=$?
[ $rc -eq 1 ] && grep -q symlink "$D/rmall.err"; ok $? "a refusal is printed and exits 1 (rc $rc: $(cat "$D/rmall.err"))"
kill $hp; wait $hp 2>/dev/null
"$D/open" --probe "$D/ext4.img" > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "with no helper listening, exit 3"
echo "1..$n"; exit $bad
