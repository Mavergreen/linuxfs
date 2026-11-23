#!/bin/sh
# platform: macOS-only -- linuxfs-helper uses getpeereid, getmntinfo and SCM_RIGHTS as Darwin has them
#   usage: helper-test.sh
#          Builds linuxfs-helper and linuxfs-open for 10.9 and runs the policy test, then, with the helper on a
#          test socket (--test-files: regular files stand in for disks), checks what linuxfs-open gets: the
#          probe, a read-write or read-only descriptor on fd 3, a refusal for an unknown filesystem, and exit 3
#          with no helper. Linux makes the ext4 image.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
D=$HOME/Library/Caches/mm-build/linuxfs-helper-test; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
cc() { "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld "$@"; }
cc -DLINUXFS_PROBE_NO_MAIN -o "$D/helper" "$ROOT/tools/helper.c" "$ROOT/tools/probe.c" -framework IOKit -framework CoreFoundation || exit 1
cc -DLINUXFS_PROBE_NO_MAIN -o "$D/open" "$ROOT/tools/open.c" "$ROOT/tools/probe.c" || exit 1
cc -o "$D/probe" "$ROOT/tools/probe.c" || exit 1
cc -DLINUXFS_PROBE_NO_MAIN -o "$D/policy" "$ROOT/tests/helper-policy-test.c" "$ROOT/tools/probe.c" -framework IOKit -framework CoreFoundation || exit 1
"$D/policy" > "$D/policy.tap"; bad=$?
grep -v '^1\.\.' "$D/policy.tap"
n=$(grep -c '^ok\|^not ok' "$D/policy.tap")
sh "$ROOT/build/linux-host.sh" sh -c 'truncate -s 32M "$1/ext4.img" && mkfs.ext4 -q -F -L helped "$1/ext4.img" &&
  truncate -s 64M "$1/ssd.img" && truncate -s 256M "$1/hdd.img" && mkapfs -L Fused -F "$1/hdd.img" "$1/ssd.img" > /dev/null' _ "$D" || exit 1
head -c 1048576 /dev/zero > "$D/zero.img"
S=$D/sock; export LINUXFS_HELPER_SOCKET=$S
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
kill $hp; wait $hp 2>/dev/null
"$D/open" --probe "$D/ext4.img" > /dev/null 2>&1; [ $? -eq 3 ]; ok $? "with no helper listening, exit 3"
echo "1..$n"; exit $bad
