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
  -o "$D/linuxfs-fs" "$ROOT/tools/fs.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/plist.c" "$ROOT/tools/probe.c" "$ROOT/tools/trust.c" \
  -framework CoreFoundation -framework DiskArbitration || exit 1
for n in macfuse_ext4.util macfuse_ntfs.util macfuse_btrfs.util fsck_macfuse_ext4 mount_macfuse_ext4 bogus.util; do cp "$D/linuxfs-fs" "$D/$n"; done
# gpt2.img: two ext4 partitions on one GPT disk (tests/lib/gpt-wrap.py), for the sibling partitions (final review r0 C1)
sh "$ROOT/build/linux-host.sh" sh -c "cd '$D' && sh '$ROOT/tests/lib/probe-images.sh' '$D' && blkid -s UUID -o value ext4.img > ext4.uuid && blkid -s UUID -o value btrfs.img > btrfs.uuid && python3 -I '$ROOT/tests/lib/gpt-wrap.py' ext4.img gpt2.img 0FC63DAF-8483-4772-8E79-3D69D8477DE4 ext4.img 0FC63DAF-8483-4772-8E79-3D69D8477DE4" || exit 1
n=0 bad=0
# spec: Task 16j -- the console user's mount program asks root's daemon first; no case here meets a real one (the ask: cases name their own)
LINUXFS_MOUNTD_SOCK=$D/no-mountd.sock; export LINUXFS_MOUNTD_SOCK
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
att() { hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$D/$1" | awk 'NR == 1 { print $1 }'; }
devs=
# the end, however it comes: the stand-in daemon, a background root run and its watchdog, and the last CLI group it named go first,
# so nothing holds a disk when it is detached (task-16j-findings-r0.md m8)
mdpid= tp= wd= lastcg=
cleanup() {
  for p in $mdpid $tp $wd; do kill "$p" 2>/dev/null; done
  test -z "$lastcg" || ! kill -0 -- "-$lastcg" 2>/dev/null || kill -9 -- "-$lastcg" 2>/dev/null
  for d in $devs; do hdiutil detach -quiet -force "$d" 2>/dev/null; done; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
e=$(att ext4.img); b=$(att btrfs.img); t=$(att ntfs.img); g=$(att gpt2.img); devs="$e $b $t $g"
echo "# attached $e $b $t $g"
E=${e#/dev/}; B=${b#/dev/}; T=${t#/dev/}; G=${g#/dev/}
plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$2" > "$1"; }
plist "$D/empty.plist" ""
plist "$D/take.plist" "<key>NTFSTakeover</key><true/>"
plist "$D/takestr.plist" "<key>NTFSTakeover</key><string>YES</string>"
plist "$D/takeoff.plist" "<key>NTFSTakeover</key><true/><key>Automount</key><false/>"   # a stale Automount, from before it was dropped
printf 'this is not a plist' > "$D/corrupt.plist"
u() { # BIN ARGS... : the util with the test prefs (USERP, MACHP)
  x=$1; shift; LINUXFS_PREFS_USER=${USERP:-$D/none.plist} LINUXFS_PREFS_MACHINE=${MACHP:-$D/none2.plist} "$D/$x" "$@"; }
out=$(u macfuse_ext4.util -p "$E" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = "my data" ]; ok $? "ext4 util -p on the ext4 disk prints the label and exits 255 (rc $rc, '$out')"
out=$(u macfuse_ext4.util -p "$E" fixed readonly); rc=$?
[ $rc = 255 ] && [ "$out" = "my data" ]; ok $? "ext4 is claimed fixed and readonly too (rc $rc)"
out=$(u macfuse_btrfs.util -p "$E" removable writable); rc=$?
[ $rc = 254 ] && [ -z "$out" ]; ok $? "btrfs util on the ext4 disk exits 254 and prints nothing (rc $rc)"
out=$(u macfuse_btrfs.util -p "$B" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = backup ]; ok $? "btrfs util on the btrfs disk exits 255 (rc $rc, '$out')"
# spec: tools/fs.c -- -k as 10.9's hfs.util does it, which DiskArbitration reads (its fstab UUID= lookup needs it): the UUID,
#       uppercase, with no newline, and exit 253 (FSUR_IO_SUCCESS, not -p's 255: DiskArbitration drops the UUID otherwise)
out=$(u macfuse_ext4.util -k "$E"); rc=$?
want=$(tr a-f A-F < "$D/ext4.uuid")
[ $rc = 253 ] && [ "$out" = "$want" ]; ok $? "-k prints the UUID blkid gave, exit 253 (rc $rc, '$out', want '$want')"
[ "$(u macfuse_ext4.util -k "$E" | wc -c | tr -d ' ')" = 36 ]; ok $? "-k prints the 36 characters alone, no newline"
out=$(u macfuse_btrfs.util -k "$B"); rc=$?
[ $rc = 253 ] && [ "$out" = "$(tr a-f A-F < "$D/btrfs.uuid")" ]; ok $? "-k on btrfs prints its UUID too"
out=$(u macfuse_btrfs.util -k "$E"); rc=$?
[ $rc = 254 ] && [ -z "$out" ]; ok $? "-k for another filesystem's disk exits 254"
out=$(u macfuse_ntfs.util -k "$T"); rc=$?
[ $rc = 254 ]; ok $? "-k on NTFS (no UUID) exits 254 (rc $rc)"
u macfuse_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFS util with no prefs exits 254 (rc $rc)"
USERP=$D/empty.plist u macfuse_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFS util with a plist lacking NTFSTakeover exits 254 (rc $rc)"
out=$(USERP=$D/take.plist u macfuse_ntfs.util -p "$T" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = Windows ]; ok $? "NTFSTakeover=true: NTFS removable exits 255, prints the label (rc $rc, '$out')"
USERP=$D/takestr.plist u macfuse_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "NTFSTakeover as the string YES counts (rc $rc)"
USERP=$D/take.plist u macfuse_ntfs.util -p "$T" fixed writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "NTFSTakeover=true but fixed: exits 254 (rc $rc)"
USERP=$D/takeoff.plist u macfuse_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "a stale Automount=false is not read: NTFSTakeover=true still claims (rc $rc)"
USERP=$D/corrupt.plist MACHP=$D/take.plist u macfuse_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "a corrupt user plist counts as absent: the machine's NTFSTakeover=true holds (rc $rc)"
USERP=$D/empty.plist MACHP=$D/take.plist u macfuse_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "prefs fall back key by key: a user plist lacking the key leaves the machine's NTFSTakeover=true (rc $rc)"
USERP=$D/missing.plist MACHP=$D/missing2.plist u macfuse_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "missing plists use the defaults: ext4 still claimed (rc $rc)"
ln -sf "$D/take.plist" "$D/link.plist"
USERP=$D/link.plist u macfuse_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "a symlinked user plist is refused, as absent (rc $rc)"
# spec: tools/fs.c util -- a stale Ignore:<LABEL> is not read: DiskArbitration applies /etc/fstab's noauto, per volume
plist "$D/ign.plist" "<key>Ignore:my data</key><true/>"
out=$(USERP=$D/ign.plist MACHP=$D/ign.plist u macfuse_ext4.util -p "$E" removable writable); rc=$?
[ $rc = 255 ] && [ "$out" = "my data" ]; ok $? "the probe does not consult Ignore:<LABEL>: still claimed (rc $rc, '$out')"
for bad_args in "-p diskX removable writable" "-p ../disk2 removable writable" "-p ${E}s removable writable" "-p $E sometimes writable" "-p $E" "-z" ""; do
  # shellcheck disable=SC2086
  u macfuse_ext4.util $bad_args >/dev/null 2>&1; rc=$?
  [ $rc = 254 ]; ok $? "bad arguments '$bad_args' exit 254 (rc $rc)"
done
u macfuse_ext4.util -p disk99999 removable writable >/dev/null 2>&1; rc=$?
[ $rc = 254 ]; ok $? "a disk that does not exist exits 254 (rc $rc)"
u bogus.util -p "$E" removable writable >/dev/null 2>&1; rc=$?
[ $rc = 254 ]; ok $? "an unknown program name exits 254 (rc $rc)"
u fsck_macfuse_ext4 -q "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 0 ]; ok $? "fsck -q exits 0 (rc $rc)"
out=$(u fsck_macfuse_ext4 -n "/dev/r$E" 2>&1); rc=$?
[ $rc = 8 ] && [ "$out" = "Verify and Repair for ext4 come with its tools" ]; ok $? "fsck -n exits 8 and says why (rc $rc, '$out')"
u fsck_macfuse_ext4 -y "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck -y exits 8 (rc $rc)"
u fsck_macfuse_ext4 >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck with no flag exits 8 (rc $rc)"
out=$(u fsck_macfuse_ext4 -z "/dev/r$E" 2>&1 >/dev/null); rc=$?
[ $rc = 8 ] && case $out in usage:*) true ;; *) false ;; esac; ok $? "fsck with an unknown flag exits 8 with a usage line on stderr (rc $rc, '$out')"
u fsck_macfuse_ext4 -qn "/dev/r$E" >/dev/null 2>&1; rc=$?
[ $rc = 8 ]; ok $? "fsck flags are parsed exactly: -qn is not -q (rc $rc)"
# spec: tools/fs.c mount role -- as the console user, with stand-ins for the CLI, the keychain keeper and the dialog
M=$D/mount; mkdir -p "$M"; MD=$D/mount_macfuse_ext4
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
# spec: tools/fs.c mount_role -- the user path exits 0 only with the mount in the table: LINUXFS_MNTTAB (TYPE<TAB>FROM<TAB>ON<TAB>OWNER
#       lines, last on top) stands in for it; by default it holds the stand-in CLI's mount of disk9 on /tmp/m (an inner env names another)
printf 'macfuse_ext4\t/dev/disk9\t/tmp/m\t%s\n' "$(id -u)" > "$M/mnttab"
mt() { # ARGS...: the mount role with a bare environment, HOME unset, the stand-ins in place
  rm -f "$M/log" "$M/log.n"
  env -u HOME STUB_LOG="$M/log" LINUXFS_CLI="$M/cli" LINUXFS_DIALOG="$M/dialog" LINUXFS_KEYCHAIN_SOCK="$SOCK" LINUXFS_MNTTAB="$M/mnttab" "$@"; }
rm -f "$SOCK"
mt "$MD" -o nodev -o noowners /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -qx 'args: da-mount /dev/disk9 /tmp/m' "$M/log"; ok $? "mount runs 'da-mount DEV MNT' for -o nodev -o noowners (rc $rc: $(head -1 "$M/log" 2>/dev/null))"
grep -q "^HOME=$PWHOME DA=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin\$" "$M/log"; ok $? "the CLI gets HOME from passwd ($PWHOME), LINUXFS_DA=1 and the bare PATH ($(sed -n 2p "$M/log" 2>/dev/null))"
# spec: item 6 ("Ignore ownership") -- owners (an /etc/fstab or vsdb entry's, which DiskArbitration puts after its own noowners)
#       is passed on as --owners: the CLI then shows Linux's ids, with the kernel checking them (default_permissions)
mt "$MD" -o nodev -o owners /dev/disk9 /tmp/m >/dev/null 2>&1
grep -qx 'args: da-mount --owners /dev/disk9 /tmp/m' "$M/log"; ok $? "-o owners adds --owners ($(head -1 "$M/log" 2>/dev/null))"
mt "$MD" -o nodev -o noowners -o nosuid -o owners /dev/disk9 /tmp/m >/dev/null 2>&1
grep -qx 'args: da-mount --owners /dev/disk9 /tmp/m' "$M/log"; ok $? "noowners then owners (DiskArbitration's order): --owners ($(head -1 "$M/log" 2>/dev/null))"
mt "$MD" -o rdonly /dev/disk9 /tmp/m >/dev/null 2>&1
grep -qx 'args: da-mount --ro /dev/disk9 /tmp/m' "$M/log"; ok $? "-o rdonly adds --ro"
mt "$MD" -o owners,rdonly /dev/disk9 /tmp/m >/dev/null 2>&1
grep -qx 'args: da-mount --ro --owners /dev/disk9 /tmp/m' "$M/log"; ok $? "owners with rdonly: --ro --owners ($(head -1 "$M/log" 2>/dev/null))"
# spec: item 6 -- mount -u (vsdbutil's, after diskutil enableOwnership) cannot be done: macFUSE's kernel refuses MNT_UPDATE
#       (ENOTSUP). It is refused before the CLI runs, rather than taken for a second mount on the same mount point
mt "$MD" -o perm,nosuid,nodev,update /dev/disk9 /tmp/m >/dev/null 2>"$M/err"; rc=$?
[ $rc = 1 ] && [ ! -s "$M/log" ] && grep -q 'update' "$M/err"; ok $? "an update is refused without running the CLI (rc $rc: $(cat "$M/err"))"
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
rm -f "$M/log"; env -u HOME STUB_LOG="$M/log" LINUXFS_CLI="$M/clibg" LINUXFS_MNTTAB="$M/mnttab" "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
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
# spec: .superpowers/sdd/2026-11-25-hfs-parity/push-d-debug.md -- one exit gate: whichever run of the CLI said 0 (the first try, the keeper's
#       password or the dialog's), the mount program exits 0 only if the mount table's topmost mount on MNT is the bundle's type from
#       /dev/BSD (any owner); else exit 1, saying so, so DiskArbitration never records a mount that is not there
cat > "$M/cliok" <<'EOS'
#!/bin/sh
echo "args: $*" >> "$STUB_LOG"
echo /tmp/m
exit 0
EOS
chmod +x "$M/cliok"
: > "$M/mnttab-none"
mt env LINUXFS_CLI="$M/cliok" LINUXFS_MNTTAB="$M/mnttab-none" "$MD" /dev/disk9 /tmp/m >/dev/null 2>"$M/err"; rc=$?
[ $rc = 1 ] && grep -q 'the CLI exited 0 but nothing is mounted on /tmp/m' "$M/err"; ok $? "user path: the CLI exits 0 with nothing mounted -> exit 1 (rc $rc: $(cat "$M/err"))"
kc saved pw
mt env LINUXFS_MNTTAB="$M/mnttab-none" STUB_PW=pw "$MD" /dev/disk9 /tmp/m >/dev/null 2>"$M/err"; rc=$?
kcstop
[ $rc = 1 ] && grep -qx 'stdin: pw' "$M/log" && grep -q 'nothing is mounted on /tmp/m' "$M/err"; ok $? "user path: the keeper's password, then the CLI exits 0 with nothing mounted -> exit 1 (rc $rc)"
kc none
mt env LINUXFS_MNTTAB="$M/mnttab-none" STUB_PW=pw DLG_PWS=pw DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>"$M/err"; rc=$?
kcstop
[ $rc = 1 ] && grep -q '^dialog' "$M/log" && grep -q 'nothing is mounted on /tmp/m' "$M/err"; ok $? "user path: the dialog's password, then the CLI exits 0 with nothing mounted -> exit 1 (rc $rc)"
mt env LINUXFS_CLI="$M/cliok" "$MD" /dev/disk9 /tmp/m >/dev/null 2>"$M/err"; rc=$?
[ $rc = 0 ]; ok $? "user path: the CLI exits 0 with the mount in the table -> exit 0 (rc $rc: $(cat "$M/err"))"
for l in "macfuse_ext4	/dev/disk8	/tmp/m	0" "macfuse_xfs	/dev/disk9	/tmp/m	0" "macfuse_ext4	/dev/disk9	/tmp/m2	0" "macfuse_ext4	/dev/disk9	/tmp/m	0
hfs	/dev/disk5s2	/tmp/m	0"; do
  printf '%s\n' "$l" > "$M/mnttab-other"
  mt env LINUXFS_CLI="$M/cliok" LINUXFS_MNTTAB="$M/mnttab-other" "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
  [ $rc = 1 ]; ok $? "user path: the CLI exits 0 but the topmost mount on /tmp/m is not macfuse_ext4 from /dev/disk9 -> exit 1 ($(printf '%s' "$l" | tr '\t\n' ' |'): rc $rc)"
done
printf 'macfuse_ext4\t/dev/disk9\t/tmp/m\t0\n' > "$M/mnttab-root"
mt env LINUXFS_CLI="$M/cliok" LINUXFS_MNTTAB="$M/mnttab-root" "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
[ $rc = 0 ]; ok $? "user path: any owner's mount counts (root's: rc $rc)"
# spec: tools/fs.c run_cli -- the mount program against the REAL cli/linuxfs (da-mount), with stand-ins only for lklfuse, the
#       opener and the prober (the CLI's own LINUXFS_LKLFUSE, LINUXFS_OPEN and LINUXFS_PROBE; its --access is the real
#       linuxfs-probe's): every argv form the mount program builds is accepted (lklfuse runs, and with nothing mounted here
#       the exit is 1, not usage's 2), and the password reaches
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
real() { # ARGS...: the mount role (user path) running the real CLI, whose lklfuse exits at once: nothing can mount here, so the CLI says
#   so (exit 1: an lklfuse that ends before its mount appears is a failure, whatever its status), and an argv it takes is rc 1, not 2
  rm -f "$R/lk.log" "$R"/logs/*.log
  mt env LINUXFS_CLI="$ROOT/cli/linuxfs" LINUXFS_OPEN="$R/open" LINUXFS_LKLFUSE="$R/lklfuse" LINUXFS_PROBE="$R/open" \
    LINUXFS_STATE="$R/state" LINUXFS_LOGS="$R/logs" LINUXFS_LOCKS="$R/locks" LINUXFS_DOMAIN=test.fsreal \
    LINUXFS_MACHINE_DOMAIN="$R/no-machine" LK_LOG="$R/lk.log" REAL_PROBE="$D/linuxfs-probe" "$@"; }
phantom() { grep -q 'lklfuse exited (status 0) before the mount appeared' "$R/logs/rdisk9.log"; }   # rc 1 for exactly that reason (r0 M1)
real "$MD" /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && phantom && grep -q "^lklfuse: .*$R/mnt" "$R/lk.log"; ok $? "the real CLI accepts the plain da-mount argv (rc $rc)"
plist "$R/stale.plist" "<key>Automount</key><false/><key>Ignore:lbl</key><true/>"
real env LINUXFS_DOMAIN="$R/stale" "$MD" /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && phantom && grep -q "^lklfuse: .*$R/mnt" "$R/lk.log"; ok $? "a stale Automount=false and Ignore:<LABEL> are not read: the real CLI mounts (rc $rc)"
real "$MD" -o owners /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && phantom && grep -q "^lklfuse: .*,default_permissions,owner=caller" "$R/lk.log" && ! grep -q "uid=\|gid=\|owner=root" "$R/lk.log"; ok $? "the real CLI takes da-mount --owners: Linux's ids, checked by the kernel, new files the creator's (rc $rc: $(cat "$R/lk.log" 2>/dev/null))"
real "$MD" -o noowners /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && phantom && grep -q "^lklfuse: .*,uid=[0-9]*,gid=[0-9]*,owner=root" "$R/lk.log" && ! grep -q "default_permissions" "$R/lk.log"; ok $? "and with noowners keeps today's mapping (rc $rc: $(cat "$R/lk.log" 2>/dev/null))"
real "$MD" -o rdonly /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && phantom && grep -q "^lklfuse: .*,ro " "$R/lk.log"; ok $? "the real CLI accepts da-mount --ro and mounts read-only (rc $rc)"
kc saved pw
real env FAKE_PROBE=apfs FAKE_ENCRYPTED=pw "$MD" -o owners /dev/disk9 "$R/mnt" >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 1 ] && phantom && grep -q "^pw: pw\$" "$R/lk.log" && grep -q "passfd=5" "$R/lk.log"; ok $? "the real CLI accepts da-mount --password-stdin and lklfuse gets the password on fd 5 (rc $rc: $(tr '\n' '|' < "$R/lk.log" 2>/dev/null))"
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
  -DLINUXFS_FS_TEST_DROP -o "$D/drop/mount_macfuse_ext4" "$ROOT/tools/fs.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/plist.c" "$ROOT/tools/probe.c" "$ROOT/tools/trust.c" \
  -framework CoreFoundation -framework DiskArbitration || exit 1
DM=$D/drop/mount_macfuse_ext4
mkdir -p "$D/short"
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld -DLINUXFS_PROBE_NO_MAIN \
  -DLINUXFS_FS_TEST_DROP -DOPTS_MAX=60 -o "$D/short/mount_macfuse_ext4" "$ROOT/tools/fs.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/plist.c" "$ROOT/tools/probe.c" "$ROOT/tools/trust.c" \
  -framework CoreFoundation -framework DiskArbitration || exit 1
V=$D/vols; rm -rf "$V"; mkdir -p "$V/NAME" "$V/other"; : > "$V/file"; ln -s "$V/NAME" "$V/link"
H=/Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d
UID_D=$(id -u daemon)
# the disks' locks, in a directory the program makes on demand under a parent only root can write in (root's are
# /var/db/dev.mavergreen.linuxfs.locks/dev.mavergreen.linuxfs.mount.<disk>.lock; /var/db is root:wheel 0755)
LKP=$D/lockparent; rm -rf "$LKP"; mkdir -p "$LKP"; chmod 755 "$LKP"
LK=$LKP/locks; LKF=$LK/dev.mavergreen.linuxfs.mount.$E.lock
plan() { # ARGS...: the drop build's plan for user daemon, volumes under $V
  env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_LOCKDIR="$LK" LINUXFS_PREFS_USER="$D/none.plist" \
    LINUXFS_PREFS_MACHINE="${MACHP:-$D/none2.plist}" "$DM" "$@"; }
# spec: tools/fs.c mount_as_root -- with a macFUSE whose libfuse serves /dev/fd/N (Mavergreen's manifest at or past the first
#       release that ships it), root runs mount_macfuse itself (allow_other is root's to give), takes the device it sends, and
#       hands it to the CLI as fd 4 (LINUXFS_FUSE_FD=4) beside the disk on 3; an older or unreadable manifest is refused
MF=$D/macfuse; mkdir -p "$MF"
manifest() { plist "$MF/$1.plist" "<key>identifier</key><string>dev.mavergreen.macfuse</string><key>version</key><string>$1</string>"; }
for v in 5.5.0-mavericks.1 5.5.0-mavericks.2 5.5.0-mavericks.10 5.6.0-mavericks.1 6.0.0-mavericks.1 5.4.9-mavericks.9 garbage 5.5.0; do manifest "$v"; done
ln -sf "$MF/5.5.0-mavericks.2.plist" "$MF/link.plist"
cp "$MF/5.5.0-mavericks.2.plist" "$MF/writable.plist"; chmod 664 "$MF/writable.plist"
HELPER=/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse
fplan() { # MANIFEST ARGS...: the drop build's plan with that macFUSE manifest (COMMFD's number as N)
  mf=$1; shift
  env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_LOCKDIR="$LK" LINUXFS_FS_TEST_MACFUSE="$mf" LINUXFS_FS_TEST_TRUST_ROOT="$D" LINUXFS_PREFS_USER="$D/none.plist" \
    LINUXFS_PREFS_MACHINE="${MACHP:-$D/none2.plist}" ${FP_ENV:-} "$DM" "$@" > "$M/fplan.out"; frc=$?
  sed 's/^helper-env _FUSE_COMMFD=[0-9][0-9]*$/helper-env _FUSE_COMMFD=N/' "$M/fplan.out"; return $frc; }
fwant() { # RW HELPER-OPTIONS DEV MNT [ARGV-FLAGS]: the plan the brief prescribes for root's mount
  rw=$1 hopts=$2 dv=$3 mn=$4; shift 4
  printf 'user daemon\nuid %s\ngid %s\nfd3 /dev/r%s %s\nmnt %s\n' "$UID_D" "$(id -g daemon)" "$dv" "$rw" "$mn"
  printf 'helper %s\nhelper-argv -o\nhelper-argv %s\nhelper-argv %s\n' "$HELPER" "$hopts" "$mn"
  printf 'helper-env _FUSE_CALL_BY_LIB=1\nhelper-env _FUSE_COMMVERS=2\nhelper-env _FUSE_DAEMON_PATH=%s/lklfuse\nhelper-env _FUSE_COMMFD=N\nfd6 the CLI'"'"'s channel to root\n' "$H"
  printf 'env HOME=/private/var/db/linuxfs\nenv PATH=/usr/bin:/bin:/usr/sbin:/sbin\nenv LINUXFS_DA=1\nenv LINUXFS_ALL_USERS=1\nenv LINUXFS_OPEN_INHERITED=1\n'
  printf 'env LINUXFS_LKLFUSE=%s/lklfuse\nenv LINUXFS_PROBE=%s/linuxfs-probe\nenv LINUXFS_OPEN=%s/linuxfs-open\nenv LINUXFS_FUSE_FD=4\nenv LINUXFS_FUSE_CHAN=6\n' "$H" "$H" "$H"
  printf 'argv %s/linuxfs\nargv da-mount\n' "$H"
  for a in "$@"; do printf 'argv %s\n' "$a"; done
  printf 'argv /dev/%s\nargv %s\n' "$dv" "$mn"
}
F2=$MF/5.5.0-mavericks.2.plist
fplan "$F2" "$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
fwant rw "allow_other,nosuid,nodev,local,volname=NAME,fsname=/dev/$E,noappledouble,fstypename=ext4,fssubtype=7" "$E" "$V/NAME" > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root plan: a device named without /dev/ is accepted and passed as /dev/DEV (rc $rc)"
# spec: item 6 (fsname=/dev/<bsd>) -- root's mount is named for its disk, as HFS+'s is, so DiskArbitration and Finder tie it to the disk
grep -q "^helper-argv .*,fsname=/dev/$E,noappledouble," "$M/plan"; ok $? "root plan: mount_macfuse's -o holds fsname=/dev/$E ($(grep '^helper-argv a' "$M/plan"))"
env -i LINUXFS_FS_TEST_USER=no_such_user_xyz LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_LOCKDIR="$LK" "$DM" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
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
env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES=/private/var LINUXFS_FS_TEST_LOCKDIR="$LK" "$DM" "/dev/$E" /private/var/empty > "$M/plan" 2>&1; rc=$?
[ $rc = 1 ] && ! grep -q '^mnt' "$M/plan"; ok $? "root plan: a mount point not owned by the expected owner is refused (rc $rc)"
# spec: tools/fs.c -- the mount point must be on the volumes directory's device: /dev (devfs) is not on /'s. /dev is itself a mount
#       point, which Task 16f's "nothing mounted already" refuses first, so the mount table here is an empty one
: > "$M/empty.mnttab"
env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES=/ LINUXFS_FS_TEST_LOCKDIR="$LK" LINUXFS_FS_TEST_MNTTAB="$M/empty.mnttab" "$DM" "/dev/$E" /dev > "$M/plan" 2>&1; rc=$?
[ $rc = 1 ] && ! grep -q '^mnt' "$M/plan" && grep -q 'another volume' "$M/plan"; ok $? "root plan: a mount point on another device than the volumes directory is refused (rc $rc: $(tail -1 "$M/plan"))"
# spec: Task 16f fix round 1 (m1) -- and with the real mount table (getmntinfo), /dev, devfs's mount point, is something mounted already
env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES=/ LINUXFS_FS_TEST_LOCKDIR="$LK" "$DM" "/dev/$E" /dev > "$M/plan" 2>&1; rc=$?
test $rc = 1 && ! grep -q '^fd3' "$M/plan" && grep -q '^linuxfs-mount: refused: something is mounted on the mount point' "$M/plan"
ok $? "root plan: the real mount table refuses a mount point something is mounted on (/dev) (rc $rc: $(tail -1 "$M/plan"))"
# spec: tools/fs.c -- every refusal is on stderr (and syslog) with a reason
plan "/dev/disk9;ls" "$V/NAME" 2>&1 >/dev/null | grep -q '^linuxfs-mount: refused: '; ok $? "root plan: a refusal writes its reason to stderr"
plan "/dev/disk99999" "$V/NAME" 2>&1 >/dev/null | grep -q '^linuxfs-mount: refused: '; ok $? "root plan: a device that cannot be opened is refused on stderr too"
# spec: Task 16f (root-daemon design I4, N4) -- one mount per disk at a time: root takes the disk's lock (flock, LOCK_EX|LOCK_NB)
#       after the names are checked and before the device is opened; another holder means another mount of the disk is under way
# spec: Task 16f fix rounds 1 and 2 (I1, I1') -- the locks' directory (/var/db/dev.mavergreen.linuxfs.locks; not under /var/run, which is root:daemon 0775) is made on demand, root's
#       (here: this user's, with this user's group) and 0700, and is checked before each use: a symlink, another mode or another
#       group is refused, never repaired
rm -rf "$LK"
fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
test $rc = 0 && test -d "$LK" && test ! -L "$LK" && test "$(stat -f '%Lp %u %g' "$LK")" = "700 $(id -u) $(id -g)"
ok $? "root plan: the locks' directory is made on demand, 0700 (rc $rc, $(stat -f '%Sp %u %g' "$LK" 2>&1))"
lockdir_refused() { # WHAT: a plan now is refused before the device is opened
  fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
  test $rc = 1 && grep -qx "linuxfs-mount: refused: the disks' lock directory is not root's alone (0700, not a symlink)" "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
  ok $? "root plan: $1 → refused (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"; }
mv "$LK" "$LK.real"; ln -s "$LK.real" "$LK"
lockdir_refused "the locks' directory a symlink (to a good one)"
rm -f "$LK"; mv "$LK.real" "$LK"
chmod 755 "$LK"; lockdir_refused "the locks' directory 0755"
test "$(stat -f %Lp "$LK")" = 755; ok $? "and it is left as it is, not repaired ($(stat -f %Lp "$LK"))"
chmod 700 "$LK"
og=$(id -G | tr ' ' '\n' | grep -vx "$(id -g)" | head -1)
if test -n "$og" && chgrp "$og" "$LK" 2>/dev/null; then
  lockdir_refused "the locks' directory of another group ($og)"
  chgrp "$(id -g)" "$LK"
else
  ok 0 "# SKIP no second group to give the locks' directory"
fi
rm -rf "$LK.file"; mv "$LK" "$LK.real"; : > "$LK"; chmod 700 "$LK"
lockdir_refused "a file where the locks' directory goes"
rm -f "$LK"; mv "$LK.real" "$LK"
# spec: Task 16f fix round 2 (I1') -- the locks' directory's parent must pass trust.c's root_only rule (root's; writable by a group
#       only when it is gid 0, by others never; or sticky), or anyone who can write there could rename the directory aside and
#       a second request would make a fresh one; refused, and the parent is left as it was
parent_refused() { # WHAT
  fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
  test $rc = 1 && grep -qx "linuxfs-mount: refused: the disks' lock directory's parent is writable by others than root" "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
  ok $? "root plan: $1 → refused (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"; }
chmod 775 "$LKP"; parent_refused "the locks' directory's parent group-writable (gid $(stat -f %g "$LKP")), not sticky"
test "$(stat -f %Lp "$LKP")" = 775; ok $? "and the parent is left as it was ($(stat -f %Lp "$LKP"))"
chmod 757 "$LKP"; parent_refused "the locks' directory's parent writable by others, not sticky"
chmod 1777 "$LKP"
fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
test $rc = 0; ok $? "root plan: a sticky parent (1777) is root's alone in the rule's sense: accepted (rc $rc: $(tail -n 1 "$M/plan"))"
chmod 755 "$LKP"
rm -rf "$LK"; chmod 775 "$LKP"
parent_refused "no locks' directory yet, and a group-writable parent"
test ! -e "$LK"; ok $? "and no locks' directory is made there"
chmod 755 "$LKP"
fplan "$F2" "/dev/$E" "$V/NAME" > /dev/null 2>&1
chmod 644 "$LKF"
fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
test $rc = 1 && grep -q '^linuxfs-mount: refused: the disk.s lock file' "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
ok $? "root plan: a lock file of another mode than 0600 → refused (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
rm -f "$LKF"
hold() { # SECONDS: a perl that holds the disk's lock that long, in the background ($holder); waits, bounded, until it does
  rm -f "$M/held"
  /usr/bin/perl -MFcntl=:flock -e 'open(my $f, "+<", $ARGV[0]) or exit 1; flock($f, LOCK_EX) or exit 1; open(my $h, ">", $ARGV[1]) or exit 1; close $h; sleep $ARGV[2]' \
    "$LKF" "$M/held" "$1" & holder=$!
  i=0; while test ! -e "$M/held" && test $i -lt 50; do sleep 0.1; i=$((i + 1)); done; }
lockfree() { /usr/bin/perl -MFcntl=:flock -e 'open(my $f, "<", $ARGV[0]) or exit 1; flock($f, LOCK_EX | LOCK_NB) or exit 1' "$LKF"; }
fplan "$F2" "/dev/$E" "$V/NAME" > /dev/null 2>&1	# the lock file, made as the program makes it
hold 5
fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
test $rc = 1 && grep -qx "linuxfs-mount: refused: another mount of $E is under way" "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
ok $? "root plan: the disk's lock held → refused, \"another mount of\", nothing opened (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
rm -f "$LKF" "$D/lock-target"; ln -s "$D/lock-target" "$LKF"
fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
test $rc = 1 && grep -q '^linuxfs-mount: refused: ' "$M/plan.err" && ! grep -q '^fd3' "$M/plan" && test ! -e "$D/lock-target"
ok $? "root plan: a symlink where the lock file goes → refused, nothing created through it (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
rm -f "$LKF"
fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
test $rc = 0 && test -f "$LKF" && test ! -L "$LKF" && test "$(stat -f %Lp "$LKF")" = 600 && lockfree
ok $? "root plan: the lock is free again after a plan (rc $rc, $(ls -l "$LKF" 2>&1))"
# spec: Task 16f -- nothing mounted already: anything on MNT, or anything from /dev/<bsd> (any type, anywhere), refuses the request
#       before the device is opened (the drop build reads LINUXFS_FS_TEST_MNTTAB, TYPE<TAB>FROM<TAB>ON<TAB>OWNER, for the table)
tabplan() { # MNTTAB-LINE: the plan against a mount table of that line
  printf '%s\n' "$1" > "$M/mnttab"
  FP_ENV="LINUXFS_FS_TEST_MNTTAB=$M/mnttab" fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?; }
tabplan "$(printf 'macfuse_ext4\t/dev/disk99\t%s\t0' "$V/NAME")"
test $rc = 1 && grep -qx "linuxfs-mount: refused: something is mounted on the mount point or from $E or its disk already" "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
ok $? "root plan: a mount on MNT → refused (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
tabplan "$(printf 'hfs\t/dev/%s\t/Volumes/other\t501' "$E")"
test $rc = 1 && grep -q '^linuxfs-mount: refused: something is mounted' "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
ok $? "root plan: a mount from /dev/$E elsewhere → refused (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
tabplan "$(printf 'hfs\t/dev/%s1\t/Volumes/other\t0\nhfs\t/dev/disk0s2\t%s/other\t0\nhfs\t/dev/r%s\t/x\t0' "$E" "$V" "$E")"
test $rc = 0 && grep -q '^fd3' "$M/plan"; ok $? "root plan: other mounts (/dev/${E}1, another mount point, /dev/r$E) do not refuse it (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
# spec: Task 16f fix round 1 (m4), and final review r0 C1 -- a whole disk and its partitions exclude each other (a mount from
#       /dev/<whole> refuses a partition; one from any /dev/<whole>s<N> refuses the whole disk), and sibling partitions do not:
#       each is its own volume, as HFS+'s are (a disk with an HFS+ and an ext4 partition mounts both). $G is gpt2.img: two ext4
#       partitions, ${G}s1 and ${G}s2
test -b "/dev/${G}s1" && test -b "/dev/${G}s2"; ok $? "gpt2.img attached as $G with two partitions, ${G}s1 and ${G}s2"
tabplan "$(printf 'hfs\t/dev/%ss1\t/Volumes/other\t501' "$E")"
test $rc = 1 && grep -q "^linuxfs-mount: refused: something is mounted .* from $E or its disk already" "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
ok $? "root plan: the whole disk $E is refused while its partition ${E}s1 is mounted (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
gplan() { # MNTTAB-LINES DEV: the plan for DEV against a mount table of those lines
  printf '%s\n' "$1" > "$M/mnttab"
  FP_ENV="LINUXFS_FS_TEST_MNTTAB=$M/mnttab" fplan "$F2" "$2" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?; }
gplan "$(printf 'hfs\t/dev/%s\t/Volumes/other\t0' "$G")" "/dev/${G}s1"
test $rc = 1 && grep -q "^linuxfs-mount: refused: something is mounted .* from ${G}s1 or its disk already" "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
ok $? "root plan: a partition ${G}s1 is refused while the whole disk $G is mounted (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
gplan "$(printf 'macfuse_ext4\t/dev/%ss1\t/Volumes/other\t0' "$G")" "/dev/${G}s1"
test $rc = 1 && grep -q "^linuxfs-mount: refused: something is mounted .* from ${G}s1 or its disk already" "$M/plan.err" && ! grep -q '^fd3' "$M/plan"
ok $? "root plan: a partition ${G}s1 is refused while it is mounted elsewhere (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
gplan "$(printf 'hfs\t/dev/%ss2\t/Volumes/other\t501' "$G")" "/dev/${G}s1"
test $rc = 0 && grep -qx "fd3 /dev/r${G}s1 rw" "$M/plan"
ok $? "root plan: a partition ${G}s1 mounts while its sibling ${G}s2 is mounted, an HFS+ volume (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
gplan "$(printf 'macfuse_ext4\t/dev/%ss2\t/Volumes/other\t0' "$G")" "/dev/${G}s1"
test $rc = 0 && grep -qx "fd3 /dev/r${G}s1 rw" "$M/plan"
ok $? "root plan: a partition ${G}s1 mounts while its sibling ${G}s2 is root's linuxfs mount (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
# the locks, in two levels: a partition holds its whole disk's lock shared and its own exclusive; a whole disk, its own exclusive.
# holdn SECONDS NAME:EX|SH...: a perl that holds those locks (LK/dev.mavergreen.linuxfs.mount.NAME.lock) that long, in the
# background ($holder); waits, bounded, until it does
holdn() {
  rm -f "$M/held"; hs=$1; shift
  /usr/bin/perl -MFcntl=:flock -e 'my ($held, $secs, $dir, @l) = @ARGV; my @f; for (@l) { my ($n, $m) = split /:/; open(my $f, ">>", "$dir/dev.mavergreen.linuxfs.mount.$n.lock") or exit 1; flock($f, $m eq "SH" ? LOCK_SH : LOCK_EX) or exit 1; push @f, $f } open(my $h, ">", $held) or exit 1; close $h; sleep $secs' \
    "$M/held" "$hs" "$LK" "$@" & holder=$!
  i=0; while test ! -e "$M/held" && test $i -lt 50; do sleep 0.1; i=$((i + 1)); done; }
held_plan() { # DEV OUT ERR: the plan for DEV, with an empty mount table
  : > "$M/mnttab"; FP_ENV="LINUXFS_FS_TEST_MNTTAB=$M/mnttab" fplan "$F2" "$1" "$V/NAME" > "$2" 2> "$3"; }
unhold() { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; }
held_plan "/dev/${G}s1" "$M/plan" "$M/plan.err"; rc=$?
GL=$LK/dev.mavergreen.linuxfs.mount.$G.lock GL1=$LK/dev.mavergreen.linuxfs.mount.${G}s1.lock
test $rc = 0 && test -f "$GL" && test -f "$GL1" && test "$(stat -f '%Lp %l' "$GL1")" = "600 1" && /usr/bin/perl -MFcntl=:flock -e 'for (@ARGV) { open(my $f, "<", $_) or exit 1; flock($f, LOCK_EX | LOCK_NB) or exit 1 }' "$GL" "$GL1"
ok $? "root plan: a partition's plan makes its own lock file beside its whole disk's (0600), and both are free after it (rc $rc, $(ls -l "$GL1" 2>&1))"
held_plan "/dev/${G}s2" "$M/plan" "$M/plan.err"	# ${G}s2's lock file, made as the program makes it
holdn 5 "$G:SH" "${G}s2:EX"	# what root's mount of ${G}s2 holds while it is under way
held_plan "/dev/${G}s1" "$M/plan" "$M/plan.err"; rc1=$?; cp "$M/plan" "$M/plan1"; cp "$M/plan.err" "$M/plan.err1"
held_plan "/dev/${G}s2" "$M/plan" "$M/plan.err2"; rc2=$?
held_plan "/dev/$G" "$M/plan" "$M/plan.err3"; rc3=$?
unhold
test $rc1 = 0 && grep -qx "fd3 /dev/r${G}s1 rw" "$M/plan1"
ok $? "root plan: ${G}s1 and ${G}s2 mount at once: ${G}s1 while ${G}s2's mount holds its locks (rc $rc1: $(tr '\n' ';' < "$M/plan.err1"))"
test $rc2 = 1 && grep -qx "linuxfs-mount: refused: another mount of ${G}s2 is under way" "$M/plan.err2"
ok $? "root plan: ${G}s2 itself is refused while its mount is under way (rc $rc2: $(tr '\n' ';' < "$M/plan.err2"))"
test $rc3 = 1 && grep -qx "linuxfs-mount: refused: another mount of $G is under way" "$M/plan.err3"
ok $? "root plan: the whole disk $G is refused while a partition's mount is under way (rc $rc3: $(tr '\n' ';' < "$M/plan.err3"))"
holdn 5 "$G:EX"	# what root's mount of the whole disk holds
held_plan "/dev/${G}s1" "$M/plan" "$M/plan.err1"; rc1=$?
held_plan "/dev/${G}s2" "$M/plan" "$M/plan.err2"; rc2=$?
unhold
test $rc1 = 1 && test $rc2 = 1 && grep -qx "linuxfs-mount: refused: another mount of $G is under way" "$M/plan.err1" && grep -qx "linuxfs-mount: refused: another mount of $G is under way" "$M/plan.err2"
ok $? "root plan: partitions ${G}s1 and ${G}s2 are refused while the whole disk's mount is under way (rc $rc1 $rc2: $(cat "$M/plan.err1" "$M/plan.err2" | tr '\n' ';'))"
hold 5
fplan "$F2" "/dev/${E}2" "$V/NAME" > "$M/plan" 2> "$M/plan.err3"; rc3=$?
unhold
! grep -q 'under way' "$M/plan.err3" && test -e "$LK/dev.mavergreen.linuxfs.mount.${E}2.lock"
ok $? "root plan: ${E}2 is another disk than $E: its own lock, not refused as under way (rc $rc3: $(tr '\n' ';' < "$M/plan.err3"))"
# spec: tools/fs.c -- test environment overrides are not honoured by the mount role's environment; the shipped build has no test code at all
FP_ENV="LINUXFS_CLI=/bin/false LINUXFS_OPEN=/bin/false LINUXFS_LKLFUSE=/bin/false" fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1
grep -qx "env LINUXFS_OPEN=$H/linuxfs-open" "$M/plan" && grep -qx "env LINUXFS_LKLFUSE=$H/lklfuse" "$M/plan"; ok $? "root plan: a caller's LINUXFS_OPEN and LINUXFS_LKLFUSE are not passed on"
fplan "$MF/5.5.0-mavericks.2.plist" -o nodev -o noowners -o nosuid "/dev/$E" "$V/NAME" > "$M/plan" 2>"$M/plan.err"; rc=$?
fwant rw "allow_other,nosuid,nodev,local,volname=NAME,fsname=/dev/$E,noappledouble,fstypename=ext4,fssubtype=7" "$E" "$V/NAME" > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: mount_macfuse's fixed path, argv, the libfuse handshake's environment, the CLI's channel as fd 6, LINUXFS_FUSE_FD=4, LINUXFS_FUSE_CHAN=6 (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
fplan "$MF/5.5.0-mavericks.2.plist" -o rdonly "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
fwant ro "allow_other,nosuid,nodev,local,volname=NAME,fsname=/dev/$E,noappledouble,fstypename=ext4,fssubtype=7,rdonly" "$E" "$V/NAME" --ro > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: rdonly adds rdonly to mount_macfuse's options and --ro to the CLI's (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
# spec: item 6 ("Ignore ownership") -- with owners the volume shows Linux's ids to every user (allow_other), so the kernel checks
#       them (default_permissions) and a setuid file stays inert (nosuid, as on every root mount: DiskArbitration asks it for
#       an external disk)
fplan "$MF/5.5.0-mavericks.2.plist" -o nodev,noowners,nosuid,owners,rdonly "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
fwant ro "allow_other,nosuid,nodev,default_permissions,local,volname=NAME,fsname=/dev/$E,noappledouble,fstypename=ext4,fssubtype=7,rdonly" "$E" "$V/NAME" --ro --owners > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: owners adds default_permissions to mount_macfuse's options and --owners to the CLI's (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
fplan "$MF/5.5.0-mavericks.2.plist" -o owners,noowners "/dev/$E" "$V/NAME" > "$M/plan" 2>&1
! grep -q 'default_permissions\|^argv --owners$' "$M/plan"; ok $? "root mount plan: a later noowners leaves neither default_permissions nor --owners"
fplan "$MF/5.5.0-mavericks.2.plist" -o update "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
[ $rc = 1 ] && ! grep -q '^fd3\|^helper' "$M/plan"; ok $? "root mount plan: an update is refused before the device is opened (rc $rc: $(tail -1 "$M/plan"))"
mkdir -p "$V/a,b=c"
fplan "$MF/5.5.0-mavericks.2.plist" "/dev/$E" "$V/a,b=c" > "$M/plan" 2>&1
grep -qx "helper-argv allow_other,nosuid,nodev,local,volname=a-b-c,fsname=/dev/$E,noappledouble,fstypename=ext4,fssubtype=7" "$M/plan"; ok $? "root mount plan: the volume name is the mount point's, made safe for an option list ($(grep '^helper-argv a' "$M/plan"))"
# spec: tools/fs.c mount_by_root -- options that do not fit are refused, never cut (a cut one would lose a trailing rdonly)
DM_EXT=$DM; DM=$D/short/mount_macfuse_ext4
fplan "$F2" -o rdonly "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
[ $rc = 1 ] && ! grep -q '^helper' "$M/plan" && grep -q 'the mount options do not fit$' "$M/plan"; ok $? "root mount plan: options that do not fit are refused, not cut (rc $rc: $(tail -1 "$M/plan"))"
DM=$DM_EXT
# spec: tools/fs.c mount_by_root -- the mount's options end with the filesystem's fstypename and fssubtype (tools/fsrules.c's names table)
cp "$DM" "$D/drop/mount_macfuse_ntfs"
DM_EXT=$DM; DM=$D/drop/mount_macfuse_ntfs
fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
fwant rw "allow_other,nosuid,nodev,local,volname=NAME,fsname=/dev/$E,noappledouble,fstypename=ntfs,fssubtype=8" "$E" "$V/NAME" > "$M/want"
[ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: an NTFS mount ends ,fstypename=ntfs,fssubtype=8 (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
DM=$DM_EXT
fplan "$F2" "/dev/$E" "$V/NAME" 2>&1 >/dev/null | grep -q .; [ $? -ne 0 ]; ok $? "root mount plan: a good run writes nothing to stderr"
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
fro() { # DEV WHAT [MACHINE-PREFS]: root's mount of DEV is read-only (rdonly, --ro), the device still opened read-write
  MACHP=${3:-} fplan "$F2" "/dev/$1" "$V/NAME" > "$M/plan" 2>&1; rc=$?
  fwant rw "allow_other,nosuid,nodev,local,volname=NAME,fsname=/dev/$1,noappledouble,fstypename=ext4,fssubtype=7,rdonly" "$1" "$V/NAME" --ro > "$M/want"
  [ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: $2: rdonly to mount_macfuse, --ro to the CLI (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
}
frw() { # DEV WHAT [MACHINE-PREFS]: root's mount of DEV is read-write
  MACHP=${3:-} fplan "$F2" "/dev/$1" "$V/NAME" > "$M/plan" 2>&1; rc=$?
  fwant rw "allow_other,nosuid,nodev,local,volname=NAME,fsname=/dev/$1,noappledouble,fstypename=ext4,fssubtype=7" "$1" "$V/NAME" > "$M/want"
  [ $rc = 0 ] && cmp -s "$M/plan" "$M/want"; ok $? "root mount plan: $2: read-write (rc $rc: $(diff "$M/plan" "$M/want" | head -4 | tr '\n' ';'))"
}
fro "$TD" "a dirty NTFS volume"
frw "$T" "a clean NTFS volume"
fro "$A" "APFS without APFSWrite"
frw "$A" "APFS with APFSWrite" "$D/apfswrite.plist"
! grep -q 'rdonly\|^argv --ro$' "$M/plan"; ok $? "and with APFSWrite set the plan has no rdonly for mount_macfuse and no --ro for the CLI: root is authoritative, the CLI takes ro from it alone"
fro "$E" "the ReadOnly preference" "$D/readonly.plist"
MACHP=$D/apfswrite.plist fplan "$F2" "/dev/$AE" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
[ $rc = 1 ] && ! grep -q '^helper' "$M/plan" && ! grep -q '^argv' "$M/plan" && grep -q '^linuxfs-mount: refused: .*encrypted' "$M/plan.err"
ok $? "root: an encrypted volume before login is refused, nothing run (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
fplan "$MF/5.5.0-mavericks.1.plist" "/dev/$AE" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
[ $rc = 1 ] && ! grep -q '^argv' "$M/plan" && grep -q 'encrypted' "$M/plan.err"; ok $? "and so with an older macFUSE: _linuxfs never runs for it (rc $rc)"
# spec: tools/fs.c mount_as_root -- a macFUSE too old to serve /dev/fd/N cannot mount before login at all: _linuxfs with allow_other is
#       always refused by macFUSE (VM-proven), so root refuses with a fixed reason and runs nothing
fplan "$MF/5.5.0-mavericks.1.plist" "/dev/$TD" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
[ $rc = 1 ] && ! grep -q '^argv\|^helper\|^env' "$M/plan" && grep -qx "linuxfs-mount: refused: macFUSE is too old to mount before login; update macFUSE" "$M/plan.err"
ok $? "with an older macFUSE root refuses, nothing planned: macFUSE is too old to mount before login; update macFUSE (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
# spec: tools/fs.c -- the capability gate: MACFUSE_FD_MOUNTPOINT_SINCE, compared as numbers (5.5.0-mavericks.10 is past .2)
for v in 5.5.0-mavericks.2 5.5.0-mavericks.10 5.6.0-mavericks.1 6.0.0-mavericks.1; do
  fplan "$MF/$v.plist" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1
  grep -q '^helper-argv' "$M/plan" && grep -qx 'env LINUXFS_FUSE_FD=4' "$M/plan"; ok $? "macFUSE $v serves /dev/fd/N: root mounts"
done
for v in 5.5.0-mavericks.1 5.4.9-mavericks.9 garbage 5.5.0 missing; do
  fplan "$MF/$v.plist" "/dev/$E" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
  [ $rc = 1 ] && ! grep -q '^argv\|^helper\|^env' "$M/plan" && grep -qx "linuxfs-mount: refused: macFUSE is too old to mount before login; update macFUSE" "$M/plan.err"
  ok $? "macFUSE manifest $v (older, unreadable or none): refused as too old, nothing run (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
done
fplan "$MF/writable.plist" "/dev/$E" "$V/NAME" > "$M/plan" 2> "$M/plan.err"; rc=$?
[ $rc = 1 ] && ! grep -q '^argv\|^helper' "$M/plan" && grep -q '^linuxfs-mount: refused: ' "$M/plan.err"; ok $? "a group-writable manifest is refused, nothing run (rc $rc: $(tr '\n' ';' < "$M/plan.err"))"
# spec: tools/fs.c -- the handshake, with a stand-in mount helper (tests/lib/mount-helper-stub.c) and a stand-in CLI
#       (tests/lib/cli-stub.c): the CLI says "ready" on fd 6 first, root then runs the helper, and the device goes to the CLI over
#       that channel; the CLI answers INIT by writing to it (fd 4); root waits for the helper's status, bounded
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld -o "$D/drop/mhelper" "$ROOT/tests/lib/mount-helper-stub.c" || exit 1
"$CL/bin/clang" --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -Werror -fuse-ld=lld -o "$M/fdcli" "$ROOT/tests/lib/cli-stub.c" || exit 1
hs() { # HELPER-MODE CLI-MODE [WAIT]: root's mount with both stand-ins; status in rc, output in $M/plan; HS_ENV adds to its environment, HS_WRAP runs it
  rm -f "$D/drop/mhelper.log" "$M/fdcli.log"
  if [ -n "$1" ]; then echo "$1" > "$D/drop/mhelper.mode"; else rm -f "$D/drop/mhelper.mode"; fi
  echo "$2" > "$M/fdcli.mode"
  env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_LOCKDIR="$LK" \
    LINUXFS_FS_TEST_MOUNT_HELPER="${HS_HELPER:-$D/drop/mhelper}" LINUXFS_FS_TEST_ROOT_CLI="$M/fdcli" LINUXFS_FS_TEST_TRUST_ROOT="$D" \
    LINUXFS_FS_TEST_MACFUSE="${HS_MANIFEST:-$MF/5.5.0-mavericks.2.plist}" ${3:+LINUXFS_FS_TEST_WAIT=$3} ${HS_ENV:-} \
    ${HS_WRAP:-} "$DM" "/dev/$E" "$V/NAME" 7</dev/null > "$M/plan" 2>&1; rc=$?; }
gone() { [ -z "$1" ] || ! ps -p "$1" > /dev/null; }
hs "" ok; t0=$rc
[ $t0 = 0 ] && grep -q '^status 0$' "$D/drop/mhelper.log" && grep -q '^cli-rc 0' "$M/plan"; ok $? "root: the helper's device reaches the CLI, the CLI answers INIT, status 0: exit 0 (rc $t0: $(tail -n 4 "$M/plan" | tr '\n' ';'))"
fdl=$(sed -n 's/^fds: //p' "$M/fdcli.log" | sed 's/ *255//')
[ "$fdl" = "3 6:sock" ]; ok $? "the CLI holds the disk on 3 and its channel on 6, nothing else ('$fdl')"
grep -q '^device on 4$' "$M/fdcli.log"; ok $? "the device reaches the CLI over the channel, as fd 4"
grep -qx LINUXFS_FUSE_FD=4 "$M/fdcli.log" && grep -qx LINUXFS_FUSE_CHAN=6 "$M/fdcli.log"; ok $? "the CLI's environment names the device and the channel: LINUXFS_FUSE_FD=4, LINUXFS_FUSE_CHAN=6"
hfd=$(sed -n 's/^env _FUSE_COMMFD=//p' "$D/drop/mhelper.log")
[ "$(grep '^env ' "$D/drop/mhelper.log" | sort | tr '\n' ' ')" = "$(printf 'env _FUSE_CALL_BY_LIB=1\nenv _FUSE_COMMFD=%s\nenv _FUSE_COMMVERS=2\nenv _FUSE_DAEMON_PATH=%s/lklfuse\n' "$hfd" "$H" | sort | tr '\n' ' ')" ]
ok $? "the helper's environment is the handshake's four variables and nothing else ($(grep '^env ' "$D/drop/mhelper.log" | tr '\n' ' '))"
lfd=$(awk -v p="$LKF" '$1 == "fdpath" && $3 == p { print $2 }' "$D/drop/mhelper.log")
test "$(sed -n 's/^fds //p' "$D/drop/mhelper.log" | tr ' ' '\n' | grep -vx "$lfd" | sort -n | tr '\n' ' ')" = "$(printf '0\n1\n2\n%s\n' "$hfd" | sort -n | tr '\n' ' ')"
ok $? "the helper holds 0-2, its socket and the disk's lock only, never the disk ($(sed -n 's/^fds //p' "$D/drop/mhelper.log"); lock on '$lfd')"
# spec: Task 16f (design N4) -- the lock is not close-on-exec: mount_macfuse inherits it through the loop that closes the rest, and the CLI
#       closes it before it becomes _linuxfs, so nothing of _linuxfs's ever holds a disk root believes free
test -n "$lfd" && ! grep -q "^fdpath .*dev\.mavergreen\.linuxfs\.mount\." "$M/fdcli.log" && grep -q "^fdpath 3 /dev/r$E\$" "$M/fdcli.log"
ok $? "root plan (helper stand-in): the CLI does not hold the lock, mount_macfuse does (helper's lock fd '$lfd'; CLI's $(grep '^fdpath' "$M/fdcli.log" | tr '\n' ' '))"
[ "$(grep '^argv ' "$D/drop/mhelper.log" | tr '\n' '|')" = "argv -o|argv allow_other,nosuid,nodev,local,volname=NAME,fsname=/dev/$E,noappledouble,fstypename=ext4,fssubtype=7|argv $V/NAME|" ]; ok $? "the helper's argv is -o OPTIONS MNT"
# spec: tools/fs.c mount_by_root -- every other descriptor is closed: descriptors the mount program inherited (3, 4, 5, 9) are gone
#       in the CLI and in the helper, and with stdin closed the device still lands on fd 3 and nothing on 0-2
hs "" ok 4</dev/null 5</dev/null 9</dev/null 3</dev/null; fdl=$(sed -n 's/^fds: //p' "$M/fdcli.log" | sed 's/ *255//')
lfd=$(awk -v p="$LKF" '$1 == "fdpath" && $3 == p { print $2 }' "$D/drop/mhelper.log")
hfds=$(sed -n 's/^fds //p' "$D/drop/mhelper.log" | tr ' ' '\n' | grep -vx "$lfd" | sort -n | tr '\n' ' ')
[ $rc = 0 ] && [ "$fdl" = "3 6:sock" ] && test -n "$lfd" && test "$hfds" = "$(printf '0\n1\n2\n%s\n' "$(sed -n 's/^env _FUSE_COMMFD=//p' "$D/drop/mhelper.log")" | sort -n | tr '\n' ' ')"
ok $? "inherited descriptors 3, 4, 5, 9 are gone: the CLI holds the disk on 3 and its channel on 6 only, the helper its socket and the disk's lock only (rc $rc, CLI fds '$fdl', helper's '$hfds' and lock '$lfd')"
hs "" ok <&-; fdl=$(sed -n 's/^fds: //p' "$M/fdcli.log" | sed 's/ *255//')
[ $rc = 0 ] && [ "$fdl" = "3 6:sock" ]; ok $? "with stdin closed the device still lands on fd 3 and nothing else is open (rc $rc, fds '$fdl')"
hs "status 5" ok
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc != 0 ] && gone "$hp"; ok $? "a helper status of 5 fails the mount (rc $rc) and the helper is gone"
s0=$(date +%s); hs "" "exit 3"; t=$(( $(date +%s) - s0 ))
[ $rc = 3 ] && [ ! -e "$D/drop/mhelper.log" ] && [ $t -lt 8 ]; ok $? "a CLI that refuses (exit 3) before it is ready: mount_macfuse is never run, root exits 3 in $t s (rc $rc)"
# spec: tools/fs.c mount_by_root -- a CLI that is neither ready nor ended within the bounded wait: root gives up, runs no
#       mount_macfuse, and stops the CLI
s0=$(date +%s); hs "" noready 2; t=$(( $(date +%s) - s0 ))
cp1=$(sed -n 's/^pid //p' "$M/fdcli.log")
[ $rc = 1 ] && [ ! -e "$D/drop/mhelper.log" ] && [ $t -lt 8 ] && gone "$cp1"; ok $? "a CLI that is never ready: root gives up in $t s, runs no mount_macfuse, the CLI is stopped (rc $rc)"
# spec: tools/fs.c wait_ready -- "ready" is exactly one byte, R: another byte, or R with more, is a CLI gone wrong, and the mount
#       fails at once with no mount_macfuse run (the log says garbled, not timed out)
for g in garble rr; do
  s0=$(date +%s); hs "" $g 20; t=$(( $(date +%s) - s0 ))
  [ $rc = 1 ] && [ ! -e "$D/drop/mhelper.log" ] && [ $t -lt 8 ]; ok $? "a CLI that sends '$g' instead of \"ready\": no mount_macfuse, root exits 1 in $t s, not at the 20 s bound (rc $rc)"
done
# spec: tools/fs.c recv_device -- root also watches the CLI's channel: a CLI that dies after "ready" has mount_macfuse stopped at
#       once, not after the wait for a device (nofd: the helper never sends one; the bound here is 20 s)
s0=$(date +%s); hs nofd "diesAfterR 3" 20; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 3 ] && [ $t -lt 10 ] && gone "$hp"; ok $? "a CLI that dies right after \"ready\": root stops mount_macfuse and exits 3 in $t s, not at the bound (rc $rc)"
# spec: tools/fs.c recv_device -- a healthy, slow mount is not aborted: the CLI's shell closes its own copy of the channel after "ready",
#       another process of the CLI (the opener's role) keeps it open, and mount_macfuse sends the device 4 s late
hs delay forkchan 20
[ $rc = 0 ] && grep -q '^device on 4$' "$M/fdcli.log" && grep -q '^status 0$' "$D/drop/mhelper.log"; ok $? "a slow device (4 s) while another CLI process holds the channel: the mount is not aborted (rc $rc)"
s0=$(date +%s); hs nofd ok 2; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 1 ] && [ $t -lt 8 ] && gone "$hp"; ok $? "a helper that sends no device: exit 1 after the bounded wait ($t s), the helper is killed (rc $rc)"
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
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log"); heir=$(sed -n 's/^heir //p' "$D/drop/mhelper.log")
[ $rc = 0 ] && [ -n "$hp" ] && gone "$hp" && [ $t -ge 2 ] && [ $t -lt 6 ]; ok $? "a mount_macfuse that lingers after a good mount is stopped and reaped: no root helper left (rc $rc, $t s)"
# spec: Task 16f (design I4) -- the lock lives as long as anything of root's for the mount does: mount_macfuse's own child (the heir,
#       7 s) outlives the program by about 5 s, and until it ends a second request for the disk is refused; then it is accepted
s0=$(date +%s); hs "" ok; t=$(( $(date +%s) - s0 ))
test -n "$heir" && ps -p "$heir" > /dev/null && test $rc = 1 && grep -qx "linuxfs-mount: refused: another mount of $E is under way" "$M/plan" && test ! -e "$M/fdcli.log"
ok $? "root plan (helper stand-in): mount_macfuse holds the lock: while its heir lives a second request is refused (rc $rc, $t s, heir '$heir')"
i=0; while test -n "$heir" && ps -p "$heir" > /dev/null && test $i -lt 100; do sleep 0.1; i=$((i + 1)); done
hs "" ok
test $rc = 0 && grep -q '^status 0$' "$D/drop/mhelper.log"; ok $? "and once it has ended, the next request is accepted (rc $rc: $(tail -n 2 "$M/plan" | tr '\n' ';'))"
s0=$(date +%s); hs stubborn ok; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 0 ] && [ -n "$hp" ] && gone "$hp" && [ $t -ge 3 ] && [ $t -lt 7 ]; ok $? "one that ignores SIGTERM is killed a second later (rc $rc, $t s)"
# spec: tools/fs.c mount_by_root -- lklfuse dying at startup (the CLI ends after the device went to it) while mount_macfuse keeps the device (blocked in
#       mount(2) on INIT, as the real one may be): root still ends, bounded, and stops it; one that outlives even SIGKILL
#       (LINUXFS_FS_TEST_NOKILL makes root's SIGKILL a no-op) is reported, on stderr and syslog, not left silently
s0=$(date +%s); hs hold "afterready 3"; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 3 ] && [ $t -lt 15 ] && [ -n "$hp" ] && gone "$hp"; ok $? "mount_macfuse holding the device with no status, the CLI failed: root exits 3 in $t s and mount_macfuse is gone (rc $rc)"
s0=$(date +%s); HS_ENV=LINUXFS_FS_TEST_NOKILL=1; hs holdstubborn "afterready 3"; unset HS_ENV; t=$(( $(date +%s) - s0 ))
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 3 ] && [ $t -lt 20 ] && [ -n "$hp" ] && grep -q "mount_macfuse (pid $hp) is still running after SIGKILL" "$M/plan"
ok $? "one that outlives SIGKILL: root still exits 3 in $t s, and says it is left running ($(grep -i 'still running' "$M/plan" | tr '\n' ' '))"
[ -z "$hp" ] || kill -9 "$hp" 2>/dev/null
i=0; while ! gone "$hp" && test $i -lt 50; do sleep 0.1; i=$((i + 1)); done
HS_ENV=LINUXFS_FS_TEST_NOKILL=1; hs stubborn ok; unset HS_ENV
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log")
[ $rc = 0 ] && [ -n "$hp" ] && grep -q "mount_macfuse (pid $hp) is still running after SIGKILL" "$M/plan"; ok $? "after a good mount too, a mount_macfuse that outlives SIGKILL is reported (rc $rc)"
[ -z "$hp" ] || kill -9 "$hp" 2>/dev/null
i=0; while ! gone "$hp" && test $i -lt 50; do sleep 0.1; i=$((i + 1)); done
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
# spec: tools/fs.c path_trusted -- root executes mount_macfuse, and reads macFUSE's manifest, only through a path whose every part
#       (the file, each directory above it) is root's and not writable by a group other than 0 or by anyone else: a user who can
#       write /usr/local could otherwise rename /usr/local/mavergreen and plant a mount_macfuse. The path is resolved first and
#       the resolved path is what runs. (The tests' stand-in for root is the user running them, and TRUST_ROOT names the
#       directory above which nothing is checked.)
TR=$D/tr; rm -rf "$TR"; mkdir -p "$TR/ok" "$TR/world" "$TR/group" "$TR/isdir" "$TR/sticky" "$TR/sticky2" "$TR/nosticky"
chmod 755 "$TR" "$TR/ok" "$TR/isdir"; chmod 777 "$TR/world"; chmod 775 "$TR/group" "$TR/nosticky"; chmod 1775 "$TR/sticky"; chmod 1777 "$TR/sticky2"
for d in ok world group sticky sticky2 nosticky; do cp "$D/drop/mhelper" "$TR/$d/mhelper"; cp "$MF/5.5.0-mavericks.2.plist" "$TR/$d/manifest.plist"; : > "$TR/$d/libfuse.dylib"; chmod 755 "$TR/$d/mhelper"; done
cp "$D/drop/mhelper" "$TR/ok/mhelper-o"; chmod 757 "$TR/ok/mhelper-o"
cp "$D/drop/mhelper" "$TR/ok/mhelper-g"; chmod 775 "$TR/ok/mhelper-g"
ln -s "$TR/ok/mhelper" "$TR/world/link"; ln -s "$TR/ok/libfuse.dylib" "$TR/world/libfuse-link.dylib"; ln -s "$TR/ok/libfuse.dylib" "$TR/ok/libfuse-link.dylib"; ln -s "$TR/ok/manifest.plist" "$TR/world/manifest-link.plist"; ln -s "$TR/ok/manifest.plist" "$TR/ok/manifest-link.plist"; ln -s "$TR/ok" "$TR/world/okdir"; ln -s "$TR/world/link" "$TR/ok/hop2"; ln -s "$TR/world/mhelper" "$TR/ok/badlink"
trust() { # WHAT HELPER MANIFEST LIBFUSE: root's mount with those (empty: the defaults), no stale logs; sets rc
  rm -f "$TR"/*/mhelper*.log "$D/drop/mhelper.log"
  HS_HELPER=${2:-}; HS_MANIFEST=${3:-}; HS_ENV=${4:+LINUXFS_FS_TEST_LIBFUSE=$4}
  hs "" ok
  HS_HELPER=; HS_MANIFEST=; HS_ENV=
}
refused() { # WHAT: the mount was refused with the fixed reason, and neither mount_macfuse nor the CLI ran
  [ $rc = 1 ] && grep -qx "linuxfs-mount: refused: macFUSE's install path is writable by a user" "$M/plan" && [ ! -e "$M/fdcli.log" ] &&
    ! ls "$TR"/*/mhelper*.log "$D/drop/mhelper.log" > /dev/null 2>&1; ok $? "root: $1: refused with a fixed reason; mount_macfuse and the CLI never run (rc $rc: $(tail -n 2 "$M/plan" | tr '\n' ';'))"
}
cp "$MF/5.5.0-mavericks.2.plist" "$TR/ok/manifest.plist"
trust x "$TR/ok/mhelper"
[ $rc = 0 ] && grep -q '^status 0$' "$TR/ok/mhelper.log"; ok $? "root: a helper in directories that are root's and not writable by others is run (rc $rc)"
trust x "$TR/world/mhelper"; refused "a helper in a directory anyone can write"
trust x "$TR/group/mhelper"; refused "a helper in a directory writable by a group that is not wheel"
trust x "$TR/ok/mhelper-o"; refused "a helper file writable by others"
trust x "$TR/ok/mhelper-g"; refused "a helper file writable by a group that is not wheel"
trust x "$TR/ok/badlink"; refused "a symlink to a helper in a writable directory (the resolved path is checked)"
# spec: tools/fs.c path_trusted -- dyld and the shell follow the literal path, so the directories holding each symlink hop count too:
#       a user-writable directory holding the symlink is refused even when the target is trusted
trust x "$TR/world/link"; refused "a symlink in a directory anyone can write, to a trusted helper"
trust x "$TR/ok/hop2"; refused "a symlink to a symlink in a writable directory, to a trusted helper"
trust x "$TR/world/okdir/mhelper"; refused "a path through a symlink to a directory, held in a writable directory"
# spec: tools/fs.c path_trusted -- a root-owned sticky directory is root-only even when group- or world-writable (nobody else can rename or
#       remove root's entries; stock 10.9 may ship / as 1775 root:admin); without the sticky bit it is not
trust x "$TR/sticky/mhelper"
[ $rc = 0 ] && grep -q '^status 0$' "$TR/sticky/mhelper.log"; ok $? "root: a helper in a sticky group-writable (1775) directory is run (rc $rc)"
trust x "$TR/sticky2/mhelper"
[ $rc = 0 ] && grep -q '^status 0$' "$TR/sticky2/mhelper.log"; ok $? "root: and in a sticky world-writable (1777) one (rc $rc)"
trust x "$TR/nosticky/mhelper"; refused "the same 1775 directory without the sticky bit"
trust x "$TR/isdir"; [ $rc = 1 ] && [ ! -e "$M/fdcli.log" ]; ok $? "root: a helper that is not a regular file is refused (rc $rc)"
trust x "$TR/ok/missing"; [ $rc = 1 ] && [ ! -e "$M/fdcli.log" ]; ok $? "root: a missing helper is refused (rc $rc)"
trust x "" "$TR/world/manifest.plist"; refused "a manifest in a directory anyone can write"
trust x "" "$TR/group/manifest.plist"; refused "a manifest in a group-writable directory"
trust x "" "$TR/ok/manifest.plist"; [ $rc = 0 ]; ok $? "root: a manifest in a trusted directory is read (rc $rc)"
trust x "" "$TR/world/manifest-link.plist"; refused "a manifest symlink in a directory anyone can write"
trust x "" "$TR/ok/manifest-link.plist"; [ $rc = 0 ]; ok $? "root: a manifest symlink in a trusted directory is loaded from its resolved path (rc $rc)"
# spec: tools/fs.c -- lklfuse, as _linuxfs, loads /usr/local/lib/libfuse3.4.dylib: the same walk, run before the CLI starts
trust x "" "" "$TR/world/libfuse.dylib"; refused "libfuse in a directory anyone can write"
trust x "" "" "$TR/world/libfuse-link.dylib"; refused "a libfuse symlink in a directory anyone can write, to a trusted file"
trust x "" "" "$TR/ok/libfuse-link.dylib"; [ $rc = 0 ]; ok $? "root: a libfuse symlink in a trusted directory to a trusted file: the mount goes ahead (rc $rc)"
trust x "" "" "$TR/ok/libfuse.dylib"; [ $rc = 0 ]; ok $? "root: libfuse in a trusted directory: the mount goes ahead (rc $rc)"
trust x "" "" "$TR/ok/nolibfuse.dylib"; [ $rc = 1 ] && [ ! -e "$M/fdcli.log" ]; ok $? "root: no libfuse: refused, the CLI never runs (rc $rc)"
# spec: tools/fs.c mount_by_root -- the force-unmount on failure takes only root's own mount (fsrules_mount_is_roots: the bundle's
#       macfuse_<fs>, from /dev/DISK, owned by root); another volume on MNT, here an HFS+ one, is left, even from a disk (the rule's
#       cases are fsrules-test's). (The matching case needs a real macFUSE mount: the VM smoke's.)
rm -f "$D/foreign.dmg"; hdiutil create -quiet -size 4m -fs HFS+ -volname foreign "$D/foreign.dmg" && cp "$D/foreign.dmg" "$D/drop/mhelper.img"
hs foreign ok
fm=$(mount | grep -F " on $V/NAME (")
[ $rc != 0 ] && grep -q '^attached 0$' "$D/drop/mhelper.log" && [ -n "$fm" ]; ok $? "a volume on MNT that is not root's mount is never force-unmounted (rc $rc, '$fm')"
fd9=$(hdiutil info | awk -v p="$D/drop/mhelper.img" '/^image-path/ { sub(/^image-path[ \t]*:[ \t]*/, ""); cur = ($0 == p) } cur && /^\/dev\/disk[0-9]+[ \t]/ { print $1; exit }')
[ -z "$fd9" ] || hdiutil detach -quiet -force "$fd9" 2>/dev/null
# spec: Task 16f (root-daemon design §3) -- f_owner 0 no longer tells one root mount from another; the lock and the pre-check do: a
#       failed request only ever unmounts its own. Root's live mount of $E on MNT refuses a second request before the CLI runs, and
#       its failure path (here forced: the helper's status 5) never reaches unmount(2) (the drop build says "unmount-attempt MNT")
printf 'macfuse_ext4\t/dev/%s\t%s\t0\n' "$E" "$V/NAME" > "$M/mnttab"
HS_ENV="LINUXFS_FS_TEST_MNTTAB=$M/mnttab"; hs "status 5" ok; unset HS_ENV
test $rc = 1 && test ! -e "$M/fdcli.log" && test ! -e "$D/drop/mhelper.log" && ! grep -q '^unmount-attempt' "$M/plan" && grep -q '^linuxfs-mount: refused: something is mounted' "$M/plan"
ok $? "root plan (helper stand-in): a live root mount of $E is never unmounted by a second request (rc $rc: $(tr '\n' ';' < "$M/plan" | cut -c1-200))"
rm -f "$D/drop/mhelper.mnttab"; : > "$D/drop/mhelper.mnttab"
HS_ENV="LINUXFS_FS_TEST_MNTTAB=$D/drop/mhelper.mnttab"; hs "mounted 5" ok; unset HS_ENV
test $rc != 0 && grep -qx "unmount-attempt $V/NAME" "$M/plan"; ok $? "and a request whose own mount landed before it failed unmounts that mount (rc $rc: $(grep '^unmount' "$M/plan"))"
# spec: Task 16j (root-daemon design §1, I5, R2, M2; revision 4) -- the console user's mount program asks root's daemon first, at
#       LINUXFS_MOUNTD_SOCK: tests/lib/mountd-stub.pl stands in for it, and LINUXFS_MOUNTD_PEER_UID names its uid in place of root's.
#       It falls back to its own path only while nothing was touched: no daemon, no hi, user, or silence or EOF before begin
MS=$M/mountd.sock; ML=$M/mountd.log
md() { # STEP...: the stand-in daemon in the background ($mdpid), logging to $ML; waits, bounded, until it listens
  rm -f "$MS" "$MS.ready" "$ML"
  /usr/bin/perl "$ROOT/tests/lib/mountd-stub.pl" "$MS" "$ML" "$@" & mdpid=$!
  i=0; while test ! -e "$MS.ready" && test $i -lt 50; do sleep 0.1; i=$((i + 1)); done; }
mdstop() { kill "$mdpid" 2>/dev/null; wait "$mdpid" 2>/dev/null; mdpid=; }
ask() { # ARGS...: the mount role as the console user, asking the stand-in (ASK_ROOT=1: root required, no stand-in uid; ASK_ENV adds
        # to its environment; ASK_SOCK names another socket path); rc, stderr in $M/ask.err, seconds taken in $t
  if test -n "${ASK_ROOT:-}"; then pu="-u LINUXFS_MOUNTD_PEER_UID"; else pu="LINUXFS_MOUNTD_PEER_UID=$(id -u)"; fi
  s0=$(date +%s)
  mt env $pu LINUXFS_MOUNTD_SOCK="${ASK_SOCK:-$MS}" LINUXFS_MNTTAB="$M/ask9.mnttab" ${ASK_ENV:-} "$MD" "$@" > /dev/null 2> "$M/ask.err"; rc=$?
  t=$(( $(date +%s) - s0 )); }
printf 'macfuse_ext4\t/dev/disk9\t/tmp/m\t%s\n' "$(id -u)" > "$M/ask9.mnttab"	# the stand-in CLI's own mount, for the user path's gate
cliran() { grep -q '^args: ' "$M/log" 2>/dev/null; }
askerr() { tr '\n' ';' < "$M/ask.err" | cut -c1-240; }
md sleep:1 peek say:hi read 'say:user\tnot yet'
ask -o nodev -o noowners "/dev/$E" "$V/NAME"; mdstop
grep -qx 'early 0' "$ML" && grep -qxF "got: mount\\text4\\t$E\\t-\\t$V/NAME" "$ML"
ok $? "ask: the line is exactly mount<TAB>ext4<TAB>$E<TAB>-<TAB>$V/NAME, sent after hi ($(tr '\n' ';' < "$ML"))"
md say:hi read 'say:user\tnot yet'
ask -o rdonly -o owners /dev/disk9 /tmp/m; mdstop
grep -qxF 'got: mount\text4\tdisk9\tro,owners\t/tmp/m' "$ML"; ok $? "ask: -o rdonly -o owners gives FLAGS ro,owners ($(tr '\n' ';' < "$ML"))"
md say:hi read 'say:user\tnot yet'
ask -o owners /dev/disk9 /tmp/m; mdstop
grep -qxF 'got: mount\text4\tdisk9\towners\t/tmp/m' "$ML"; ok $? "ask: -o owners alone gives FLAGS owners ($(tr '\n' ';' < "$ML"))"
md say:hi read say:begin 'say:no\t3\tnot for the ext4 bundle'
ask /dev/disk9 /tmp/m; mdstop
test $rc = 3 && ! cliran; ok $? "ask: hi, begin, no 3 → exit 3, and the CLI never runs (rc $rc: $(askerr))"
md say:hi read 'say:no\t3\tnot for the ext4 bundle'
ask /dev/disk9 /tmp/m; mdstop
test $rc = 3 && ! cliran; ok $? "ask: hi, no 3 (before begin) → exit 3, and the CLI never runs (rc $rc: $(askerr))"
md say:hi read say:begin 'say:no\t0\tzero'
ask /dev/disk9 /tmp/m; mdstop
test $rc = 1 && ! cliran; ok $? "ask: no 0 → exit 1 (rc $rc: $(askerr))"
md say:hi read say:begin 'say:no\t300\tbig'
ask /dev/disk9 /tmp/m; mdstop
test $rc = 1 && ! cliran; ok $? "ask: no 300 → exit 1 (rc $rc: $(askerr))"
md say:hi read say:begin say:ok
ask "/dev/$E" "$V/NAME"; mdstop
test $rc = 1 && ! cliran && grep -q 'not on' "$M/ask.err"; ok $? "ask: hi, begin, ok with nothing in the mount table → exit 1, and the CLI never runs (rc $rc: $(askerr))"
printf 'macfuse_ext4\t/dev/%s\t%s\t0\n' "$E" "$V/NAME" > "$M/ask.mnttab"
md say:hi read say:begin say:ok
ASK_ENV="LINUXFS_MNTTAB=$M/ask.mnttab"; ask "/dev/$E" "$V/NAME"; unset ASK_ENV; mdstop
test $rc = 0 && ! cliran; ok $? "ask: hi, begin, ok with root's mount on MNT in the mount table → exit 0, and the CLI never runs (rc $rc: $(askerr))"
printf 'macfuse_ext4\t/dev/%s\t%s\t%s\n' "$E" "$V/NAME" "$(id -u)" > "$M/ask.mnttab"
md say:hi read say:begin say:ok
ASK_ENV="LINUXFS_MNTTAB=$M/ask.mnttab"; ask "/dev/$E" "$V/NAME"; unset ASK_ENV; mdstop
test $rc = 1 && ! cliran; ok $? "ask: hi, begin, ok with the user's own mount on MNT, not root's → exit 1 (rc $rc: $(askerr))"
md say:hi read 'say:user\tnot your disk: your own mount'
ask /dev/disk9 /tmp/m; mdstop
test $rc = 0 && cliran && grep -q 'your own' "$M/ask.err"; ok $? "ask: user → the CLI runs (rc $rc: $(askerr))"
md 'say:user\tnot the user at the console'
ask /dev/disk9 /tmp/m; mdstop
test $rc = 0 && cliran && ! grep -q '^got' "$ML"; ok $? "ask: user before hi (not the console's user) → the CLI runs, and no request was sent (rc $rc: $(askerr))"
md say:hi read 'say:user\tbusy'
ask /dev/disk9 /tmp/m; mdstop
test $rc = 0 && cliran; ok $? "ask: user<TAB>busy after hi → the CLI runs (rc $rc: $(askerr))"
rm -f "$MS"
ask /dev/disk9 /tmp/m
test $rc = 0 && cliran; ok $? "ask: no socket → the CLI runs (rc $rc: $(askerr))"
# spec: Task 16j (revision 4, the controller's ruling) -- /var/run is root:daemon 0775, so the socket could be replaced: the client
#       requires its peer to be uid 0 (getpeereid) before it sends or reads anything, and any other listener is no daemon
md say:hi drain	# a hi first, so a client that skipped the check would send its request
ASK_ROOT=1; ask /dev/disk9 /tmp/m; unset ASK_ROOT; mdstop
grep -qx connected "$ML" && grep -qx 'drained 0' "$ML" && test $rc = 0 && cliran && grep -q "held by uid $(id -u), not root" "$M/ask.err"
ok $? "ask: a non-root listener at the socket path gets nothing and the CLI runs (rc $rc: $(tr '\n' ';' < "$ML"); $(askerr))"
md full
ask /dev/disk9 /tmp/m; mdstop
grep -q '^full after [1-9]' "$ML" && ! grep -qx connected "$ML" && test $rc = 0 && cliran
ok $? "ask: a socket nobody accepts on (ECONNREFUSED, a full backlog) → the CLI runs (rc $rc: $(tr '\n' ';' < "$ML"); $(askerr))"
md stale
ask /dev/disk9 /tmp/m; mdstop
test -S "$MS" && test $rc = 0 && cliran && grep -q 'Connection refused' "$M/ask.err"
ok $? "ask: a stale socket file (nothing listening) → the CLI runs (rc $rc: $(askerr))"
# spec: task-16j-findings-r0.md m4 -- connect follows a symlink, so one at the socket path could lead to another root socket: the path
#       itself must be a socket of root's (best effort: lstat before connect)
md say:hi read 'say:no\t3\tnot this service'
rm -f "$M/link.sock"; ln -s "$MS" "$M/link.sock"
ASK_SOCK=$M/link.sock; ask /dev/disk9 /tmp/m; unset ASK_SOCK; mdstop
! grep -qx connected "$ML" && test $rc = 0 && cliran && grep -q 'not a socket' "$M/ask.err"
ok $? "ask: a symlink at the socket path (to a socket of the right uid) is not followed: the CLI runs (rc $rc: $(tr '\n' ';' < "$ML"); $(askerr))"
# spec: task-16j-findings-r0.md m1 -- ok before begin claims a mount: never the user's own path over it
md say:hi read say:ok
ask /dev/disk9 /tmp/m; mdstop
test $rc = 1 && ! cliran; ok $? "ask: hi, then ok without begin → exit 1, and the CLI never runs (rc $rc: $(askerr))"
md close
ask /dev/disk9 /tmp/m; mdstop
grep -qx connected "$ML" && test $rc = 0 && cliran; ok $? "ask: accepted and closed at once → the CLI runs (rc $rc: $(askerr))"
md sleep:6
ask /dev/disk9 /tmp/m; mdstop
grep -qx connected "$ML" && test $rc = 0 && cliran && test $t -ge 5 && test $t -le 7; ok $? "ask: accepted, nothing written for 6 s → the CLI runs, after the 5 s hi wait, within 7 s ($t s, rc $rc: $(askerr))"
md say:hi read close
ask /dev/disk9 /tmp/m; mdstop
grep -q '^got: mount' "$ML" && test $rc = 0 && cliran; ok $? "ask: hi then EOF before begin → the CLI runs (rc $rc: $(askerr))"
md say:hi read say:begin sleep:10
ASK_ENV=LINUXFS_MOUNTD_WAIT=2; ask /dev/disk9 /tmp/m; unset ASK_ENV; mdstop
test $rc = 1 && ! cliran && test $t -le 4; ok $? "ask: hi, begin, then silence (LINUXFS_MOUNTD_WAIT=2) → exit 1 within 4 s, and the CLI never runs ($t s, rc $rc: $(askerr))"
md say:hi read sleep:10
ASK_ENV=LINUXFS_MOUNTD_PREBEGIN_WAIT=2; ask /dev/disk9 /tmp/m; unset ASK_ENV; mdstop
test $rc = 0 && cliran && test $t -le 4 && grep -q 'said nothing before begin' "$M/ask.err"
ok $? "ask: hi, then nothing (LINUXFS_MOUNTD_PREBEGIN_WAIT=2) → the CLI runs, within 4 s ($t s, rc $rc: $(askerr))"
md say:hi read say:begin close
ask /dev/disk9 /tmp/m; mdstop
test $rc = 1 && ! cliran; ok $? "ask: hi, begin, then EOF → exit 1, and the CLI never runs (rc $rc: $(askerr))"
md say:hi read say:begin say:hello
ask /dev/disk9 /tmp/m; mdstop
test $rc = 1 && ! cliran; ok $? "ask: hi, begin, then garbage → exit 1, and the CLI never runs (rc $rc: $(askerr))"
md say:hello
ask /dev/disk9 /tmp/m; mdstop
grep -qx connected "$ML" && test $rc = 0 && cliran && ! grep -q '^got' "$ML"; ok $? "ask: a garbled first line (hello) → the CLI runs (rc $rc: $(askerr))"
md drain
FP_ENV="LINUXFS_MOUNTD_SOCK=$MS LINUXFS_MOUNTD_PEER_UID=$(id -u)" fplan "$F2" "/dev/$E" "$V/NAME" > "$M/plan" 2>&1; rc=$?
mdstop
test $rc = 0 && ! grep -qx connected "$ML"; ok $? "ask: the root plan (drop build) never connects (rc $rc: $(cat "$ML" 2>/dev/null | tr '\n' ';'))"
# spec: Task 16j (root-daemon design I4, N3, N5) -- the daemon's deadline is SIGTERM: root's path then stops the CLI's group, unmounts
#       its own mount (mounted_on = 1) and stops mount_macfuse, bounded, and exits 1. The handler only sets a flag, without SA_RESTART,
#       so every wait sees EINTR or the flag
grp_gone() { # PGID: no live process is left in that group (bounded, 3 s)
  test -n "$1" || return 1
  i=0; while ps -axo pgid=,stat= | awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }' && test $i -lt 30; do sleep 0.1; i=$((i + 1)); done
  test $i -lt 30 || return 1
  test "$1" != "$lastcg" || lastcg=; }	# gone: never killed again by number at exit (findings-r1 n1)
hst() { # HELPER-MODE CLI-MODE FILE PATTERN: root's mount with both stand-ins, in the background; once FILE has a line matching
        # PATTERN (bounded, 10 s), SIGTERM; rc, the seconds from the signal to its end in $t, output in $M/plan; HS_ENV adds to its environment
  rm -f "$D/drop/mhelper.log" "$M/fdcli.log"
  i=0; while ! lockfree && test $i -lt 100; do sleep 0.1; i=$((i + 1)); done	# an earlier case's heir may still hold the disk's lock
  if test -n "$1"; then echo "$1" > "$D/drop/mhelper.mode"; else rm -f "$D/drop/mhelper.mode"; fi
  echo "$2" > "$M/fdcli.mode"
  env -i LINUXFS_FS_TEST_USER=daemon LINUXFS_FS_TEST_VOLUMES="$V" LINUXFS_FS_TEST_LOCKDIR="$LK" \
    LINUXFS_FS_TEST_MOUNT_HELPER="$D/drop/mhelper" LINUXFS_FS_TEST_ROOT_CLI="$M/fdcli" LINUXFS_FS_TEST_TRUST_ROOT="$D" \
    LINUXFS_FS_TEST_MACFUSE="$MF/5.5.0-mavericks.2.plist" LINUXFS_FS_TEST_WAIT=20 ${HS_ENV:-} \
    "$DM" "/dev/$E" "$V/NAME" 7</dev/null > "$M/plan" 2>&1 & tp=$!
  i=0; while ! grep -q "$4" "$3" 2>/dev/null && test $i -lt 100; do sleep 0.1; i=$((i + 1)); done
  sleep 0.5	# into the wait
  s0=$(date +%s); kill -TERM "$tp"
  ( sleep 20; kill -9 "$tp" 2>/dev/null ) & wd=$!
  wait "$tp"; rc=$?; t=$(( $(date +%s) - s0 )); tp=
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null; wd=; lastcg=$(sed -n 's/^cli-pgid //p' "$M/plan" | head -n 1); }
pgid_of() { sed -n 's/^cli-pgid //p' "$M/plan" | head -n 1; }
: > "$D/drop/mhelper.mnttab"
HS_ENV="LINUXFS_FS_TEST_MNTTAB=$D/drop/mhelper.mnttab"; hst mountedhang linger "$M/fdcli.log" '^lingerer '; unset HS_ENV
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log"); lp=$(sed -n 's/^lingerer //p' "$M/fdcli.log"); cg=$(pgid_of)
test $rc = 1 && test $t -lt 5 && grep -q 'stopped by SIGTERM' "$M/plan"
ok $? "root plan (helper stand-in): SIGTERM while waiting for mount_macfuse's status → exit 1 within 5 s ($t s, rc $rc: $(tail -n 3 "$M/plan" | tr '\n' ';'))"
grp_gone "$cg" && test -n "$lp" && gone "$lp"; ok $? "and the CLI stand-in's group ($cg) is gone, its lingerer ($lp) too"
test -n "$hp" && gone "$hp"; ok $? "and the stand-in mount helper ($hp) is gone"
grep -qx "unmount-attempt $V/NAME" "$M/plan"; ok $? "and with a mount table showing root's mount, root unmounts it ($(grep '^unmount' "$M/plan"))"
test -z "$lp" || kill "$lp" 2>/dev/null
: > "$D/drop/mhelper.mnttab"
HS_ENV="LINUXFS_FS_TEST_MNTTAB=$D/drop/mhelper.mnttab"; hst nostatus linger "$M/fdcli.log" '^lingerer '; unset HS_ENV
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log"); lp=$(sed -n 's/^lingerer //p' "$M/fdcli.log"); cg=$(pgid_of)
test $rc = 1 && test $t -lt 5 && grp_gone "$cg" && test -n "$hp" && gone "$hp" && ! grep -q '^unmount-attempt' "$M/plan"
ok $? "and with none, it does not unmount (rc $rc, $t s: $(grep '^unmount' "$M/plan"))"
test -z "$lp" || kill "$lp" 2>/dev/null
hst "" noready "$M/fdcli.log" '^pid '
cg=$(pgid_of)
test $rc = 1 && test $t -lt 5 && grp_gone "$cg" && test ! -e "$D/drop/mhelper.log" && grep -q 'stopped by SIGTERM' "$M/plan"
ok $? "root plan (helper stand-in): SIGTERM while waiting for ready → exit 1, the CLI group ($cg) is gone, and no mount helper ran ($t s, rc $rc: $(tail -n 3 "$M/plan" | tr '\n' ';'))"
hst nofd ok "$D/drop/mhelper.log" '^pid '
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log"); cg=$(pgid_of)
test $rc = 1 && test $t -lt 5 && grp_gone "$cg" && test -n "$hp" && gone "$hp" && grep -q 'stopped by SIGTERM' "$M/plan"
ok $? "root plan (helper stand-in): SIGTERM while waiting for the device → exit 1 within 5 s, the CLI group ($cg) and the stand-in mount helper ($hp) are gone ($t s, rc $rc: $(tail -n 3 "$M/plan" | tr '\n' ';'))"
# spec: task-16j-findings-r0.md I1 -- once ok is decided root's path blocks SIGTERM: a SIGTERM after the success path's last check
#       (LINUXFS_FS_TEST_OK_PAUSE: the drop build says "ok-pause" there and sleeps) is held to the end; the program exits 0 with
#       its mount, never 1 with the mount left in place
: > "$D/drop/mhelper.mnttab"
HS_ENV="LINUXFS_FS_TEST_MNTTAB=$D/drop/mhelper.mnttab LINUXFS_FS_TEST_OK_PAUSE=2"; hst "mounted 0" ok "$M/plan" '^ok-pause'; unset HS_ENV
test $rc = 0 && test $t -lt 5 && ! grep -q '^unmount-attempt' "$M/plan" && grep -q '^ok-pause' "$M/plan" && grep -q "^macfuse_ext4	/dev/$E	$V/NAME	0" "$D/drop/mhelper.mnttab"
ok $? "root plan (helper stand-in): SIGTERM after ok is decided → exit 0 with the mount in place, no unmount ($t s, rc $rc: $(tail -n 3 "$M/plan" | tr '\n' ';'))"
# spec: task-16j-findings-r0.md I2 (the controller's ruling) -- under SIGTERM the CLI's group still gets up to 5 s to end on its SIGTERM (LKL's
#       umount and sync) before SIGKILL: a stand-in lklfuse that takes 2 s to end is never killed
hst nostatus slowterm "$M/fdcli.log" '^lingerer '
hp=$(sed -n 's/^pid //p' "$D/drop/mhelper.log"); lp=$(sed -n 's/^lingerer //p' "$M/fdcli.log"); cg=$(pgid_of)
test $rc = 1 && test $t -lt 6 && grep -qx 'clean exit' "$M/fdcli.log" && grp_gone "$cg" && test -n "$hp" && gone "$hp"
ok $? "root plan (helper stand-in): SIGTERM: a CLI group member that ends 2 s after its SIGTERM is not SIGKILLed ($t s, rc $rc, lingerer $lp: $(grep -c 'clean exit' "$M/fdcli.log") clean exit)"
hs "" ok
test $rc = 0 && test "$(grep -c '^cli-pgid ' "$M/plan")" = 1 && grep -qE '^cli-pgid [0-9]+$' "$M/plan" && test "$(pgid_of)" = "$(sed -n 's/^pgid //p' "$M/fdcli.log")"
ok $? "root plan (helper stand-in): cli-pgid: one cli-pgid N line, N the CLI stand-in's process group (rc $rc: $(grep '^cli-pgid' "$M/plan" | tr '\n' ' '); stand-in's $(grep '^pgid' "$M/fdcli.log"))"
! strings "$D/linuxfs-fs" | grep -qE 'LINUXFS_FS_TEST|unmount-attempt'; ok $? "the shipped build carries no LINUXFS_FS_TEST_* code and no unmount-attempt line"
! grep -q 'LINUXFS_FS_TEST' "$ROOT"/build/*.sh; ok $? "no build script defines LINUXFS_FS_TEST_DROP"
echo "1..$n"; exit $bad
