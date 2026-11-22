#!/bin/sh
# platform: host-agnostic -- on the Linux host (build/linux-host.sh, LINUX_HOST_FUSE=1), building lklfuse if need be
#   usage: apfs-fixtures-linux.sh [FIXTURES-DIR]
#          Reads the APFS that macOS made (tests/lib/make-apfs-fixtures.sh's directory: enc.img.gz, ssd.img.gz,
#          hdd.img.gz, expected.txt) through lklfuse, read-only, and checks every file against expected.txt:
#          the encrypted volume Secret with its password (and refused without it, or with a wrong one, which
#          names the hint), the unencrypted volume Plain beside it, and the Fusion container's volume Fused from
#          its two devices (a 400 MiB file that spills onto the second). Skips (77) off Linux, without /dev/fuse,
#          or when FIXTURES-DIR (default: tests/fixtures/apfs) has no fixtures yet. Builds lklfuse (LKLFUSE,
#          default /work/gate0-linux/out/lklfuse) with build/build-lkl-linux.sh when it is missing.
set -u
F=${1:-$(cd "$(dirname "$0")" && pwd)/fixtures/apfs}
LKLFUSE=${LKLFUSE:-/work/gate0-linux/out/lklfuse}
[ "$(uname -s)" = Linux ] || { echo "apfs-fixtures-linux.sh: Linux host only" >&2; exit 77; }
[ -c /dev/fuse ] || { echo "apfs-fixtures-linux.sh: no /dev/fuse (LINUX_HOST_FUSE=1?)" >&2; exit 77; }
[ -f "$F/expected.txt" ] || { echo "apfs-fixtures-linux.sh: no APFS fixtures from macOS in $F" >&2; exit 77; }
# spec: a host-agnostic test that skips fails (run-repo-tests.sh), and this one sorts before gate0-linux.sh, which builds
#       lklfuse: so build it here when it is missing (CI's build step has usually left it in the /work volume already)
if [ ! -x "$LKLFUSE" ]; then
  sh "$(cd "$(dirname "$0")/.." && pwd)/build/build-lkl-linux.sh" "$(dirname "$LKLFUSE")" > "${TMPDIR:-/tmp}/apfs-fixtures-build.log" 2>&1 &&
    [ -x "$LKLFUSE" ] || { echo "apfs-fixtures-linux.sh: building lklfuse failed:" >&2; tail -20 "${TMPDIR:-/tmp}/apfs-fixtures-build.log" >&2; exit 1; }
fi
W=$(mktemp -d /tmp/apfs-fixtures.XXXXXX); MNT=$W/mnt; mkdir "$MNT"
pid=
trap 'fusermount3 -u "$MNT" 2>/dev/null; [ -z "$pid" ] || wait "$pid" 2>/dev/null; rm -rf "$W"' EXIT
for f in enc ssd hdd; do [ ! -f "$F/$f.img.gz" ] || gzip -dc "$F/$f.img.gz" > "$W/$f.img" || exit 1; done
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }

# spec: patches/lkl/0007-lklfuse-passfd.patch --
#       mount OPTS IMAGE [PASSWORD]: lklfuse in the background; 0 once mounted
mount_it() {
  if [ $# -ge 3 ]; then "$LKLFUSE" -f -o "$1,passfd=5" "$2" "$MNT" > "$W/log" 2>&1 5<<P &
$3
P
  else "$LKLFUSE" -f -o "$1" "$2" "$MNT" > "$W/log" 2>&1 &
  fi
  pid=$!
  # platform: lklfuse puts up its FUSE mount before LKL mounts the disk: mounted once LKL answers, not before
  i=0; until grep -q " $MNT " /proc/mounts && ls "$MNT" > /dev/null 2>&1 && kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1)); { [ $i -le 200 ] && kill -0 "$pid" 2>/dev/null; } || { wait "$pid"; pid=; return 1; }; sleep 0.1
  done
}
unmount_it() { fusermount3 -u "$MNT" && wait "$pid"; r=$?; pid=; return $r; }
# spec: tests/fixtures/apfs/expected.txt --
#       matches VOLUME: every file expected.txt lists for VOLUME, as macOS wrote it
matches() {
  # platform: not what macOS's own daemons rewrite as the volume is unmounted
  grep "^$1 " "$F/expected.txt" | sed "s/^$1 //" | grep -v '  \./\.fseventsd/\|  \./\.Spotlight-V100/\|  \./\.Trashes/' > "$W/want"
  [ -s "$W/want" ] && (cd "$MNT" && sha256sum -c --quiet "$W/want")
}

mount_it type=apfs,ro "$W/enc.img"; rc=$?
[ $rc -ne 0 ] && grep -q 'Required key not available' "$W/log"; ok $? "the encrypted volume is refused without its password (log: $(tail -n 2 "$W/log" | tr '\n' '|'))"
[ $rc -ne 0 ] || unmount_it
mount_it type=apfs,ro "$W/enc.img" wrong-password; rc=$?
[ $rc -ne 0 ] && grep -q 'Key was rejected' "$W/log" && grep -q 'hint: test' "$W/log"; ok $? "a wrong password is rejected, naming the hint"
[ $rc -ne 0 ] || unmount_it
mount_it type=apfs,ro "$W/enc.img" linuxfs-test; ok $? "the password unlocks the encrypted volume ($(tail -n 1 "$W/log"))"
matches Secret; ok $? "every file on it reads back as macOS wrote it"
[ "$(readlink "$MNT/link")" = hello.txt ] && [ -f "$MNT/unicode-café.txt" ]; ok $? "its symlink and its Unicode name too (link -> $(readlink "$MNT/link"); $(ls "$MNT" | grep unicode))"
! touch "$MNT/nope" 2>/dev/null || false; ok $? "and it is read-only"
unmount_it; ok $? "unmount it"
mount_it type=apfs,ro,opts=vol=1 "$W/enc.img"; ok $? "the unencrypted volume beside it mounts with no password"
matches Plain; ok $? "and reads back"
unmount_it; ok $? "unmount it"
# spec: a Fusion pair only from a macOS that still makes them (10.13-10.14; macOS 27 refuses): QUEUE.md
if [ -f "$W/ssd.img" ] && [ -f "$W/hdd.img" ]; then
  mount_it "type=apfs,ro,tier2file=$W/hdd.img" "$W/ssd.img"; ok $? "the Fusion container mounts from its two devices"
  matches Fused; ok $? "every file reads back, the one that spills onto the second device too"
  unmount_it; ok $? "unmount it"
else
  echo "# no Fusion fixture (ssd.img.gz, hdd.img.gz) in $F"
fi
echo "1..$n"; exit $bad
