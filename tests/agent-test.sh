#!/bin/sh
# platform: macOS-only -- DiskArbitration, hdiutil
#   usage: agent-test.sh
#          Builds linuxfs-agent for 10.9 and runs its policy test, then runs it against a real disk: an ext4 image
#          attached with hdiutil -nomount (nothing is mounted or installed). With stand-ins for the CLI and
#          linuxfs-open (which reads the attached disk, the user's own), the agent must run `automount diskN`
#          when the disk appears and `unmount --force diskN` when it is detached. Linux makes the image.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
D=$HOME/Library/Caches/mm-build/linuxfs-agent-test; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
cc() { "$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld "$@"; }
cc -o "$D/agent" "$ROOT/tools/agent.c" -framework DiskArbitration -framework CoreFoundation -framework Security || exit 1
cc -o "$D/policy" "$ROOT/tests/agent-policy-test.c" -framework DiskArbitration -framework CoreFoundation -framework Security || exit 1
cc -o "$D/probe" "$ROOT/tools/probe.c" || exit 1
"$D/policy" > "$D/policy.tap"; bad=$?
grep -v '^1\.\.' "$D/policy.tap"
n=$(grep -c '^ok\|^not ok' "$D/policy.tap")
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
sh "$ROOT/build/linux-host.sh" sh -c 'truncate -s 16M "$1/ext4.img" && mkfs.ext4 -q -F -L agented "$1/ext4.img"' _ "$D" || exit 1
# spec: tools/agent.c --
#       the CLI's stand-in: its unmount ends what holds the disk (as lklfuse exits when unmounted)
#       (with $D/slow, an unmount that takes 15 s, past DiskArbitration's 10 s for an answer: P3-3)
printf '#!/bin/sh\necho "$*" >> "%s/cli.calls"\n[ "$1" != unmount ] || [ ! -f "%s/slow" ] || sleep 15\n[ "$1" != unmount ] || [ ! -f "%s/holder.pid" ] || kill "$(cat "%s/holder.pid")" 2>/dev/null\nexit 0\n' "$D" "$D" "$D" "$D" > "$D/cli"
printf '#!/bin/sh\n[ "$1" = --probe ] || exit 2\nexec "%s/probe" "/dev/r${2#/dev/}"\n' "$D" > "$D/open"
chmod 755 "$D/cli" "$D/open"; : > "$D/cli.calls"
LINUXFS_CLI=$D/cli LINUXFS_OPEN=$D/open "$D/agent" 2> "$D/agent.log" & ap=$!
dev=
dev2=
trap 'kill $ap 2>/dev/null; for d in $dev $dev2; do hdiutil detach -quiet -force "$d" 2>/dev/null; done' EXIT
sleep 2
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/ext4.img" | awk 'NR == 1 { print $1 }')
bsd=${dev#/dev/}
echo "# attached $dev"
i=0; while ! grep -qx "automount $bsd" "$D/cli.calls" && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -qx "automount $bsd" "$D/cli.calls"; ok $? "the agent runs 'automount $bsd' when an ext4 disk appears"
grep -q "$bsd holds ext4	agented; claiming it" "$D/agent.log"; ok $? "it claimed the disk at peek, before it appeared"
hdiutil detach -quiet "$dev"; dev=
i=0; while ! grep -qx "unmount --force $bsd" "$D/cli.calls" && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -qx "unmount --force $bsd" "$D/cli.calls"; ok $? "and 'unmount --force $bsd' when it is detached"
[ "$(grep -c "^automount" "$D/cli.calls")" = 1 ]; ok $? "nothing else on this Mac was automounted (calls: $(tr '\n' '|' < "$D/cli.calls"))"
# spec: tools/agent.c --
#       ejected while mounted: lklfuse holds the disk open, so it never disappears on its own (P3-2); the agent must
#       unmount it as the eject is asked for, so the eject goes through
: > "$D/cli.calls"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/ext4.img" | awk 'NR == 1 { print $1 }')
bsd=${dev#/dev/}
i=0; while ! grep -qx "automount $bsd" "$D/cli.calls" && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sh -c 'exec sleep 60' < "/dev/r$bsd" & echo $! > "$D/holder.pid"
sleep 1
hdiutil detach -force "$dev" > "$D/eject.out" 2>&1; erc=$?
grep -qx "unmount --force $bsd" "$D/cli.calls"; ok $? "a disk held open and ejected: the agent unmounts it first (calls: $(tr '\n' '|' < "$D/cli.calls"))"
! kill -0 "$(cat "$D/holder.pid")" 2>/dev/null && [ $erc -eq 0 ] && ! hdiutil info | grep -q "^$dev[ 	]"
ok $? "and the eject goes through ($erc: $(tr '\n' ' ' < "$D/eject.out"))"
kill "$(cat "$D/holder.pid")" 2>/dev/null; rm -f "$D/holder.pid"; hdiutil detach -quiet -force "$dev" 2>/dev/null; dev=
# spec: tools/agent.c --
#       an unmount slower than DiskArbitration waits: the agent answers the eject in time anyway (it may fail busy), so
#       DiskArbitration never gives up on it and still tells it of the next disk (P3-3: the reattached one went unseen)
: > "$D/cli.calls"; cp "$D/ext4.img" "$D/ext4b.img"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/ext4.img" | awk 'NR == 1 { print $1 }')
bsd=${dev#/dev/}
i=0; while ! grep -qx "automount $bsd" "$D/cli.calls" && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sh -c 'exec sleep 60' < "/dev/r$bsd" & echo $! > "$D/holder.pid"
touch "$D/slow"; sleep 1
hdiutil detach -force "$dev" > "$D/eject.out" 2>&1 & ep=$!
sleep 1
dev2=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/ext4b.img" | awk 'NR == 1 { print $1 }')
bsd2=${dev2#/dev/}
i=0; while ! grep -qx "automount $bsd2" "$D/cli.calls" && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
grep -qx "automount $bsd2" "$D/cli.calls"; ok $? "a disk attached while a slow eject unmount runs is still automounted (calls: $(tr '\n' '|' < "$D/cli.calls"))"
! syslog -k Sender diskarbitrationd -k Time ge -2m 2>/dev/null | grep -q "\[$ap\]:[0-9]* not responding" || false
ok $? "DiskArbitration never finds the agent not responding"
wait $ep; rm -f "$D/slow"
kill "$(cat "$D/holder.pid")" 2>/dev/null; rm -f "$D/holder.pid"
hdiutil detach -quiet -force "$dev" 2>/dev/null; hdiutil detach -quiet -force "$dev2" 2>/dev/null; dev= dev2=
# spec: tools/agent.c --
#       an encrypted volume: automount exits 4; the agent asks (here a stand-in for its dialog), mounts with the password on
#       stdin, asks again with the hint when it is wrong, and gives up after three tries
kill $ap; wait $ap 2>/dev/null
cat > "$D/cli" <<EOF
#!/bin/sh
echo "\$*" >> "$D/cli.calls"
case "\$1 \$3" in
  "automount ") exit 4 ;;
  "mount --password-stdin") IFS= read -r pw; echo "\$pw" >> "$D/pw.got"
    [ "\$pw" = right ] && exit 0
    echo "linuxfs: wrong password for /dev/\$2 (hint: test)" >&2; exit 4 ;;
esac
EOF
printf '#!/bin/sh\necho "$*" >> "%s/ask.calls"\nn=$(wc -l < "%s/ask.calls")\nif [ -f "%s/always-wrong" ] || [ $n -eq 1 ]; then printf "once\nwrong\n"; else printf "once\nright\n"; fi\n' "$D" "$D" "$D" > "$D/ask"
chmod 755 "$D/cli" "$D/ask"; : > "$D/cli.calls"; : > "$D/ask.calls"; : > "$D/pw.got"
LINUXFS_CLI=$D/cli LINUXFS_OPEN=$D/open LINUXFS_ASKPASS=$D/ask LINUXFS_KEYCHAIN=off "$D/agent" 2> "$D/agent.log" & ap=$!
sleep 2
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/ext4.img" | awk 'NR == 1 { print $1 }')
bsd=${dev#/dev/}
i=0; while ! grep -qx "mount $bsd --password-stdin" "$D/cli.calls" || [ "$(wc -l < "$D/pw.got")" -lt 2 ]; do
  [ $i -lt 300 ] || break; sleep 0.1; i=$((i + 1)); done
[ "$(head -n 1 "$D/ask.calls")" = "$bsd" ]; ok $? "automount exiting 4 makes the agent ask for $bsd's password (asked: $(tr '\n' '|' < "$D/ask.calls"))"
[ "$(tr '\n' ' ' < "$D/pw.got")" = "wrong right " ]; ok $? "it mounts with each answer on stdin (got: $(tr '\n' ' ' < "$D/pw.got"))"
[ "$(sed -n 2p "$D/ask.calls")" = "$bsd test wrong" ]; ok $? "and asks again, with the hint, after a wrong one"
hdiutil detach -quiet "$dev"; dev=
touch "$D/always-wrong"; : > "$D/ask.calls"; : > "$D/pw.got"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/ext4.img" | awk 'NR == 1 { print $1 }')
bsd=${dev#/dev/}
i=0; while [ "$(wc -l < "$D/pw.got")" -lt 3 ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
sleep 3
[ "$(wc -l < "$D/ask.calls")" -eq 3 ] && [ "$(wc -l < "$D/pw.got")" -eq 3 ]; ok $? "three wrong passwords, and it stops asking (asked $(wc -l < "$D/ask.calls" | tr -d ' ') times)"
echo "1..$n"; exit $bad
