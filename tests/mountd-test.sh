#!/bin/sh
# platform: macOS-only -- tools/mountd.c links the helper's media rule (tools/helper.c), which needs IOKit and CoreFoundation,
#   and the daemon reads its peer with LOCAL_PEERCRED and checks in with launchd as Darwin has them
#   usage: mountd-test.sh
#          Builds the root mount daemon's judging functions (tools/mountd.c, LINUXFS_MOUNTD_NO_MAIN) for 10.9 with their
#          test and runs it: the request line, the peer, whose disk it is and the rest of the verdict, the mount point's
#          facts before and after adoption, the status, the reply line and the bounds. Then the daemon's front door, in its
#          test build (LINUXFS_MOUNTD_TEST: its own socket, a console uid given, small limits, stderr for syslog, a stub
#          child that replies "user not yet"), through a perl client: the greeting, the peer check before any slot, the
#          slots and the queue, the request's one 5 s bound, idle exit and the peer log. Then the work (16i), on ext4,
#          btrfs and encrypted APFS images attached -nomount (Linux makes the first two), with stand-ins for
#          DiskArbitration, /Volumes, the mount table and the mount program (tests/lib/mountd-program-stub.c): the
#          replies, the program's argv, environment, descriptors and group, the refusals before begin, adoption and giving
#          back, the mount point's lock, the deadline and the group kill; and the real DiskArbitration once. Last, the
#          shipped build carries none of the test build's hooks. Nothing is mounted, installed or run as root.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
D=$HOME/Library/Caches/mm-build/linuxfs-mountd-test; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
cc() { "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld "$@"; }
cc -DLINUXFS_MOUNTD_NO_MAIN -DLINUXFS_HELPER_NO_MAIN -DLINUXFS_PROBE_NO_MAIN -o "$D/policy" "$ROOT/tests/mountd-policy-test.c" \
  "$ROOT/tools/mountd.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/helper.c" "$ROOT/tools/probe.c" "$ROOT/tools/plist.c" \
  "$ROOT/tools/fstab.c" -framework IOKit -framework CoreFoundation || exit 1
# spec: build/build-lkl-darwin.sh -- the shipped daemon, built as the release builds it
daemon() { cc -DLINUXFS_HELPER_NO_MAIN -DLINUXFS_PROBE_NO_MAIN "$@" "$ROOT/tools/mountd.c" "$ROOT/tools/trust.c" \
  "$ROOT/tools/helper.c" "$ROOT/tools/probe.c" "$ROOT/tools/fstab.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/plist.c" \
  -framework DiskArbitration -framework IOKit -framework CoreFoundation; }
daemon -o "$D/mountd" || echo "# the shipped daemon did not build"
daemon -DLINUXFS_MOUNTD_TEST -o "$D/mountd-t" || echo "# the test build did not build"
"$D/policy" > "$D/policy.tap"; bad=$?
grep -v '^1\.\.' "$D/policy.tap"
n=$(grep -c '^ok\|^not ok' "$D/policy.tap")
ok() { n=$((n + 1)); if test "$1" = 0; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
T=$(printf '\t')
ME=$(id -u); OTHER=$((ME + 4242))
S=$D/sock
REQ="mount${T}ext4${T}disk9s1${T}-${T}/Volumes/x"

# The client: connects to SOCK and, by MODE:
#   send REQ   writes REQ and a newline, then prints each line it reads, then "eof EPOCH";
#   big        writes 2000 bytes and a newline, then the same;
#   drip REQ   reads one line (prints it), then writes REQ a byte every 2 s; prints "closed SECONDS" when the daemon closes;
#   flood N    N connections that send nothing, each read to EOF; prints each connection's lines joined by "|".
# Every run is bounded by a 20 s alarm. A refused connect (a full backlog) is tried again for up to 5 s.
cat > "$D/client.pl" <<'EOF'
use strict; use IO::Socket::UNIX; use IO::Select; use Time::HiRes qw(time sleep);
$SIG{PIPE} = 'IGNORE'; $SIG{ALRM} = sub { print "timeout\n"; exit 2 }; alarm 20;
$| = 1;
my ($path, $mode, $arg) = @ARGV;
# a full backlog (a flood) refuses a connect: it is tried again for up to 5 s, as a patient client would
sub conn {
	my $t0 = time;
	while (1) {
		my $c = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path);
		return $c if $c;
		if (!$!{ECONNREFUSED} || time - $t0 > 5) { print "noconnect $!\n"; exit 3 }
		sleep 0.01;
	}
}
sub drain { my ($c) = @_; my @l; while (my $l = <$c>) { chomp $l; push @l, $l } return @l }
if ($mode eq 'flood') {
	for (1 .. $arg) { my $c = conn(); print join('|', drain($c)), "\n"; close $c }
	exit 0;
}
my $c = conn();
if ($mode eq 'send' || $mode eq 'big') {
	print $c ($mode eq 'big' ? 'x' x 2000 : $arg), "\n";
	print "$_\n" for drain($c);
	printf "eof %.2f\n", time;
} elsif ($mode eq 'drip') {
	my $t0 = time; my $hi = <$c>; print $hi;
	my $s = IO::Select->new($c);
	for my $b (split //, $arg) {
		syswrite $c, $b;
		if ($s->can_read(2)) { my $buf; if (!sysread($c, $buf, 512)) { printf "closed %.1f\n", time - $t0; exit 0 } print $buf }
	}
	print "never closed\n";
}
EOF
cl() { perl "$D/client.pl" "$S" "$@"; }
# start [ENV=VAL ...] -- ARGS: the test build on $S, its stderr in $D/err, its pid in $dp; waits (5 s) for the socket
start() {
  rm -f "$S"; e=""
  while test $# -gt 0 && test "$1" != "--"; do e="$e $1"; shift; done; shift
  env $e "$D/mountd-t" --socket "$S" --status "$@" 2> "$D/err" & dp=$!
  i=0; while ! test -S "$S" && test $i -lt 50; do sleep 0.1; i=$((i + 1)); done
}
stop() { kill "$dp" 2>/dev/null; i=0; while kill -0 "$dp" 2>/dev/null && test $i -lt 50; do sleep 0.1; i=$((i + 1)); done; wait "$dp" 2>/dev/null; }
trap 'kill $dp 2>/dev/null' EXIT
# after A B: B - A in tenths of a second (A and B epoch seconds with decimals)
after() { perl -e 'printf "%d\n", ($ARGV[1] - $ARGV[0]) * 10' "$1" "$2"; }
eofat() { sed -n 's/^eof //p' "$1"; }

# spec: plan 16h, front_greeting -- the console user reads hi before anything else
start -- --console "$ME"
cl send "$REQ" > "$D/greet.out"
test "$(sed -n 1p "$D/greet.out")" = "hi"; ok $? "front_greeting: the console user reads hi first"
test "$(sed -n 2p "$D/greet.out")" = "user${T}not yet"; ok $? "front_greeting: then the stub child's reply"
# spec: plan 16h, front_peer_log -- a served peer is logged with its groups
grep -q "^mountd: peer uid $ME groups [0-9]" "$D/err"; ok $? "front_peer_log: a served peer's uid and groups are logged"
cl big > "$D/big.out"
test "$(sed -n 1p "$D/big.out")" = "hi" && sed -n 2p "$D/big.out" | grep -q "^no${T}1${T}."
ok $? "front_big_request: 2000 bytes get no 1 and a reason"
stop

# spec: plan 16h, front_other_uid -- not the console user: user, and no greeting
start -- --console "$OTHER"
cl send "$REQ" > "$D/other.out"
test "$(sed -n 1p "$D/other.out")" = "user${T}not the user at the console" && ! grep -q '^hi$' "$D/other.out"
ok $? "front_other_uid: another uid gets user, not the user at the console, with no hi"
stop

# spec: plan 16h, front_flood_other_uid (I3) and front_peer_log -- 50 refused peers take no slot, are logged once
start -- --console "$OTHER"
cl flood 50 > "$D/flood.out"
test "$(grep -c "^user${T}not the user at the console\$" "$D/flood.out")" = 50
ok $? "front_flood_other_uid: each of 50 connections gets user and nothing else"
grep '^mountd: status slots ' "$D/err" > "$D/flood.status"
test -s "$D/flood.status" && ! grep -v '^mountd: status slots 0 queued 0$' "$D/flood.status" > /dev/null
ok $? "front_flood_other_uid: the slot count never rose above 0 ($(wc -l < "$D/flood.status" | tr -d ' ') status lines)"
test "$(grep -c "^mountd: refused uid $ME" "$D/err")" = 1
ok $? "front_peer_log: one log line for 50 refusals within 10 s"
stop
start -- --console "$ME"
cl send "$REQ" > "$D/after.out"
test "$(cat "$D/after.out" | sed -n 1,2p | tr '\n' '|')" = "hi|user${T}not yet|"
ok $? "front_flood_other_uid: then the console user is still served"
stop

# spec: plan 16h, front_slots -- one slot per uid, one queued; the queued one is served after the first
start LINUXFS_MOUNTD_TEST_CHILD_SLEEP=1 -- --console "$ME" --max-uid 1 --queue 1 --queue-wait 2
cl send "$REQ" > "$D/s1.out" & c1=$!
sleep 0.3
cl send "$REQ" > "$D/s2.out" & c2=$!
wait $c1; wait $c2
test "$(sed -n 1,2p "$D/s2.out" | tr '\n' '|')" = "hi|user${T}not yet|" && test "$(after "$(eofat "$D/s1.out")" "$(eofat "$D/s2.out")")" -ge 5
ok $? "front_slots: the second request is queued, and served after the first"
grep -q '^mountd: status slots 1 queued 1$' "$D/err"; ok $? "front_slots: it was queued"
stop
start LINUXFS_MOUNTD_TEST_CHILD_SLEEP=4 -- --console "$ME" --max-uid 1 --queue 1 --queue-wait 2
cl send "$REQ" > "$D/b1.out" & c1=$!
sleep 0.3
t2=$(perl -MTime::HiRes=time -e 'printf "%.2f\n", time'); cl send "$REQ" > "$D/b2.out" & c2=$!
sleep 0.3
t3=$(perl -MTime::HiRes=time -e 'printf "%.2f\n", time'); cl send "$REQ" > "$D/b3.out"
test "$(sed -n 1,2p "$D/b3.out" | tr '\n' '|')" = "hi|user${T}busy|" && test "$(after "$t3" "$(eofat "$D/b3.out")")" -le 10
ok $? "front_slots: a third, beyond the queue, gets user busy at once"
wait $c2
w=$(after "$t2" "$(eofat "$D/b2.out")")
test "$(sed -n 1,2p "$D/b2.out" | tr '\n' '|')" = "hi|user${T}busy|" && test "$w" -ge 15 && test "$w" -le 35
ok $? "front_slots: a queued one waiting past 2 s gets user busy (after ${w} tenths)"
wait $c1
test "$(sed -n 2p "$D/b1.out")" = "user${T}not yet"; ok $? "front_slots: the first is still served"
stop

# spec: plan 16h, front_slow_request (M4) -- one 5 s bound on the whole request, not per read
start -- --console "$ME"
cl drip "$REQ" > "$D/slow.out"
s=$(sed -n 's/^closed //p' "$D/slow.out")
test "$(sed -n 1p "$D/slow.out")" = "hi" && test -n "$s" && test "$(perl -e 'print $ARGV[0] <= 7 ? 1 : 0' "$s")" = 1
ok $? "front_slow_request: a byte every 2 s is closed within 7 s (${s:-never} s)"
! grep -q '^mountd: request ' "$D/err"; ok $? "front_slow_request: with no child work"
stop

# spec: plan 16h, front_idle -- exits 0 after the idle time, but never with a request in flight
t0=$(date +%s)
start -- --console "$ME" --idle 2
i=0; while kill -0 "$dp" 2>/dev/null && test $i -lt 60; do sleep 0.1; i=$((i + 1)); done
wait "$dp"; rc=$?; took=$(($(date +%s) - t0))
test $rc = 0 && test $took -le 4; ok $? "front_idle: --idle 2 exits 0 within 4 s (rc $rc after ${took} s)"
start LINUXFS_MOUNTD_TEST_CHILD_SLEEP=3 -- --console "$ME" --idle 2
cl send "$REQ" > "$D/idle.out"
test "$(sed -n 2p "$D/idle.out")" = "user${T}not yet"; ok $? "front_idle: a 3 s request in flight is answered"
i=0; while kill -0 "$dp" 2>/dev/null && test $i -lt 60; do sleep 0.1; i=$((i + 1)); done
wait "$dp"; rc=$?
test $rc = 0; ok $? "front_idle: and then it exits 0"

# spec: task-16h-findings-r0.md I1 -- connect-and-close flooders of another uid (the test build's --foreign-pgid takes their
#       process group for another uid) never starve the parent's housekeeping: the console user's 5 requests, one after
#       another, are each served (finished children are reaped), and once the flood stops the idle exit still comes
cat > "$D/flood.pl" <<'PL'
use strict; use IO::Socket::UNIX; use Time::HiRes qw(time sleep);
my ($path, $pgfile, $stop, $n) = @ARGV;
setpgrp(0, 0); $SIG{PIPE} = 'IGNORE';
open my $f, '>', "$pgfile.new" or die; print $f getpgrp(0), "\n"; close $f; rename "$pgfile.new", $pgfile;
my $t0 = time;
sleep 0.05 until -S $path || time - $t0 > 5;
for (1 .. $n) {
	next if fork;
	until (-e $stop || time - $t0 > 40) { my $c = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path); close $c if $c }
	exit 0;
}
1 while wait > 0;
PL
# flood N: N flooders in a process group of their own, $fp; flood_end stops them (bounded)
flood() { rm -f "$S" "$D/stop" "$D/pgid"; perl "$D/flood.pl" "$S" "$D/pgid" "$D/stop" "$1" & fp=$!
  i=0; while ! test -s "$D/pgid" && test $i -lt 50; do sleep 0.1; i=$((i + 1)); done; }
flood_end() { touch "$D/stop"; i=0; while kill -0 "$fp" 2>/dev/null && test $i -lt 100; do sleep 0.1; i=$((i + 1)); done; wait "$fp"; }
flood 24
start LINUXFS_MOUNTD_TEST_CHILD_SLEEP=1 -- --console "$ME" --idle 2 --foreign-pgid "$(cat "$D/pgid")"
sleep 1
: > "$D/flooded.out"
for k in 1 2 3 4 5 6; do cl send "$REQ" | sed -n 2p >> "$D/flooded.out"; done
test "$(grep -c "^user${T}not yet\$" "$D/flooded.out")" = 6
ok $? "front_flood_reap (I1): under a flood of another uid, the console user's 6 requests are each served ($(tr '\n' '|' < "$D/flooded.out"))"
test "$(grep -c '^mountd: refused uid ' "$D/err")" -ge 1; ok $? "front_flood_reap: (control) the flood was refused"
most=$(sed -n 's/^mountd: status took //p' "$D/err" | sort -n | tail -1)
test "${most:-0}" = 16; ok $? "front_flood_reap: a pass of the loop takes at most 16 connections, and the flood filled one (most: ${most:-none})"
flood_end
i=0; while kill -0 "$dp" 2>/dev/null && test $i -lt 60; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$dp" 2>/dev/null; then rc=alive; else wait "$dp"; rc=$?; fi
test "$rc" = 0; ok $? "front_flood_reap: once the flood stops, it exits 0 when idle (rc $rc)"
stop
flood 24
start -- --console "$ME" --foreign-pgid "$(cat "$D/pgid")"
sleep 1
kill -TERM "$dp"; i=0; while kill -0 "$dp" 2>/dev/null && test $i -lt 60; do sleep 0.1; i=$((i + 1)); done
test $i -le 10; ok $? "front_flood_reap: under the flood, SIGTERM ends it within 1 s (${i} tenths)"
stop; flood_end

# spec: task-16h-findings-r0.md m2 -- a queued request is served only if its uid is still the console user's
#       (--console-file: the test build reads the console's uid from a file at each look)
echo "$ME" > "$D/console"
start LINUXFS_MOUNTD_TEST_CHILD_SLEEP=2 -- --console-file "$D/console" --max-uid 1
cl send "$REQ" > "$D/q1.out" & c1=$!
sleep 0.3
cl send "$REQ" > "$D/q2.out" & c2=$!
sleep 0.5
echo "$OTHER" > "$D/console"
wait $c1; wait $c2
test "$(sed -n 1,2p "$D/q2.out" | tr '\n' '|')" = "hi|user${T}not the user at the console|"
ok $? "front_queue_console (m2): a queued request whose uid left the console gets user, not the user at the console"
test "$(grep -c '^mountd: request from uid ' "$D/err")" = 1; ok $? "front_queue_console: and no child of its own"
test "$(sed -n 2p "$D/q1.out")" = "user${T}not yet"; ok $? "front_queue_console: (control) the running one is answered"
stop

# spec: task-16h-findings-r0.md m3 -- an unreadable credential: closed with no reply, logged once per 10 s with its own
#       errno (LINUXFS_MOUNTD_TEST_CRED_FAIL: the test build takes the read as failed, EINVAL)
start LINUXFS_MOUNTD_TEST_CRED_FAIL=1 -- --console "$ME"
cl flood 5 > "$D/nocred.out"
test "$(grep -c '^$' "$D/nocred.out")" = 5; ok $? "front_no_cred (m3): each of 5 gets no reply"
test "$(grep -c "^mountd: a peer's credential cannot be read: Invalid argument\$" "$D/err")" = 1
ok $? "front_no_cred: one log line in 10 s, with the failure's own errno"
stop

# ---- 16i: the work (describe, judge, adopt, spawn, reply), on real -nomount images, with stand-ins for DiskArbitration
#      (LINUXFS_MOUNTD_TEST_DA), the mount program (tests/lib/mountd-program-stub.c, in $P), /Volumes ($V) and the mount table
sh "$ROOT/build/linux-host.sh" sh -c 'truncate -s 128M "$1/ext4.img" && mkfs.ext4 -q -F -L "my data" "$1/ext4.img" &&
  truncate -s 128M "$1/btrfs.img" && mkfs.btrfs -q -f -L backup "$1/btrfs.img" > /dev/null' _ "$D" || exit 1
gunzip -c "$ROOT/tests/fixtures/apfs/enc.img.gz" > "$D/enc.img" || exit 1
att() { hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/$1" | awk 'NR == 1 { print $1 }'; }
devs=""
trap 'kill $dp 2>/dev/null; for d in $devs; do hdiutil detach -quiet -force "$d" 2>/dev/null; done' EXIT
E=$(att ext4.img); devs="$E"; B=$(att btrfs.img); devs="$devs $B"; A=$(att enc.img); devs="$devs $A"
E=${E#/dev/} B=${B#/dev/} A=${A#/dev/}
P=$D/prog V=$D/vol; mkdir -p "$P" "$V"
cc -o "$P/mount_macfuse_ext4" "$ROOT/tests/lib/mountd-program-stub.c" || exit 1
cp "$P/mount_macfuse_ext4" "$P/mount_macfuse_btrfs"; cp "$P/mount_macfuse_ext4" "$P/mount_macfuse_apfs"
chmod 755 "$P" "$P"/mount_macfuse_*
W="LINUXFS_MOUNTD_TEST_PROGRAM=$P LINUXFS_MOUNTD_TEST_VOLUMES=$V LINUXFS_MOUNTD_TEST_MNTTAB=$P/mnttab"
W="$W LINUXFS_PREFS_USER=$D/none.plist LINUXFS_PREFS_MACHINE=$D/none.plist"
WDA="$W LINUXFS_MOUNTD_TEST_DA=$D/da"
# da KEY=VAL...: DiskArbitration's stand-in, an ejectable leaf of no partition type given to macfuse_ext4, unless told
da() { { echo "kind=macfuse_ext4"; echo "content="; echo "leaf=1"; echo "has_path=0"; echo "ejectable=1"; echo "image=0"
  for kv; do echo "$kv"; done; } > "$D/da"; }
# prog WORD...: the stand-in's mode; its log and the mount table start empty
prog() { printf '%s\n' "$@" > "$P/mode"; rm -f "$P/log"; : > "$P/mnttab"; }
# mnt NAME: an empty mount point of the test user's, 0755
mnt() { rm -rf "$V/$1" "$V/$1.swapped"; mkdir "$V/$1"; chmod 755 "$V/$1"; }
rq() { printf 'mount\t%s\t%s\t%s\t/Volumes/%s' "$1" "$2" "$3" "$4"; }
replies() { sed '/^eof /d' "$1" | tr '\n' '|'; }
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
ran() { test -f "$P/log"; }
gone() { test -n "$1" || return 1; i=0; while kill -0 "$1" 2>/dev/null && test $i -lt 30; do sleep 0.1; i=$((i + 1)); done; ! kill -0 "$1" 2>/dev/null; }
logged() { sed -n "s/^$1 //p" "$P/log" 2>/dev/null | head -1; }

start $WDA -- --console "$ME"
# spec: plan 16i, serve_ok -- hi, begin, ok; the program's argv, its environment (PATH alone) and descriptors (0-2 only)
da "bsd=$E"; mnt NAME; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/sok.out"
test "$(replies "$D/sok.out")" = "hi|begin|ok|"; ok $? "serve_ok: hi, begin, then ok ($(replies "$D/sok.out"))"
test "$(sed -n 's/^argv //p' "$P/log" 2>/dev/null | tr '\n' '|')" = "-o|nodev,nosuid,noowners|/dev/$E|$V/NAME|"
ok $? "serve_ok: argv is -o nodev,nosuid,noowners /dev/$E $V/NAME"
test "$(grep '^env ' "$P/log" 2>/dev/null)" = "env PATH=/usr/bin:/bin:/usr/sbin:/sbin"; ok $? "serve_ok: the environment is PATH alone"
test "$(grep '^fds' "$P/log" 2>/dev/null)" = "fds 0 1 2"; ok $? "serve_ok: descriptors 0-2 only"
test "$(logged pid)" = "$(logged pgid)" && test -n "$(logged pid)"; ok $? "serve_ok: the program leads a process group of its own"
grep -q "^mountd: $E on /Volumes/NAME: ok (peer $ME, DA [0-9]*ms)\$" "$D/err"; ok $? "serve_ok: one result line, with the peer and DiskArbitration's latency"
# spec: plan 16i, serve_adopt -- a mount point of the peer's is adopted (the test build says so instead of fchown)
grep -qx "adopt $V/NAME" "$D/err"; ok $? "serve_adopt: the peer's mount point is adopted, then ok"
# spec: plan 16i, serve_ro_owners
mnt NAME; prog mount
cl send "$(rq ext4 "$E" ro,owners NAME)" > "$D/sro.out"
test "$(sed -n 's/^argv //p' "$P/log" 2>/dev/null | sed -n 2p)" = "nodev,nosuid,owners,rdonly" && test "$(replies "$D/sro.out")" = "hi|begin|ok|"
ok $? "serve_ro_owners: -o nodev,nosuid,owners,rdonly"
# spec: plan 16i, serve_phantom, serve_owner_501, serve_rc -- ok only with the program's 0 and root's mount of /dev/BSD on MNT
mnt NAME; prog
cl send "$(rq ext4 "$E" - NAME)" > "$D/sph.out"
replies "$D/sph.out" | grep -q "^hi|begin|no${T}1${T}[^|]*|\$"; ok $? "serve_phantom: exit 0 with nothing mounted: no 1 ($(replies "$D/sph.out"))"
mnt NAME; prog mount "owner 501"
cl send "$(rq ext4 "$E" - NAME)" > "$D/s501.out"
replies "$D/s501.out" | grep -q "^hi|begin|no${T}1${T}"; ok $? "serve_owner_501: a mount owned by 501: no 1"
mnt NAME; prog mount "exit 3"
cl send "$(rq ext4 "$E" - NAME)" > "$D/src.out"
replies "$D/src.out" | grep -q "^hi|begin|no${T}3${T}"; ok $? "serve_rc: exit 3: no 3 ($(replies "$D/src.out"))"
mnt NAME; prog mount "from /dev/disk99"
cl send "$(rq ext4 "$E" - NAME)" > "$D/src2.out"
replies "$D/src2.out" | grep -q "^hi|begin|no${T}1${T}"; ok $? "serve_rc: exit 0, mounted from another device: no 1"
# spec: plan 16i, serve_encrypted -- the user's own mount, before begin, the program never run
da "bsd=$A" kind=macfuse_apfs; mnt NAME; prog mount
cl send "$(rq apfs "$A" - NAME)" > "$D/senc.out"
replies "$D/senc.out" | grep -q "^hi|user${T}encrypted|\$" && ! ran; ok $? "serve_encrypted: user encrypted, before begin, not run ($(replies "$D/senc.out"))"
# spec: plan 16i, serve_kind
da "bsd=$E" kind=macfuse_btrfs; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/skind.out"
replies "$D/skind.out" | grep -q "^hi|no${T}1${T}[^|]*|\$" && ! ran; ok $? "serve_kind: given to macfuse_btrfs, asked as ext4: no 1, before begin"
# spec: plan 16i, serve_foreign_node (I6, N1)
da "bsd=$E" "node_uid=$OTHER"; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/sfn.out"
test "$(replies "$D/sfn.out")" = "hi|user${T}not your disk: your own mount|" && ! ran; ok $? "serve_foreign_node: another user's node: user, before begin, not run"
da "bsd=$E" image=1 node_uid=0; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/sfn2.out"
test "$(replies "$D/sfn2.out")" = "hi|user${T}not your disk: your own mount|" && ! ran; ok $? "serve_foreign_node: an image whose node is root's: user"
da "bsd=$E" image=1 "node_uid=$ME"; mnt NAME; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/sfn3.out"
test "$(replies "$D/sfn3.out")" = "hi|begin|ok|"; ok $? "serve_foreign_node: an image of the peer's: ok"
# spec: plan 16i, serve_mounted
da "bsd=$E"; mnt NAME; prog mount; printf 'hfs\t/dev/%s\t/Volumes/else\t0\n' "$E" > "$P/mnttab"
cl send "$(rq ext4 "$E" - NAME)" > "$D/smtd.out"
replies "$D/smtd.out" | grep -q "^hi|no${T}1${T}[^|]*|\$" && ! ran; ok $? "serve_mounted: something mounted from /dev/$E: no 1, before begin"
# spec: plan 16i, serve_mnt_refusals
mnt NAME; touch "$V/NAME/file"; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/sne.out"
replies "$D/sne.out" | grep -q "^hi|no${T}1${T}[^|]*|\$" && ! ran; ok $? "serve_mnt_refusals: not empty: no 1, before begin"
rm -rf "$V/NAME"; mkdir -p "$D/elsewhere"; ln -s "$D/elsewhere" "$V/NAME"
cl send "$(rq ext4 "$E" - NAME)" > "$D/ssym.out"
replies "$D/ssym.out" | grep -q "^hi|no${T}1${T}[^|]*|\$" && ! ran; ok $? "serve_mnt_refusals: a symlink: no 1, before begin"
rm -f "$V/NAME"
cl send "$(rq ext4 "$E" - NAME)" > "$D/smiss.out"
replies "$D/smiss.out" | grep -q "^hi|no${T}1${T}[^|]*|\$" && ! ran; ok $? "serve_mnt_refusals: missing: no 1, before begin"
# spec: plan 16i, serve_mnt_locked (M10) -- two disks never stack on one mount point
mnt NAME; prog "sleep 3"
cl send "$(rq ext4 "$E" - NAME)" > "$D/slk1.out" & c1=$!
sleep 1
da "bsd=$B" kind=macfuse_btrfs
cl send "$(rq btrfs "$B" - NAME)" > "$D/slk2.out"
replies "$D/slk2.out" | grep -q "^hi|no${T}1${T}[^|]*under way[^|]*|\$"; ok $? "serve_mnt_locked: a second disk on the same mount point while the first is in flight: no 1 ($(replies "$D/slk2.out"))"
wait $c1
mnt NAME; prog mount
cl send "$(rq btrfs "$B" - NAME)" > "$D/slk3.out"
test "$(replies "$D/slk3.out")" = "hi|begin|ok|"; ok $? "serve_mnt_locked: (control) once the first has ended, the second disk is served"
# spec: plan 16i, serve_chatty (M5) -- 1 MiB of output is drained
da "bsd=$E"; mnt NAME; prog chatty mount
t0=$(now); cl send "$(rq ext4 "$E" - NAME)" > "$D/schat.out"; w=$(after "$t0" "$(eofat "$D/schat.out")")
test "$(replies "$D/schat.out")" = "hi|begin|ok|" && test "$w" -le 30; ok $? "serve_chatty: 1 MiB of output, ok within 3 s (${w} tenths)"
# spec: plan 16i, step 7 -- a mount program root cannot trust is not run, and an adopted mount point is given back
mnt NAME; prog mount; chmod 777 "$P/mount_macfuse_ext4"
cl send "$(rq ext4 "$E" - NAME)" > "$D/strust.out"
chmod 755 "$P/mount_macfuse_ext4"
test "$(replies "$D/strust.out")" = "hi|begin|no${T}1${T}the mount program is not root's alone|" && ! ran && grep -qx "giveback $V/NAME $ME 755" "$D/err"
ok $? "serve_untrusted: a program others may write is not run: no 1, the mount point given back ($(replies "$D/strust.out"))"
# spec: plan 16i, serve_da_real (M6) -- the real DiskArbitration, in a child forked from a parent that has used syslog
stop
start $W -- --console "$ME"
mnt NAME; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/sreal.out"
replies "$D/sreal.out" | grep -q "^hi|no${T}1${T}DiskArbitration has not given the disk to this filesystem's bundle|\$" && ! ran
ok $? "serve_da_real: the real DiskArbitration: nothing installed, so no bundle has the disk ($(replies "$D/sreal.out"))"
grep -q "^mountd: $E on /Volumes/NAME: no 1 (peer $ME, DA [0-9]*ms): DiskArbitration has not given" "$D/err"; ok $? "serve_da_real: its latency is logged"
stop
"$D/mountd-t" --describe "$E" > "$D/describe.out" 2>&1
miss=""
# a raw image has no partition map, so its DAMediaContent is there but empty
for k in DAMediaBSDName DAMediaLeaf DAMediaContent= DAMediaEjectable DAMediaRemovable DADeviceModel DADeviceProtocol; do
  case $k in *=) grep -q "^$k" "$D/describe.out" || miss="$miss $k" ;; *) grep -q "^$k=." "$D/describe.out" || miss="$miss $k" ;; esac
done
test -z "$miss" && grep -qx "DAMediaBSDName=$E" "$D/describe.out"; ok $? "serve_da_real: --describe prints each key, with a value${miss:+ (missing:$miss)}"
grep -q '^DAMediaBSDName=' "$D/describe.out" && ! grep -q '^DAVolumePath=' "$D/describe.out" && ! grep -q '^DAVolumeKind=macfuse_' "$D/describe.out"
ok $? "serve_da_real: no DAVolumePath, and DAVolumeKind not ours"
test "$(stat -f %u "/dev/$E")" = "$ME"; ok $? "serve_da_real (N1): hdiutil gives the attaching user the node"
# spec: plan 16i, serve_adopt_swapped (M1, N9) -- the mount point swapped between fchown and the re-check is given back
start $WDA LINUXFS_MOUNTD_TEST_ADOPT_SWAP=1 -- --console "$ME"
da "bsd=$E"; mnt NAME; chmod 700 "$V/NAME"; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/sswap.out"
test "$(replies "$D/sswap.out")" = "hi|begin|no${T}1${T}the mount point changed|" && ! ran
ok $? "serve_adopt_swapped: no 1 the mount point changed, the program not run ($(replies "$D/sswap.out"))"
grep -qx "giveback $V/NAME $ME 700" "$D/err" && test "$(stat -f '%u %Lp' "$V/NAME.swapped")" = "$ME 700"
ok $? "serve_adopt_swapped: the moved directory is given back, 0700 ($(grep giveback "$D/err"))"
stop
# spec: plan 16i, serve_rdev (M8) -- /dev/BSD changed under the mount program: no
start $WDA LINUXFS_MOUNTD_TEST_RDEV_SHIFT=1 -- --console "$ME"
da "bsd=$E"; mnt NAME; prog mount
cl send "$(rq ext4 "$E" - NAME)" > "$D/srdev.out"
replies "$D/srdev.out" | grep -q "^hi|begin|no${T}1${T}"; ok $? "serve_rdev: another device under the same name: no 1 ($(replies "$D/srdev.out"))"
stop
# spec: plan 16i, serve_da_slow (N2) -- DiskArbitration that never answers: user, too slow, before begin
start $WDA LINUXFS_MOUNTD_TEST_DA_SLEEP=20 -- --console "$ME"
da "bsd=$E"; mnt NAME; prog mount
t0=$(now); cl send "$(rq ext4 "$E" - NAME)" > "$D/sslow.out"; w=$(after "$t0" "$(eofat "$D/sslow.out")")
test "$(replies "$D/sslow.out")" = "hi|user${T}the daemon was too slow: your own mount|" && test "$w" -le 170 && ! ran
ok $? "serve_da_slow: user, too slow, within 17 s (${w} tenths), before begin"
stop
# spec: plan 16i, serve_deadline (I4, N5) -- SIGTERM at the deadline, then SIGKILL to the program's group and the CLI's
start $WDA "LINUXFS_MOUNTD_TEST_RUNAS=$ME" -- --console "$ME" --deadline 2 --grace 2
da "bsd=$E"; mnt NAME; prog ignoreterm child cli "sleep 30"
t0=$(now); cl send "$(rq ext4 "$E" - NAME)" > "$D/sdl.out"; w=$(after "$t0" "$(eofat "$D/sdl.out")")
test "$(replies "$D/sdl.out")" = "hi|begin|no${T}1${T}deadline|" && test "$w" -le 60; ok $? "serve_deadline: no 1 deadline within 6 s (${w} tenths)"
pp=$(logged pid); pc=$(logged child); pl=$(logged cli)
gone "$pp" && gone "$pc" && gone "$pl"; ok $? "serve_deadline: the program, its child and the CLI in its own group are gone"
grep -qx sigterm "$P/log" 2>/dev/null; ok $? "serve_deadline: the program saw SIGTERM before SIGKILL"
stop
start $WDA "LINUXFS_MOUNTD_TEST_RUNAS=$OTHER" -- --console "$ME" --deadline 2 --grace 2
prog ignoreterm child cli "sleep 30"; mnt NAME
cl send "$(rq ext4 "$E" - NAME)" > "$D/sdl2.out"
pp=$(logged pid); pl=$(logged cli)
test "$(replies "$D/sdl2.out")" = "hi|begin|no${T}1${T}deadline|" && gone "$pp" && kill -0 "$pl" 2>/dev/null
ok $? "serve_deadline: a CLI group running as another uid is left alone"
kill -9 "$pl" 2>/dev/null
stop
# spec: plan 16i, serve_deadline_term -- a program that ends on SIGTERM: gone within the grace, no SIGKILL
start $WDA "LINUXFS_MOUNTD_TEST_RUNAS=$ME" -- --console "$ME" --deadline 2 --grace 2
prog termexit "sleep 30"; mnt NAME
t0=$(now); cl send "$(rq ext4 "$E" - NAME)" > "$D/sdt.out"; w=$(after "$t0" "$(eofat "$D/sdt.out")")
test "$(replies "$D/sdt.out")" = "hi|begin|no${T}1${T}deadline|" && test "$w" -lt 40 && grep -qx sigterm "$P/log" && ! grep -q SIGKILL "$D/err"
ok $? "serve_deadline_term: it ends on SIGTERM, within the grace (${w} tenths), with no SIGKILL"
# spec: plan 16i, serve_deadline_pgid_reused (R1) -- the CLI's group ends, a fresh group is named after it: left alone
prog ignoreterm cliend "sleep 30"; mnt NAME
cl send "$(rq ext4 "$E" - NAME)" > "$D/sdr.out"
pf=$(logged fresh)
test "$(replies "$D/sdr.out")" = "hi|begin|no${T}1${T}deadline|" && test -n "$pf" && kill -0 "$pf" 2>/dev/null
ok $? "serve_deadline_pgid_reused: a group started after the CLI's ended is left alone, and the reply is still deadline"
test -n "$pf" && kill -9 "$pf" 2>/dev/null
stop

# spec: plan 16h, mountd_shipped (M14) -- the shipped daemon checks in with launchd, runs no shell, carries no test hook
u=$("$CL/bin/llvm-nm" -u "$D/mountd" 2>&1)
printf '%s\n' "$u" | grep -qx '_launch_msg' && ! printf '%s\n' "$u" | grep -qx '_system\|_popen\|_execvp'
ok $? "mountd_shipped: nm -u has _launch_msg, and no _system, _popen or _execvp"
# m1: every test-only option and hook; the control proves each name is found in the test build, so none is vacuous
hooks="LINUXFS_MOUNTD_TEST_ LINUXFS_MOUNTD_TEST_CHILD_SLEEP LINUXFS_MOUNTD_TEST_CRED_FAIL --socket --console --console-file"
hooks="$hooks --idle --max-uid --max --queue --queue-wait --status --foreign-pgid --deadline --grace --describe"
hooks="$hooks LINUXFS_MOUNTD_TEST_DA LINUXFS_MOUNTD_TEST_DA_SLEEP LINUXFS_MOUNTD_TEST_PROGRAM LINUXFS_MOUNTD_TEST_VOLUMES"
hooks="$hooks LINUXFS_MOUNTD_TEST_MNTTAB LINUXFS_MOUNTD_TEST_ADOPT_SWAP LINUXFS_MOUNTD_TEST_RUNAS LINUXFS_MOUNTD_TEST_RDEV_SHIFT"
"$CL/bin/llvm-strings" "$D/mountd" > "$D/strings"; "$CL/bin/llvm-strings" "$D/mountd-t" > "$D/strings-t"
found=""; missing=""
for h in $hooks; do
  if grep -q -e "$h" "$D/strings"; then found="$found $h"; fi
  if ! grep -q -e "$h" "$D/strings-t"; then missing="$missing $h"; fi
done
test -z "$found"; ok $? "mountd_shipped: none of the test build's options or hooks${found:+ (found:$found)}"
test -z "$missing"; ok $? "mountd_shipped: (control) the test build has each of them${missing:+ (missing:$missing)}"
echo "1..$n"
exit $bad
