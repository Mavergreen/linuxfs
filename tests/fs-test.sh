#!/bin/sh
# platform: macOS-only -- hdiutil, CoreFoundation
#   usage: fs-test.sh
#          Builds tools/fs.c (linuxfs-fs) for 10.9 and copies it under the names the bundles use. Ext4, btrfs and NTFS
#          images made by build/linux-host.sh are attached with hdiutil -nomount (nothing is mounted or installed; the
#          user owns the device nodes, so the util runs unprivileged, with the prefs plists named by LINUXFS_PREFS_USER
#          and LINUXFS_PREFS_MACHINE). Tests the util's probe (-p) and UUID (-k) and fsck's quick check (-q).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
D=$HOME/Library/Caches/mm-build/linuxfs-fs-test; rm -rf "$D"; mkdir -p "$D"
CL=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/clang22" 2>/dev/null) || exit 1
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" 2>/dev/null) || exit 1
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld -DLINUXFS_PROBE_NO_MAIN \
  -o "$D/linuxfs-fs" "$ROOT/tools/fs.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/plist.c" "$ROOT/tools/probe.c" \
  -framework CoreFoundation -framework DiskArbitration || exit 1
for n in linuxfs_ext4.util linuxfs_ntfs.util linuxfs_btrfs.util fsck_linuxfs_ext4 mount_linuxfs_ext4 bogus.util; do cp "$D/linuxfs-fs" "$D/$n"; done
sh "$ROOT/build/linux-host.sh" sh -c "cd '$D' && sh '$ROOT/tests/lib/probe-images.sh' '$D' && blkid -s UUID -o value ext4.img > ext4.uuid && blkid -s UUID -o value btrfs.img > btrfs.uuid" || exit 1
n=0 bad=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
att() { hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/$1" | awk 'NR == 1 { print $1 }'; }
devs=
trap 'for d in $devs; do hdiutil detach -quiet -force "$d" 2>/dev/null; done' EXIT
e=$(att ext4.img); b=$(att btrfs.img); t=$(att ntfs.img); devs="$e $b $t"
echo "# attached $e $b $t"
E=${e#/dev/}; B=${b#/dev/}; T=${t#/dev/}
plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$2" > "$1"; }
plist "$D/empty.plist" ""
plist "$D/take.plist" "<key>NTFSTakeover</key><true/>"
plist "$D/takestr.plist" "<key>NTFSTakeover</key><string>YES</string>"
plist "$D/takeoff.plist" "<key>NTFSTakeover</key><true/><key>Automount</key><false/>"   # a stale Automount, from before it was dropped
printf 'this is not a plist' > "$D/corrupt.plist"
u() { # BIN ARGS... : the util with the test prefs (USERP, MACHP)
  x=$1; shift; LINUXFS_PREFS_USER=${USERP:-$D/none.plist} LINUXFS_PREFS_MACHINE=${MACHP:-$D/none2.plist} "$D/$x" "$@"; }
out=$(u linuxfs_ext4.util -p "$E" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = "my data" ]; ok $? "ext4 util -p on the ext4 disk prints the label and exits 255 (rc $rc, '$out')"
out=$(u linuxfs_ext4.util -p "$E" fixed readonly); rc=$?
[ $rc = 255 ] && [ "$out" = "my data" ]; ok $? "ext4 is claimed fixed and readonly too (rc $rc)"
out=$(u linuxfs_btrfs.util -p "$E" removable writable); rc=$?
[ $rc = 254 ] && [ -z "$out" ]; ok $? "btrfs util on the ext4 disk exits 254 and prints nothing (rc $rc)"
out=$(u linuxfs_btrfs.util -p "$B" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = backup ]; ok $? "btrfs util on the btrfs disk exits 255 (rc $rc, '$out')"
# spec: tools/fs.c -- -k as 10.9's hfs.util does it, which DiskArbitration reads (its fstab UUID= lookup needs it): the UUID,
#       uppercase, with no newline, and exit 253 (FSUR_IO_SUCCESS, not -p's 255: DiskArbitration drops the UUID otherwise)
out=$(u linuxfs_ext4.util -k "$E"); rc=$?
want=$(tr a-f A-F < "$D/ext4.uuid")
[ $rc = 253 ] && [ "$out" = "$want" ]; ok $? "-k prints the UUID blkid gave, exit 253 (rc $rc, '$out', want '$want')"
[ "$(u linuxfs_ext4.util -k "$E" | wc -c | tr -d ' ')" = 36 ]; ok $? "-k prints the 36 characters alone, no newline"
out=$(u linuxfs_btrfs.util -k "$B"); rc=$?
[ $rc = 253 ] && [ "$out" = "$(tr a-f A-F < "$D/btrfs.uuid")" ]; ok $? "-k on btrfs prints its UUID too"
out=$(u linuxfs_btrfs.util -k "$E"); rc=$?
[ $rc = 254 ] && [ -z "$out" ]; ok $? "-k for another filesystem's disk exits 254"
out=$(u linuxfs_ntfs.util -k "$T"); rc=$?
[ $rc = 254 ]; ok $? "-k on NTFS (no UUID) exits 254 (rc $rc)"
u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFS util with no prefs exits 254 (rc $rc)"
USERP=$D/empty.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFS util with a plist lacking NTFSTakeover exits 254 (rc $rc)"
out=$(USERP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = Windows ]; ok $? "NTFSTakeover=true: NTFS removable exits 255, prints the label (rc $rc, '$out')"
USERP=$D/takestr.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "NTFSTakeover as the string YES counts (rc $rc)"
USERP=$D/take.plist u linuxfs_ntfs.util -p "$T" fixed writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFSTakeover=true but fixed: exits 254 (rc $rc)"
USERP=$D/takeoff.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "a stale Automount=false is not read: NTFSTakeover=true still claims (rc $rc)"
USERP=$D/corrupt.plist MACHP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "a corrupt user plist counts as absent: the machine's NTFSTakeover=true holds (rc $rc)"
USERP=$D/empty.plist MACHP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "prefs fall back key by key: a user plist lacking the key leaves the machine's NTFSTakeover=true (rc $rc)"
USERP=$D/missing.plist MACHP=$D/missing2.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "missing plists use the defaults: ext4 still claimed (rc $rc)"
ln -sf "$D/take.plist" "$D/link.plist"
USERP=$D/link.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "a symlinked user plist is refused, as absent (rc $rc)"
# spec: tools/fs.c util -- a stale Ignore:<LABEL> is not read: DiskArbitration applies /etc/fstab's noauto, per volume
plist "$D/ign.plist" "<key>Ignore:my data</key><true/>"
out=$(USERP=$D/ign.plist MACHP=$D/ign.plist u linuxfs_ext4.util -p "$E" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = "my data" ]; ok $? "the probe does not consult Ignore:<LABEL>: still claimed (rc $rc, '$out')"
for bad_args in "-p diskX removable writable" "-p ../disk2 removable writable" "-p ${E}s removable writable" "-p $E sometimes writable" "-p $E" "-z" ""; do
  # shellcheck disable=SC2086
  u linuxfs_ext4.util $bad_args >/dev/null 2>&1; rc=$?
  [ $rc = 254 ]; ok $? "bad arguments '$bad_args' exit 254 (rc $rc)"
done
u linuxfs_ext4.util -p disk99999 removable writable >/dev/null 2>&1; rc=$?
[ $rc = 254 ]; ok $? "a disk that does not exist exits 254 (rc $rc)"
u bogus.util -p "$E" removable writable >/dev/null 2>&1; rc=$?
[ $rc = 254 ]; ok $? "an unknown program name exits 254 (rc $rc)"
u fsck_linuxfs_ext4 -q "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 0 ]; ok $? "fsck -q exits 0 (rc $rc)"
out=$(u fsck_linuxfs_ext4 -n "/dev/r$E" 2>&1); rc=$?
[ $rc = 8 ] && [ "$out" = "Verify and Repair for ext4 come with its tools" ]; ok $? "fsck -n exits 8 and says why (rc $rc, '$out')"
u fsck_linuxfs_ext4 -y "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck -y exits 8 (rc $rc)"
u fsck_linuxfs_ext4 >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck with no flag exits 8 (rc $rc)"
out=$(u fsck_linuxfs_ext4 -z "/dev/r$E" 2>&1 >/dev/null); rc=$?
[ $rc = 8 ] && case $out in usage:*) true ;; *) false ;; esac; ok $? "fsck with an unknown flag exits 8 with a usage line on stderr (rc $rc, '$out')"
u fsck_linuxfs_ext4 -qn "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck flags are parsed exactly: -qn is not -q (rc $rc)"
# spec: tools/fs.c mount role -- as the console user, with stand-ins for the CLI, the keychain keeper and the dialog
M=$D/mount; mkdir -p "$M"; MD=$D/mount_linuxfs_ext4
PWHOME=$(/usr/bin/python -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
cat > "$M/cli" <<'EOS'
#!/bin/sh
echo "args: $*" >> "$STUB_LOG"; echo "HOME=$HOME DA=${LINUXFS_DA:-} PATH=$PATH" >> "$STUB_LOG"
[ -n "${STUB_PW:-}" ] || exit 0
given=
case " $* " in *" --password-stdin "*) IFS= read -r given; echo "stdin: $given" >> "$STUB_LOG" ;; esac
[ "$given" = "$STUB_PW" ] && exit 0
if [ -n "$given" ]; then echo "linuxfs: wrong password for /dev/disk9 (hint: blue)" >&2
else echo "linuxfs: /dev/disk9 is an encrypted volume (hint: blue)" >&2; fi
exit 4
EOS
cat > "$M/dialog" <<'EOS'
#!/bin/sh
echo "dialog: $1 | $2" >> "$STUB_LOG"
[ -z "${DLG_CANCEL:-}" ] || exit 1
n=$(cat "$STUB_LOG.n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$STUB_LOG.n"
set -- $DLG_PWS
eval "pw=\${$n:-}"
[ "$pw" != EMPTY ] || pw=
printf '%s\n%s\n' "${DLG_MODE:-remember}" "$pw"
EOS
chmod +x "$M/cli" "$M/dialog"
SOCK=$M/k.sock
kc() { # MODE...: starts the stand-in keeper (logging to $M/kc.log); stop with kcstop
  rm -f "$SOCK" "$SOCK.ready" "$M/kc.log"
  /usr/bin/python "$ROOT/tests/lib/kcstub.py" "$SOCK" "$M/kc.log" "$@" & KCPID=$!
  i=0; while [ ! -e "$SOCK.ready" ] && [ "$(echo "$*" | cut -c1-5)" != stale ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
kcstop() { kill "$KCPID" 2>/dev/null; wait "$KCPID" 2>/dev/null; }
mt() { # ARGS...: the mount role with a bare environment, HOME unset, the stand-ins in place
  rm -f "$M/log" "$M/log.n"
  env -u HOME STUB_LOG="$M/log" LINUXFS_CLI="$M/cli" LINUXFS_DIALOG="$M/dialog" LINUXFS_KEYCHAIN_SOCK="$SOCK" "$@"; }
rm -f "$SOCK"
mt "$MD" -o nodev -o noowners /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -qx 'args: da-mount /dev/disk9 /tmp/m' "$M/log"; ok $? "mount runs 'da-mount DEV MNT' for -o nodev -o noowners (rc $rc: $(head -1 "$M/log" 2>/dev/null))"
grep -q "^HOME=$PWHOME DA=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin\$" "$M/log"; ok $? "the CLI gets HOME from passwd ($PWHOME), LINUXFS_DA=1 and the bare PATH ($(sed -n 2p "$M/log" 2>/dev/null))"
mt "$MD" -o nodev -o owners /dev/disk9 /tmp/m >/dev/null 2>&1
grep -qx 'args: da-mount --asked /dev/disk9 /tmp/m' "$M/log"; ok $? "-o owners adds --asked ($(head -1 "$M/log" 2>/dev/null))"
mt "$MD" -o rdonly /dev/disk9 /tmp/m >/dev/null 2>&1
grep -qx 'args: da-mount --ro /dev/disk9 /tmp/m' "$M/log"; ok $? "-o rdonly adds --ro"
mt "$MD" -o owners,rdonly /dev/disk9 /tmp/m >/dev/null 2>&1
grep -qx 'args: da-mount --asked --ro /dev/disk9 /tmp/m' "$M/log"; ok $? "both together: --asked --ro"
# spec: tools/fs.c -- a CLI exit other than 4 is the mount's exit
cat > "$M/cli7" <<'EOS'
#!/bin/sh
exit 7
EOS
chmod +x "$M/cli7"
env -u HOME LINUXFS_CLI="$M/cli7" "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
[ $rc = 7 ]; ok $? "the CLI's exit status is the mount's (rc $rc)"
# spec: tools/fs.c -- encrypted: the keeper has nothing, the dialog gives pw and says remember
kc none
mt env STUB_PW=pw DLG_PWS=pw "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ]; ok $? "an encrypted volume with a right dialog password mounts (rc $rc)"
grep -qF 'dialog: ' "$M/log" && grep 'dialog: ' "$M/log" | grep -q 'Hint: blue'; ok $? "the dialog's message carries Hint: blue ($(grep 'dialog: ' "$M/log"))"
grep 'dialog: ' "$M/log" | grep -qF "$(printf 'Enter the password for \342\200\234m\342\200\235')"; ok $? "the header names the volume by MNT's basename"
grep -qx 'stdin: pw' "$M/log"; ok $? "the rerun gets pw on stdin"
[ "$(grep -c '^args:' "$M/log")" = 2 ]; ok $? "the CLI ran twice"
! grep '^args:' "$M/log" | grep -q 'pw'; ok $? "no args line holds the password"
grep -qx 'find disk9' "$M/kc.log" && grep -qx 'save disk9 pw' "$M/kc.log"; ok $? "the keeper got find, then save disk9 pw ($(tr '\n' ';' < "$M/kc.log"))"
# spec: tools/fs.c -- remembered once only: no save
kc none
mt env STUB_PW=pw DLG_PWS=pw DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && ! grep -q '^save' "$M/kc.log"; ok $? "a password given 'once' is not saved"
# spec: tools/fs.c -- the keeper offers the right password: silent
kc saved pw
mt env STUB_PW=pw "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && ! grep -q '^dialog' "$M/log" && grep -qx 'stdin: pw' "$M/log"; ok $? "a saved right password mounts with no dialog (rc $rc)"
# spec: tools/fs.c -- the keeper's saved password is wrong: forget, then the dialog
kc saved old
mt env STUB_PW=pw DLG_PWS=pw "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && grep -qx 'forget disk9' "$M/kc.log" && grep -q '^dialog' "$M/log" && grep -qx 'stdin: old' "$M/log"; ok $? "a wrong saved password is forgotten, then the dialog runs (rc $rc; $(tr '\n' ';' < "$M/kc.log"))"
# spec: tools/fs.c -- an offered wrong password is not forgotten
kc offered old
mt env STUB_PW=pw DLG_PWS=pw DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && ! grep -q '^forget' "$M/kc.log"; ok $? "a wrong offered password is not forgotten"
# spec: tools/fs.c -- a wrong dialog password, then a right one: the second message starts Wrong password.
kc none
mt env STUB_PW=pw DLG_PWS="bad pw" DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && grep 'dialog: ' "$M/log" | sed -n 2p | grep -q '| Wrong password\. Hint: blue'; ok $? "after a wrong try the message starts 'Wrong password.' ($(grep 'dialog: ' "$M/log" | sed -n 2p))"
# spec: tools/fs.c -- three wrong tries: three dialogs, exit 4
kc none
mt env STUB_PW=pw DLG_PWS="a b c d" DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 4 ] && [ "$(grep -c '^dialog' "$M/log")" = 3 ]; ok $? "three wrong passwords: three dialogs, exit 4 (rc $rc)"
# spec: tools/fs.c -- Cancel
kc none
mt env STUB_PW=pw DLG_CANCEL=1 "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 4 ] && [ "$(grep -c '^args:' "$M/log")" = 1 ]; ok $? "Cancel exits 4 and the CLI ran once (rc $rc)"
# spec: tools/fs.c -- no keeper at all, and a stale socket: the dialog still runs, quickly
rm -f "$SOCK"
mt env STUB_PW=pw DLG_PWS=pw "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -q '^dialog' "$M/log"; ok $? "no keeper: the dialog runs (rc $rc)"
kc stale; t0=$(date +%s)
mt env STUB_PW=pw DLG_PWS=pw "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
t1=$(date +%s)
[ $rc = 0 ] && grep -q '^dialog' "$M/log" && [ $((t1 - t0)) -lt 6 ]; ok $? "a stale socket: the dialog runs, in $((t1 - t0)) s (rc $rc)"
kc hang; t0=$(date +%s)
mt env STUB_PW=pw DLG_PWS=pw DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
t1=$(date +%s); kcstop
[ $rc = 0 ] && grep -q '^dialog' "$M/log" && [ $((t1 - t0)) -lt 8 ]; ok $? "a keeper that never answers: the dialog runs after the 5 s deadline, in $((t1 - t0)) s (rc $rc)"
kc hang; t0=$(date +%s)
mt env STUB_PW=pw DLG_PWS=pw DLG_MODE=remember "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
t1=$(date +%s); kcstop
[ $rc = 0 ] && [ $((t1 - t0)) -lt 8 ]; ok $? "a hung keeper and 'remember' ticked: the save is skipped, not a second 5 s wait: $((t1 - t0)) s (rc $rc)"
# spec: tools/fs.c -- a CLI that leaves a background child behind: the mount returns at once, and the child holds only fds 0-2
cat > "$M/clibg" <<'EOS'
#!/bin/sh
/usr/bin/python -c 'import os
o = []
for f in range(3, 256):
    try:
        os.fstat(f); o.append(str(f))
    except OSError:
        pass
open(os.environ["STUB_LOG"], "a").write("fds: " + " ".join(o) + "\n")'
sleep 5 >/dev/null 2>&1 </dev/null &
exit 0
EOS
chmod +x "$M/clibg"
t0=$(date +%s)
rm -f "$M/log"; env -u HOME STUB_LOG="$M/log" LINUXFS_CLI="$M/clibg" "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
t1=$(date +%s)
[ $rc = 0 ] && [ $((t1 - t0)) -lt 3 ]; ok $? "a CLI that leaves a background child: the mount returns in $((t1 - t0)) s, not when the child ends (rc $rc)"
fds=$(sed -n 's/^fds: //p' "$M/log" | tr -d '\n'); case " $fds " in *" 255 "*) fds=$(echo " $fds " | sed 's/ 255 / /') ;; esac
[ -z "$(echo $fds)" ]; ok $? "the CLI holds no fd above 2 but the shell's own script fd ('$fds')"
# spec: tools/fs.c -- Mount with an empty field asks again, counted among the 3
kc none
mt env STUB_PW=pw DLG_PWS="EMPTY pw" DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && [ "$(grep -c '^dialog' "$M/log")" = 2 ]; ok $? "an empty password asks again instead of cancelling (rc $rc, $(grep -c '^dialog' "$M/log") dialogs)"
kc none
mt env STUB_PW=pw DLG_PWS="EMPTY EMPTY EMPTY" DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 4 ] && [ "$(grep -c '^dialog' "$M/log")" = 3 ] && [ "$(grep -c '^args:' "$M/log")" = 1 ]; ok $? "three empty answers: three dialogs, exit 4, the CLI ran once (rc $rc)"
# spec: tools/fs.c -- a hint that is not UTF-8 does not cancel the dialog
cat > "$M/clibad" <<'EOS'
#!/bin/sh
echo "args: $*" >> "$STUB_LOG"
case " $* " in *" --password-stdin "*) exit 0 ;; esac
printf 'linuxfs: encrypted (hint: caf\351)\n' >&2; exit 4
EOS
chmod +x "$M/clibad"
kc none
mt env LINUXFS_CLI="$M/clibad" DLG_PWS=pw DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && grep -q '^dialog' "$M/log"; ok $? "a hint that is not UTF-8 is left out, and the dialog still runs (rc $rc)"
# spec: tools/fs.c run_cli -- the mount program against the REAL cli/linuxfs (da-mount), with stand-ins only for lklfuse, the
#       opener and the prober (the CLI's own LINUXFS_LKLFUSE, LINUXFS_OPEN and LINUXFS_PROBE; its --access is the real
#       linuxfs-probe's): every argv form the mount program builds is accepted (not usage, exit 2), and the password reaches
#       lklfuse on its fd 5
R=$M/real; rm -rf "$R"; mkdir -p "$R/mnt"
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld \
  -o "$D/linuxfs-probe" "$ROOT/tools/probe.c" "$ROOT/tools/fsrules.c" || exit 1
cat > "$R/open" <<'EOS'
#!/bin/sh
case $1 in --access) exec "$REAL_PROBE" "$@" ;; --probe) printf '%s\tlbl\n' "${FAKE_PROBE:-ext4}"; exit 0 ;; esac
[ "$1" != --ro ] || shift
shift
exec "$@"
EOS
cat > "$R/lklfuse" <<'EOS'
#!/bin/sh
echo "lklfuse: $*" >> "$LK_LOG"
case "$*" in
  *passfd=5*) IFS= read -r got <&5; echo "pw: $got" >> "$LK_LOG" ;;
  *) if [ -n "${FAKE_ENCRYPTED:-}" ]; then echo "APFS: volume is encrypted (hint: blue)"; echo "can't mount disk: Required key not available"; exit 1; fi ;;
esac
exit 0
EOS
chmod +x "$R/open" "$R/lklfuse"
real() { # ARGS...: the mount role (user path) running the real CLI, whose lklfuse exits at once as a successful mount
  rm -f "$R/lk.log"
  mt env LINUXFS_CLI="$ROOT/cli/linuxfs" LINUXFS_OPEN="$R/open" LINUXFS_LKLFUSE="$R/lklfuse" LINUXFS_PROBE="$R/open" \
    LINUXFS_STATE="$R/state" LINUXFS_LOGS="$R/logs" LINUXFS_LOCKS="$R/locks" LINUXFS_DOMAIN=test.fsreal \
    LINUXFS_MACHINE_DOMAIN="$R/no-machine" LK_LOG="$R/lk.log" REAL_PROBE="$D/linuxfs-probe" "$@"; }
real "$MD" /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -q "^lklfuse: .*$R/mnt" "$R/lk.log"; ok $? "the real CLI accepts the plain da-mount argv (rc $rc)"
plist "$R/stale.plist" "<key>Automount</key><false/><key>Ignore:lbl</key><true/>"
real env LINUXFS_DOMAIN="$R/stale" "$MD" /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -q "^lklfuse: .*$R/mnt" "$R/lk.log"; ok $? "a stale Automount=false and Ignore:<LABEL> are not read: the real CLI mounts (rc $rc)"
real "$MD" -o owners /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -q "^lklfuse: " "$R/lk.log"; ok $? "the real CLI accepts da-mount --asked (rc $rc)"
real "$MD" -o rdonly /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -q "^lklfuse: .*,ro " "$R/lk.log"; ok $? "the real CLI accepts da-mount --ro and mounts read-only (rc $rc)"
kc saved pw
real env FAKE_PROBE=apfs FAKE_ENCRYPTED=pw "$MD" -o owners /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && grep -q "^pw: pw\$" "$R/lk.log" && grep -q "passfd=5" "$R/lk.log"; ok $? "the real CLI accepts da-mount --password-stdin and lklfuse gets the password on fd 5 (rc $rc: $(tr '\n' '|' < "$R/lk.log" 2>/dev/null))"
# spec: tools/fs.c -- misuse
for bad_args in "" "/dev/disk9" "-o /dev/disk9 /tmp/m" "/dev/disk9 /tmp/m extra" "-x /dev/disk9 /tmp/m"; do
  # shellcheck disable=SC2086
  mt "$MD" $bad_args >/dev/null 2>&1; rc=$?
  [ $rc = 1 ] && [ ! -e "$M/log" ]; ok $? "misuse '$bad_args' exits 1 without running the CLI (rc $rc)"
done
# platform: the mount role as root cannot run as root here, so a -DLINUXFS_FS_TEST_DROP build (the same code up to
#           the drop; it prints the plan instead of dropping and exec'ing) stands in. The shipped build has no such code.
mkdir -p "$D/drop"
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld -DLINUXFS_PROBE_NO_MAIN \
  -DLINUXFS_FS_TEST_DROP -o "$D/drop/mount_linuxfs_ext4" "$ROOT/tools/fs.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/plist.c" "$ROOT/tools/probe.c" \
  -framework CoreFoundation -framework DiskArbitration || exit 1
DM=$D/drop/mount_linuxfs_ext4
V=$D/vols; rm -rf "$V"; mkdir -p "$V/NAME" "$V/other"; : > "$V/file"; ln -s "$V/NAME" "$V/link"
H=/Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d
UID_D=$(id -u daemon)
plan() { # ARGS...: the drop build's plan for user daemon, volumes under $V
  env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_PREFS_USER="$D/none.plist" \
    LINUXFS_PREFS_MACHINE="${MACHP:-$D/none2.plist}" "$DM" "$@"; }
want() { # RW [ARGV-FLAGS] DEV MNT: the plan the brief prescribes
  rw=$1; dv=$2; mn=$3; shift 3
  printf 'user daemon\nuid %s\ngid %s\nfd3 /dev/r%s %s\nmnt %s\n' "$UID_D" "$(id -g daemon)" "$dv" "$rw" "$mn"
  printf 'env HOME=/private/var/db/linuxfs\nenv PATH=/usr/bin:/bin:/usr/sbin:/sbin\nenv LINUXFS_DA=1\nenv LINUXFS_ALL_USERS=1\nenv LINUXFS_OPEN_INHERITED=1\n'
  printf 'env LINUXFS_LKLFUSE=%s/lklfuse\nenv LINUXFS_PROBE=%s/linuxfs-probe\nenv LINUXFS_OPEN=%s/linuxfs-open\n' "$H" "$H" "$H"
  printf 'argv %s/linuxfs\nargv da-mount\n' "$H"
  for a in "$@"; do printf 'argv %s\n' "$a"; done
  printf 'argv /dev/%s\nargv %s\n' "$dv" "$mn"
}
plan -o nodev -o noowners -o nosuid "/dev/$E" "$V/NAME" > "$M/plan" 2>"$M/plan.err"; rc=$?
want rw "$E" "$V/NAME" > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root plan: _linuxfs ids, the device on fd 3, the exact env and argv (rc $rc: $(diff "$M/plan" "$M/want" | head -3 | tr '\n' ';'))"
plan -o owners,rdonly "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
want ro "$E" "$V/NAME" --asked --ro > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root plan: owners and rdonly become --asked --ro, and the device is opened read-only (rc $rc)"
# spec: tools/fs.c mount_as_root -- the CLI's output goes to syslog and its status comes back; only fd 3 reaches it
cat > "$M/rootcli" <<'EOS'
#!/bin/sh
echo "to stdout"; echo "to stderr" >&2
/usr/bin/python -c 'import os
o = []
for f in range(3, 256):
    try:
        os.fstat(f); o.append(str(f))
    except OSError:
        pass
print("fds: " + " ".join(o))'
exit 5
EOS
chmod +x "$M/rootcli"
env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_ROOT_CLI="$M/rootcli" "$DM" "/dev/$E" "$V/NAME" 7</dev/null > "$M/plan" 2>&1; rc=$?
fdl=$(sed -n 's/^fds: //p' "$M/plan" | sed 's/ *255//'); [ -n "$fdl" ] || fdl=none
[ $rc = 5 ] && grep -q '^cli-rc 5' "$M/plan" && grep -q 'to stdout' "$M/plan" && grep -q 'to stderr' "$M/plan" && [ "$fdl" = 3 ]; ok $? "root: the CLI's output is captured and its status 5 returned, and it holds only fd 3 (rc $rc, fds '$fdl')"
plan "$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
want rw "$E" "$V/NAME" > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root plan: a device named without /dev/ is accepted and passed as /dev/DEV (rc $rc)"
env -i LINUXFS_FS_TEST_USER=no_such_user_xyz LINUXFS_FS_TEST_VOLUMES="$V" "$DM" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
[ $rc = 1 ] && [ ! -s "$M/plan" ] || { [ $rc = 1 ] && ! grep -q '^env' "$M/plan"; }; ok $? "root plan: no _linuxfs user: exit 1, nothing planned (rc $rc)"
for bad_dev in "/dev/disk" "/dev/disk9s" "/dev/../etc/passwd" "/dev/disk9;ls" "/dev/rdisk9" "disk9/../disk8" "/dev/disk9 " "/dev/disk9s1s2" "/dev/tty" "" "/dev/disk$(printf '9%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34)"; do
  plan "$bad_dev" "$V/NAME" > "$M/plan" 2>&1; rc=$?
  [ $rc = 1 ] && ! grep -q '^fd3' "$M/plan"; ok $? "root plan: device '$(echo "$bad_dev" | cut -c1-24)' is refused (rc $rc)"
done
for bad_mnt in "/tmp/NAME" "$V" "$V/" "$V/NAME/" "$V/NAME/sub" "$V/." "$V/.." "$V/link" "$V/file" "$V/missing" "relative" "$V/../vols/NAME" "/private/var/empty" "/Volumes/../private/var/empty"; do
  plan "/dev/$E" "$bad_mnt" > "$M/plan" 2>&1; rc=$?
  [ $rc = 1 ] && ! grep -q '^mnt' "$M/plan"; ok $? "root plan: mount point '$bad_mnt' is refused (rc $rc)"
done
# spec: tools/fs.c -- a directory under the volumes directory that root does not own (here: that this user does not own)
mkdir -p "$D/vols2"
env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES=/private/var "$DM" "/dev/$E" /private/var/empty > "$M/plan" 2>&1; rc=$?
[ $rc = 1 ] && ! grep -q '^mnt' "$M/plan"; ok $? "root plan: a mount point not owned by the expected owner is refused (rc $rc)"
# spec: tools/fs.c -- the mount point must be on the volumes directory's device: /dev (devfs) is not on /'s
env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES=/ "$DM" "/dev/$E" /dev > "$M/plan" 2>&1; rc=$?
[ $rc = 1 ] && ! grep -q '^mnt' "$M/plan" && grep -q 'another volume' "$M/plan"; ok $? "root plan: a mount point on another device than the volumes directory is refused (rc $rc: $(tail -1 "$M/plan"))"
env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" "$DM" "/dev/$E" "$V/NAME" 2>&1 >/dev/null | grep -q .; [ $? -ne 0 ]; ok $? "root plan: a good run writes nothing to stderr"
# spec: tools/fs.c -- every refusal is on stderr (and syslog) with a reason
plan "/dev/disk9;ls" "$V/NAME" 2>&1 >/dev/null | grep -q '^linuxfs-mount: refused: '; ok $? "root plan: a refusal writes its reason to stderr"
plan "/dev/disk99999" "$V/NAME" 2>&1 >/dev/null | grep -q '^linuxfs-mount: refused: '; ok $? "root plan: a device that cannot be opened is refused on stderr too"
# spec: tools/fs.c -- every other descriptor is closed; the device is on 3 and stays open across exec
rcli() { env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_ROOT_CLI="$M/rootcli" "$DM" "$@"; }
rcli "/dev/$E" "$V/NAME" 4</dev/null 5</dev/null 9</dev/null 3</dev/null > "$M/plan" 2>&1; rc=$?
fdl=$(sed -n 's/^fds: //p' "$M/plan" | sed 's/ *255//')
[ $rc = 5 ] && [ "$fdl" = 3 ] && grep -qx "fd3 /dev/r$E rw" "$M/plan"; ok $? "root: inherited descriptors 3, 4, 5, 9 are gone in the CLI; only the device is open, on 3 (rc $rc, fds '$fdl')"
# spec: tools/fs.c -- closed standard descriptors do not let the device land on 0-2
rcli "/dev/$E" "$V/NAME" <&- >"$M/plan" 2>&1; rc=$?
fdl=$(sed -n 's/^fds: //p' "$M/plan" | sed 's/ *255//')
[ $rc = 5 ] && [ "$fdl" = 3 ] && grep -qx "fd3 /dev/r$E rw" "$M/plan"; ok $? "root: with stdin closed the device still lands on fd 3 and nothing else is open (rc $rc, fds '$fdl')"
# spec: tools/fs.c -- test environment overrides are not honoured by the mount role's environment; the shipped build has no test code at all
env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_CLI=/bin/false LINUXFS_OPEN=/bin/false LINUXFS_LKLFUSE=/bin/false "$DM" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1
grep -qx "env LINUXFS_OPEN=$H/linuxfs-open" "$M/plan" && grep -qx "env LINUXFS_LKLFUSE=$H/lklfuse" "$M/plan"; ok $? "root plan: a caller's LINUXFS_OPEN and LINUXFS_LKLFUSE are not passed on"
# spec: tools/fs.c mount_as_root -- with a macFUSE whose libfuse serves /dev/fd/N (Mavergreen's manifest at or past the first
#       release that ships it), root runs mount_macfuse itself (allow_other is root's to give), takes the device it sends, and
#       hands it to the CLI as fd 4 (LINUXFS_FUSE_FD=4) beside the disk on 3; an older or unreadable manifest keeps the plan above
MF=$D/macfuse; mkdir -p "$MF"
manifest() { plist "$MF/$1.plist" "<key>identifier</key><string>dev.mavergreen.macfuse</string><key>version</key><string>$1</string>"; }
for v in 5.5.0-mavericks.1 5.5.0-mavericks.2 5.5.0-mavericks.10 5.6.0-mavericks.1 6.0.0-mavericks.1 5.4.9-mavericks.9 garbage 5.5.0; do manifest "$v"; done
ln -sf "$MF/5.5.0-mavericks.2.plist" "$MF/link.plist"
cp "$MF/5.5.0-mavericks.2.plist" "$MF/writable.plist"; chmod 664 "$MF/writable.plist"
HELPER=/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse
fplan() { # MANIFEST ARGS...: the drop build's plan with that macFUSE manifest (COMMFD's number as N)
  mf=$1; shift
  env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_MACFUSE="$mf" LINUXFS_PREFS_USER="$D/none.plist" \
    LINUXFS_PREFS_MACHINE="${MACHP:-$D/none2.plist}" "$DM" "$@" > "$M/fplan.out"; frc=$?
  sed 's/^helper-env _FUSE_COMMFD=[0-9][0-9]*$/helper-env _FUSE_COMMFD=N/' "$M/fplan.out"; return $frc; }
fwant() { # RW HELPER-OPTIONS DEV MNT [ARGV-FLAGS]: the plan the brief prescribes for root's mount
  rw=$1 hopts=$2 dv=$3 mn=$4; shift 4
  printf 'user daemon\nuid %s\ngid %s\nfd3 /dev/r%s %s\nmnt %s\n' "$UID_D" "$(id -g daemon)" "$dv" "$rw" "$mn"
  printf 'helper %s\nhelper-argv -o\nhelper-argv %s\nhelper-argv %s\n' "$HELPER" "$hopts" "$mn"
  printf 'helper-env _FUSE_CALL_BY_LIB=1\nhelper-env _FUSE_COMMVERS=2\nhelper-env _FUSE_DAEMON_PATH=%s/lklfuse\nhelper-env _FUSE_COMMFD=N\nfd4 the macFUSE device\n' "$H"
  printf 'env HOME=/private/var/db/linuxfs\nenv PATH=/usr/bin:/bin:/usr/sbin:/sbin\nenv LINUXFS_DA=1\nenv LINUXFS_ALL_USERS=1\nenv LINUXFS_OPEN_INHERITED=1\n'
  printf 'env LINUXFS_LKLFUSE=%s/lklfuse\nenv LINUXFS_PROBE=%s/linuxfs-probe\nenv LINUXFS_OPEN=%s/linuxfs-open\nenv LINUXFS_FUSE_FD=4\n' "$H" "$H" "$H"
  printf 'argv %s/linuxfs\nargv da-mount\n' "$H"
  for a in "$@"; do printf 'argv %s\n' "$a"; done
  printf 'argv /dev/%s\nargv %s\n' "$dv" "$mn"
}
fplan "$MF/5.5.0-mavericks.2.plist" -o nodev -o noowners -o nosuid "/dev/$E" "$V/NAME" > "$M/plan" 2>"$M/plan.err"; rc=$?
fwant rw "allow_other,local,volname=NAME,fsname=linuxfs@$E,noappledouble" "$E" "$V/NAME" > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: mount_macfuse's fixed path, argv, the libfuse handshake's environment, the device as fd 4, LINUXFS_FUSE_FD=4 (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
fplan "$MF/5.5.0-mavericks.2.plist" -o owners,rdonly "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
fwant ro "allow_other,local,volname=NAME,fsname=linuxfs@$E,noappledouble,rdonly" "$E" "$V/NAME" --asked --ro > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: read-only adds rdonly to mount_macfuse's options and --ro to the CLI's (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
mkdir -p "$V/a,b=c"
fplan "$MF/5.5.0-mavericks.2.plist" "/dev/$E" "$V/a,b=c" > "$M/plan" 2>&1
grep -qx "helper-argv allow_other,local,volname=a-b-c,fsname=linuxfs@$E,noappledouble" "$M/plan"; ok $? "root mount plan: the volume name is the mount point's, made safe for an option list ($(grep '^helper-argv a' "$M/plan"))"
fplan "$MF/5.5.0-mavericks.2.plist" "/dev/$E" "$V/NAME" 2>&1 >/dev/null | grep -q .; [ $? -ne 0 ]; ok $? "root mount plan: a good run writes nothing to stderr"
# spec: tools/fsrules.h fsrules_access -- root decides read-only before the kernel mount, by the CLI's rule (the probe's type and
#       flags, ReadOnly, APFSWrite, DiskArbitration's rdonly), so the mount matches what lklfuse serves; an encrypted
#       volume before login is refused: no keychain and no one to ask for its password
cp "$D/apfs.img" "$D/apfs-enc.img"
/usr/bin/python - "$D/apfs-enc.img" <<'EOP'
import struct, sys
f = open(sys.argv[1], 'r+b'); n = 0
while True:
    b = f.read(4096)
    if len(b) < 4096: break
    if b[32:36] == b'APSB':
        f.seek(-4096 + 264, 1); f.write(struct.pack('<B', ord(b[264]) & 0xfe)); f.seek(4096 - 265, 1); n += 1
assert n > 0
EOP
td=$(att ntfs-dirty.img); a=$(att apfs.img); ae=$(att apfs-enc.img); devs="$devs $td $a $ae"
TD=${td#/dev/} A=${a#/dev/} AE=${ae#/dev/}
plist "$D/apfswrite.plist" "<key>APFSWrite</key><true/>"
plist "$D/readonly.plist" "<key>ReadOnly</key><true/>"
F2=$MF/5.5.0-mavericks.2.plist
fro() { # DEV WHAT [MACHINE-PREFS]: root's mount of DEV is read-only (rdonly, --ro), the device still opened read-write
  MACHP=${3:-} fplan "$F2" "/dev/$1" "$V/NAME" > "$M/plan" 2>&1; rc=$?
  fwant rw "allow_other,local,volname=NAME,fsname=linuxfs@$1,noappledouble,rdonly" "$1" "$V/NAME" --ro > "$M/want"
  [ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: $2: rdonly to mount_macfuse, --ro to the CLI (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
}
frw() { # DEV WHAT [MACHINE-PREFS]: root's mount of DEV is read-write
  MACHP=${3:-} fplan "$F2" "/dev/$1" "$V/NAME" > "$M/plan" 2>&1; rc=$?
  fwant rw "allow_other,local,volname=NAME,fsname=linuxfs@$1,noappledouble" "$1" "$V/NAME" > "$M/want"
  [ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: $2: read-write (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
}
fro "$TD" "a dirty NTFS volume"
frw "$T" "a clean NTFS volume"
fro "$A" "APFS without APFSWrite"
frw "$A" "APFS with APFSWrite" "$D/apfswrite.plist"
fro "$E" "the ReadOnly preference" "$D/readonly.plist"
MACHP=$D/apfswrite.plist fplan "$F2" "/dev/$AE" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
[ $rc = 1 ] && ! grep -q '^helper' "$M/plan" && ! grep -q '^argv' "$M/plan" && grep -q '^linuxfs-mount: refused: .*encrypted' "$M/plan.err"
ok $? "root: an encrypted volume before login is refused, nothing run (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
fplan "$MF/5.5.0-mavericks.1.plist" "/dev/$AE" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
[ $rc = 1 ] && ! grep -q '^argv' "$M/plan" && grep -q 'encrypted' "$M/plan.err"; ok $? "and so with an older macFUSE: _linuxfs never runs for it (rc $rc)"
fplan "$MF/5.5.0-mavericks.1.plist" "/dev/$TD" "$V/NAME" > "$M/plan" 2>&1; rc=$?
want rw "$TD" "$V/NAME" --ro > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "with an older macFUSE the CLI is told --ro by the same rule (rc $rc: $(diff "$M/plan" "$M/want" | head -2 | tr '\n' ';'))"
# spec: tools/fs.c -- the capability gate: MACFUSE_FD_MOUNTPOINT_SINCE, compared as numbers (5.5.0-mavericks.10 is past .2)
for v in 5.5.0-mavericks.2 5.5.0-mavericks.10 5.6.0-mavericks.1 6.0.0-mavericks.1; do
  fplan "$MF/$v.plist" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1
  grep -q '^helper-argv' "$M/plan" && grep -qx 'env LINUXFS_FUSE_FD=4' "$M/plan"; ok $? "macFUSE $v serves /dev/fd/N: root mounts"
done
want rw "$E" "$V/NAME" > "$M/want"
for v in 5.5.0-mavericks.1 5.4.9-mavericks.9 garbage 5.5.0 link writable missing; do
  fplan "$MF/$v.plist" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
  [ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "macFUSE manifest $v (older, unreadable, a symlink, group-writable or none): the plan before this one, _linuxfs mounts (rc $rc: $(diff "$M/plan" "$M/want" | head -2 | tr '\n' ';'))"
done
# spec: tools/fs.c -- the handshake, with a stand-in mount helper (tests/lib/mount-helper-stub.c) and a stand-in CLI that answers
#       INIT by writing to fd 4 (the stand-in device); root waits for the helper's status, bounded
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld -o "$D/drop/mhelper" "$ROOT/tests/lib/mount-helper-stub.c" || exit 1
cat > "$M/fdcli" <<'EOS'
#!/bin/sh
# spec: tests/fs-test.sh -- the stand-in CLI: its mode (ok | linger | exit N) in $0.mode; logs its env and descriptors to $0.log
m=$(cat "$0.mode" 2>/dev/null)
env > "$0.log"
/usr/bin/python -c 'import os, stat
o = []
for f in range(3, 256):
    try:
        s = os.fstat(f); o.append(str(f) + (":sock" if stat.S_ISSOCK(s.st_mode) else ""))
    except OSError:
        pass
print("fds: " + " ".join(o))' >> "$0.log"
case $m in
  exit*) exit "${m#exit }" ;;
  linger) printf x >&4; sleep 30 > /dev/null 2>&1 < /dev/null 4>&- & echo "lingerer $!" >> "$0.log"; exit 0 ;;
  *) printf x >&4; echo "answered INIT"; exit 0 ;;
esac
EOS
chmod +x "$M/fdcli"
hs() { # HELPER-MODE CLI-MODE [WAIT]: root's mount with both stand-ins; status in rc, output in $M/plan; HS_ENV adds to its environment, HS_WRAP runs it
  rm -f "$D/drop/mhelper.log" "$M/fdcli.log"
  if [ -n "$1" ]; then echo "$1" > "$D/drop/mhelper.mode"; else rm -f "$D/drop/mhelper.mode"; fi
  echo "$2" > "$M/fdcli.mode"
  env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_MACFUSE="$MF/5.5.0-mavericks.2.plist" \
    LINUXFS_FS_TEST_MOUNT_HELPER="$D/drop/mhelper" LINUXFS_FS_TEST_ROOT_CLI="$M/fdcli" ${3:+LINUXFS_FS_TEST_WAIT=$3} ${HS_ENV:-} \
    ${HS_WRAP:-} "$DM" "/dev/$E" "$V/NAME" 7</dev/null > "$M/plan" 2>&1; rc=$?; }
gone() { [ -z "$1" ] || ! ps -p "$1" > /dev/null; }
hs "" ok; t0=$rc
[ $t0 = 0 ] && grep -q '^status 0$' "$D/drop/mhelper.log" && grep -q '^cli-rc 0' "$M/plan"; ok $? "root: the helper's device reaches the CLI, the CLI answers INIT, status 0: exit 0 (rc $t0)"
fdl=$(sed -n 's/^fds: //p' "$M/fdcli.log" | sed 's/ *255//')
[ "$fdl" = "3 4:sock" ]; ok $? "the CLI holds the disk on 3 and the device on 4, nothing else ('$fdl')"
grep -qx LINUXFS_FUSE_FD=4 "$M/fdcli.log"; ok $? "the CLI's environment names the device: LINUXFS_FUSE_FD=4"
hfd=$(sed -n 's/^env _FUSE_COMMFD=//p' "$D/drop/mhelper.log")
[ "$(grep '^env ' "$D/drop/mhelper.log" | sort | tr '\n' ' ')" = "$(printf 'env _FUSE_CALL_BY_LIB=1\nenv _FUSE_COMMFD=%s\nenv _FUSE_COMMVERS=2\nenv _FUSE_DAEMON_PATH=%s/lklfuse\n' "$hfd" "$H" | sort | tr '\n' ' ')" ]
ok $? "the helper's environment is the handshake's four variables and nothing else ($(grep '^env ' "$D/drop/mhelper.log" | tr '\n' ' '))"
[ "$(sed -n 's/^fds //p' "$D/drop/mhelper.log")" = "0 1 2 $hfd" ]; ok $? "the helper holds 0-2 and its socket only, never the disk ($(sed -n 's/^fds //p' "$D/drop/mhelper.log"))"
[ "$(grep '^argv ' "$D/drop/mhelper.log" | tr '\n' '|')" = "argv -o|argv allow_other,local,volname=NAME,fsname=linuxfs@$E,noappledouble|argv $V/NAME|" ]; ok $? "the helper's argv is -o OPTIONS MNT"
hs "status 5" ok
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc != 0 ] && gone "$hp"; ok $? "a helper status of 5 fails the mount (rc $rc) and the helper is gone"
s0=$(date +%s); hs "" "exit 3"; t=$(( $(date +%s) - s0 ))
[ $rc = 3 ] && grep -q '^status 57$' "$D/drop/mhelper.log" && [ $t -lt 8 ]; ok $? "a CLI that refuses (exit 3) closes the device, the mount fails, and root exits 3 in $t s (rc $rc, $(grep '^status' "$D/drop/mhelper.log"))"
s0=$(date +%s); hs nofd ok 2; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 1 ] && [ ! -e "$M/fdcli.log" ] && [ $t -lt 8 ] && gone "$hp"; ok $? "a helper that sends no device: exit 1 after the bounded wait ($t s), the CLI never runs, the helper is killed (rc $rc)"
s0=$(date +%s); hs nostatus linger 2; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log"); lp=$(sed -n 's/^lingerer //p' "$M/fdcli.log")
sleep 1
[ $rc = 1 ] && [ $t -lt 10 ] && gone "$hp" && [ -n "$lp" ] && gone "$lp"; ok $? "a helper that never reports: exit 1 after the bounded wait ($t s); the helper and what the CLI left running are killed (rc $rc, lingerer '$lp')"
hs "" linger
lp=$(sed -n 's/^lingerer //p' "$M/fdcli.log")
[ $rc = 0 ] && [ -n "$lp" ] && ps -p "$lp" > /dev/null; ok $? "on success what the CLI left running (lklfuse) keeps running (rc $rc)"
[ -z "$lp" ] || kill "$lp" 2>/dev/null
# spec: tools/fs.c mount_by_root -- mount_macfuse still running 2 s after a good mount: SIGTERM, then SIGKILL 1 s later; reaped
s0=$(date +%s); hs linger ok; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 0 ] && [ -n "$hp" ] && gone "$hp" && [ $t -ge 2 ] && [ $t -lt 6 ]; ok $? "a mount_macfuse that lingers after a good mount is stopped and reaped: no root helper left (rc $rc, $t s)"
s0=$(date +%s); hs stubborn ok; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 0 ] && [ -n "$hp" ] && gone "$hp" && [ $t -ge 3 ] && [ $t -lt 7 ]; ok $? "one that ignores SIGTERM is killed a second later (rc $rc, $t s)"
# spec: tools/fs.c mount_by_root -- a CLI that fails before lklfuse answers INIT while mount_macfuse keeps the device (blocked in
#       mount(2) on INIT, as the real one may be): root still ends, bounded, and stops it; one that outlives even SIGKILL
#       (LINUXFS_FS_TEST_NOKILL makes root's SIGKILL a no-op) is reported, on stderr and syslog, not left silently
s0=$(date +%s); hs hold "exit 3"; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 3 ] && [ $t -lt 15 ] && [ -n "$hp" ] && gone "$hp"; ok $? "mount_macfuse holding the device with no status, the CLI failed: root exits 3 in $t s and mount_macfuse is gone (rc $rc)"
s0=$(date +%s); HS_ENV=LINUXFS_FS_TEST_NOKILL=1; hs holdstubborn "exit 3"; unset HS_ENV; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 3 ] && [ $t -lt 20 ] && [ -n "$hp" ] && grep -q "mount_macfuse (pid $hp) is still running after SIGKILL" "$M/plan"
ok $? "one that outlives SIGKILL: root still exits 3 in $t s, and says it is left running ($(grep -i 'still running' "$M/plan" | tr '\n' ' '))"
[ -z "$hp" ] || kill -9 "$hp" 2>/dev/null
HS_ENV=LINUXFS_FS_TEST_NOKILL=1; hs stubborn ok; unset HS_ENV
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 0 ] && [ -n "$hp" ] && grep -q "mount_macfuse (pid $hp) is still running after SIGKILL" "$M/plan"; ok $? "after a good mount too, a mount_macfuse that outlives SIGKILL is reported (rc $rc)"
[ -z "$hp" ] || kill -9 "$hp" 2>/dev/null
# spec: tools/fs.c mount_by_root -- the status is read without blocking, under the same deadline: 2 of its 4 bytes and no more
#       end in the bounded wait, not a hang (a watchdog ends a hung run at 20 s)
s0=$(date +%s); hs partial ok 2 & hj=$!
( sleep 20; kill $hj 2>/dev/null; pkill -f "$DM" 2>/dev/null ) & wd=$!
wait $hj; rc=$?; t=$(( $(date +%s) - s0 )); kill $wd 2>/dev/null
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $t -lt 15 ] && gone "$hp" && grep -q "^linuxfs-mount: root's mount of $E failed" "$M/plan"; ok $? "a status cut short after 2 bytes: root gives up in the bounded wait ($t s) and stops mount_macfuse"
# spec: tools/fs.c recv_device -- a message with more than one descriptor is refused, and root closes every one it got
hs twofds ok 2; sleep 2
[ $rc = 1 ] && grep -q '^closed by root 2$' "$D/drop/mhelper.log"; ok $? "two descriptors in the device's message: refused (rc $rc), both closed ($(grep '^closed' "$D/drop/mhelper.log"))"
# spec: tools/fs.c mount_role -- SIGCHLD back to its default first: started with it ignored, root would never see an exit status
HS_WRAP='/usr/bin/perl -e $SIG{CHLD}="IGNORE";exec(@ARGV)'; hs "" "exit 3"; unset HS_WRAP
[ $rc = 3 ]; ok $? "started with SIGCHLD ignored, root still gets the CLI's exit 3 (rc $rc)"
# spec: tools/fs.c mount_by_root -- the force-unmount on failure takes only root's own mount: from linuxfs@DISK, a macfuse (or
#       osxfuse) file system; another volume on MNT is left. (The matching case needs a real macFUSE mount: the VM smoke's.)
rm -f "$D/foreign.dmg"; hdiutil create -quiet -size 4m -fs HFS+ -volname foreign "$D/foreign.dmg" && cp "$D/foreign.dmg" "$D/drop/mhelper.img"
hs foreign ok
fm=$(mount | grep -F " on $V/NAME (")
[ $rc != 0 ] && grep -q '^attached 0$' "$D/drop/mhelper.log" && [ -n "$fm" ]; ok $? "a volume on MNT that is not root's mount is never force-unmounted (rc $rc, '$fm')"
fd9=$(hdiutil info | awk -v p="$D/drop/mhelper.img" '/^image-path/ { sub(/^image-path[ \t]*:[ \t]*/, ""); cur = ($0 == p) } cur && /^\/dev\/disk[0-9]+[ \t]/ { print $1; exit }')
[ -z "$fd9" ] || hdiutil detach -quiet -force "$fd9" 2>/dev/null
! strings "$D/linuxfs-fs" | grep -q 'LINUXFS_FS_TEST'; ok $? "the shipped build carries no LINUXFS_FS_TEST_* code"
! grep -q 'LINUXFS_FS_TEST' "$ROOT"/build/*.sh; ok $? "no build script defines LINUXFS_FS_TEST_DROP"
echo "1..$n"; exit $bad
