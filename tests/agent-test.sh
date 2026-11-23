#!/bin/sh
# platform: macOS-only -- DiskArbitration, hdiutil, the login keychain's agent
#   usage: agent-test.sh
#          Builds linuxfs-agent for 10.9 and runs its policy test, then runs the agent against a temporary HOME with the
#          keychain swapped for a store in memory (LINUXFS_KEYCHAIN=off): the keychain's socket answers find, save and
#          forget, and --offer hands over a password used once; a socket left behind with no one listening fails the
#          client within 5 s; the socket's directory is private. A raw image attached with hdiutil -nomount (nothing
#          is mounted or installed) holds no filesystem a bundle claims, so the login sweep must run nothing for it.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
D=$HOME/Library/Caches/mm-build/linuxfs-agent-test; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
cc() { "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld "$@"; }
cc -o "$D/agent" "$ROOT/tools/agent.c" -framework DiskArbitration -framework CoreFoundation -framework Security || exit 1
cc -o "$D/policy" "$ROOT/tests/agent-policy-test.c" -framework DiskArbitration -framework CoreFoundation -framework Security || exit 1
"$D/policy" > "$D/policy.tap"; bad=$?
grep -v '^1\.\.' "$D/policy.tap"
n=$(grep -c '^ok\|^not ok' "$D/policy.tap")
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
# a short HOME: the socket's path must fit sockaddr_un (104 bytes)
H=$(mktemp -d /tmp/lfagent.XXXXXX) || exit 1
SOCK=$H/Library/Caches/dev.mavergreen.linuxfs/keychain.sock
# spec: tools/agent.c --
#       the CLI's stand-in, for the sweep: it only records what it is asked
printf '#!/bin/sh\necho "$*" >> "%s/cli.calls"\nexit 0\n' "$D" > "$D/cli"; chmod 755 "$D/cli"; : > "$D/cli.calls"
dd if=/dev/zero of="$D/blank.img" bs=1m count=16 2>/dev/null
dev=
ap=
trap 'kill $ap 2>/dev/null; [ -z "$dev" ] || hdiutil detach -quiet -force "$dev" 2>/dev/null; rm -rf "$H"' EXIT
agent() { HOME=$H LINUXFS_CLI=$D/cli LINUXFS_KEYCHAIN=off LINUXFS_SWEEP_DELAY=${SWEEP:-600} "$D/agent" 2>> "$D/agent.log" & ap=$!
  i=0; while [ -z "$(printf 'find\tdisk0\n' | nc -w 1 -U "$SOCK" 2>/dev/null)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
# req VERB: one request, as a client sends it (the rest of the lines on stdin), the reply on stdout
req() { nc -w 5 -U "$SOCK"; }
find_() { printf 'find\t%s\n' "$1" | req | tr '\n' ' '; }
agent
[ "$(find_ disk9)" = "none " ]; ok $? "find for a disk with nothing kept answers none (got: $(find_ disk9))"
[ "$(printf 'save\tdisk9\nsecret\n' | req | tr '\n' ' ')" = "ok " ]; ok $? "save answers ok"
[ "$(find_ disk9)" = "saved secret " ]; ok $? "find then answers saved, with the password (got: $(find_ disk9))"
[ "$(find_ disk8)" = "none " ]; ok $? "and only for that disk"
[ "$(find_ disk9)" = "saved secret " ]; ok $? "a saved password is not used up by being found"
[ "$(printf 'forget\tdisk9\n' | req | tr '\n' ' ')" = "ok " ]; ok $? "forget answers ok"
[ "$(find_ disk9)" = "none " ]; ok $? "and find answers none again"
printf 'pw2\n' | HOME=$H "$D/agent" --offer disk9; rc=$?
[ $rc = 0 ]; ok $? "--offer disk9 exits 0 when the agent answers ($rc)"
[ "$(find_ disk9)" = "offered pw2 " ]; ok $? "find then answers offered, with the password"
[ "$(find_ disk9)" = "none " ]; ok $? "and an offer is used once: the next find answers none"
printf 'save\tdisk9\nsaved1\n' | req > /dev/null
printf 'pw3\n' | HOME=$H "$D/agent" --offer disk9
[ "$(find_ disk9)" = "offered pw3 " ] && [ "$(find_ disk9)" = "saved saved1 " ]; ok $? "an offer is preferred to a saved password, and does not replace it"
[ "$(printf 'bogus\tdisk9\n' | req | tr '\n' ' ')" = "" ]; ok $? "an unknown verb is dropped with no answer"
[ "$(printf 'find\n' | req | tr '\n' ' ')" = "" ]; ok $? "so is a request with no disk"
[ "$(printf 'save\tdisk7\n\n' | req | tr '\n' ' ')" = "" ] && [ "$(find_ disk7)" = "none " ]; ok $? "a save with no password is dropped, and keeps nothing"
[ "$(stat -f %Lp "$H/Library/Caches/dev.mavergreen.linuxfs")" = 700 ]; ok $? "the socket's directory is mode 700"
[ "$(stat -f %Lp "$SOCK")" = 600 ]; ok $? "and the socket is mode 600"
! grep -q 'secret\|pw2\|pw3\|saved1' "$D/agent.log"; ok $? "no password is in the agent's log"
kill -9 $ap; wait $ap 2>/dev/null
[ -S "$SOCK" ]; ok $? "killing the agent leaves its socket file behind"
s=$(date +%s)
printf 'pw\n' | HOME=$H "$D/agent" --offer disk9 2> /dev/null; rc=$?
e=$(( $(date +%s) - s ))
[ $rc = 1 ] && [ $e -le 5 ]; ok $? "--offer against it, with no one listening, exits 1 within 5 s (rc $rc, $e s)"
agent
[ "$(find_ disk9)" = "none " ]; ok $? "a restarted agent replaces the stale socket and answers"
kill $ap; wait $ap 2>/dev/null
# spec: tools/agent.c --
#       the login sweep: 15 s after start (here 2 s) it mounts the linuxfs_ disks nothing mounted; a disk with no
#       linuxfs_ kind (this Mac has no bundles, so an attached image has none) is left alone
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/blank.img" | awk 'NR == 1 { print $1 }')
echo "# attached $dev"
: > "$D/cli.calls"; SWEEP=2 agent; sleep 7
i=0; while ! grep -q 'login sweep looked' "$D/agent.log" && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
looked=$(sed -n 's/.*login sweep looked at \([0-9]*\) disks.*/\1/p' "$D/agent.log" | tail -n 1)
[ "${looked:-0}" -ge 1 ]; ok $? "the sweep ran, and looked at the attached disk among the others (${looked:-none} disks)"
[ ! -s "$D/cli.calls" ]; ok $? "and ran nothing for a disk with no linuxfs_ kind (calls: $(tr '\n' '|' < "$D/cli.calls"))"
echo "1..$n"; exit $bad
