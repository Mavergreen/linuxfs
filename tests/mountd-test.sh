#!/bin/sh
# platform: macOS-only -- tools/mountd.c links the helper's media rule (tools/helper.c), which needs IOKit and CoreFoundation,
#   and the daemon reads its peer with LOCAL_PEERCRED and checks in with launchd as Darwin has them
#   usage: mountd-test.sh
#          Builds the root mount daemon's judging functions (tools/mountd.c, LINUXFS_MOUNTD_NO_MAIN) for 10.9 with their
#          test and runs it: the request line, the peer, whose disk it is and the rest of the verdict, the mount point's
#          facts before and after adoption, the status, the reply line and the bounds. Then the daemon's front door, in its
#          test build (LINUXFS_MOUNTD_TEST: its own socket, a console uid given, small limits, stderr for syslog, a stub
#          child that replies "user not yet"), through a perl client: the greeting, the peer check before any slot, the
#          slots and the queue, the request's one 5 s bound, idle exit and the peer log. Last, the shipped build carries
#          none of the test build's hooks. Nothing is attached, opened or run as root.
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

# spec: plan 16h, mountd_shipped (M14) -- the shipped daemon checks in with launchd, runs no shell, carries no test hook
u=$("$CL/bin/llvm-nm" -u "$D/mountd" 2>&1)
printf '%s\n' "$u" | grep -qx '_launch_msg' && ! printf '%s\n' "$u" | grep -qx '_system\|_popen\|_execvp'
ok $? "mountd_shipped: nm -u has _launch_msg, and no _system, _popen or _execvp"
# m1: every test-only option and hook; the control proves each name is found in the test build, so none is vacuous
hooks="LINUXFS_MOUNTD_TEST_ LINUXFS_MOUNTD_TEST_CHILD_SLEEP LINUXFS_MOUNTD_TEST_CRED_FAIL --socket --console --console-file"
hooks="$hooks --idle --max-uid --max --queue --queue-wait --status --foreign-pgid"
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
