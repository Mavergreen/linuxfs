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
  -o "$D/linuxfs-fs" "$ROOT/tools/fs.c" "$ROOT/tools/fsrules.c" "$ROOT/tools/probe.c" \
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
# prefs: user plist and machine plist, as the CLI writes them
plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$2" > "$1"; }
plist "$D/empty.plist" ""
plist "$D/take.plist" "<key>NTFSTakeover</key><true/>"
plist "$D/takestr.plist" "<key>NTFSTakeover</key><string>YES</string>"
plist "$D/takeoff.plist" "<key>NTFSTakeover</key><true/><key>Automount</key><false/>"
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
out=$(u linuxfs_ext4.util -k "$E"); rc=$?
want=$(tr a-f A-F < "$D/ext4.uuid")
[ $rc = 255 ] && [ "$out" = "$want" ]; ok $? "-k prints the UUID blkid gave (rc $rc, '$out', want '$want')"
out=$(u linuxfs_btrfs.util -k "$B"); rc=$?
[ $rc = 255 ] && [ "$out" = "$(tr a-f A-F < "$D/btrfs.uuid")" ]; ok $? "-k on btrfs prints its UUID too"
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
[ $rc = 254 ]; ok $? "NTFSTakeover=true with Automount=false: exits 254 (rc $rc)"
USERP=$D/corrupt.plist MACHP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "a corrupt user plist counts as absent: the machine's NTFSTakeover=true holds (rc $rc)"
USERP=$D/empty.plist MACHP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "prefs fall back key by key: a user plist lacking the key leaves the machine's NTFSTakeover=true (rc $rc)"
USERP=$D/takeoff.plist MACHP=$D/take.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "and the user's Automount=false beats the machine's (rc $rc)"
USERP=$D/missing.plist MACHP=$D/missing2.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "missing plists use the defaults: ext4 still claimed (rc $rc)"
ln -sf "$D/take.plist" "$D/link.plist"
USERP=$D/link.plist u linuxfs_ntfs.util -p "$T" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "a symlinked user plist is refused, as absent (rc $rc)"
plist "$D/ign.plist" "<key>Ignore:my data</key><true/>"
USERP=$D/ign.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "Ignore:<LABEL> true makes the util decline that disk (rc $rc)"
plist "$D/unign.plist" "<key>Ignore:my data</key><false/>"
USERP=$D/unign.plist MACHP=$D/ign.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 255 ]; ok $? "a user Ignore false overrides a machine Ignore true (rc $rc)"
USERP=$D/empty.plist MACHP=$D/ign.plist u linuxfs_ext4.util -p "$E" removable writable >/dev/null; rc=$?
[ $rc = 254 ]; ok $? "the machine's Ignore holds when the user's plist lacks the key (rc $rc)"
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
# --- the mount role, as the console user, with stand-ins for the CLI, the keychain keeper and the dialog
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
# a CLI exit other than 4 is the mount's exit
cat > "$M/cli7" <<'EOS'
#!/bin/sh
exit 7
EOS
chmod +x "$M/cli7"
env -u HOME LINUXFS_CLI="$M/cli7" "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
[ $rc = 7 ]; ok $? "the CLI's exit status is the mount's (rc $rc)"
# encrypted: the keeper has nothing, the dialog gives pw and says remember
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
# remembered once only: no save
kc none
mt env STUB_PW=pw DLG_PWS=pw DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && ! grep -q '^save' "$M/kc.log"; ok $? "a password given 'once' is not saved"
# the keeper offers the right password: silent
kc saved pw
mt env STUB_PW=pw "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && ! grep -q '^dialog' "$M/log" && grep -qx 'stdin: pw' "$M/log"; ok $? "a saved right password mounts with no dialog (rc $rc)"
# the keeper's saved password is wrong: forget, then the dialog
kc saved old
mt env STUB_PW=pw DLG_PWS=pw "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && grep -qx 'forget disk9' "$M/kc.log" && grep -q '^dialog' "$M/log" && grep -qx 'stdin: old' "$M/log"; ok $? "a wrong saved password is forgotten, then the dialog runs (rc $rc; $(tr '\n' ';' < "$M/kc.log"))"
# an offered wrong password is not forgotten
kc offered old
mt env STUB_PW=pw DLG_PWS=pw DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && ! grep -q '^forget' "$M/kc.log"; ok $? "a wrong offered password is not forgotten"
# a wrong dialog password, then a right one: the second message starts Wrong password.
kc none
mt env STUB_PW=pw DLG_PWS="bad pw" DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && grep 'dialog: ' "$M/log" | sed -n 2p | grep -q '| Wrong password\. Hint: blue'; ok $? "after a wrong try the message starts 'Wrong password.' ($(grep 'dialog: ' "$M/log" | sed -n 2p))"
# three wrong tries: three dialogs, exit 4
kc none
mt env STUB_PW=pw DLG_PWS="a b c d" DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 4 ] && [ "$(grep -c '^dialog' "$M/log")" = 3 ]; ok $? "three wrong passwords: three dialogs, exit 4 (rc $rc)"
# Cancel
kc none
mt env STUB_PW=pw DLG_CANCEL=1 "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 4 ] && [ "$(grep -c '^args:' "$M/log")" = 1 ]; ok $? "Cancel exits 4 and the CLI ran once (rc $rc)"
# no keeper at all, and a stale socket: the dialog still runs, quickly
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
# a CLI that leaves a background child behind: the mount returns at once, and the child holds only fds 0-2
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
# Mount with an empty field asks again, counted among the 3
kc none
mt env STUB_PW=pw DLG_PWS="EMPTY pw" DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 0 ] && [ "$(grep -c '^dialog' "$M/log")" = 2 ]; ok $? "an empty password asks again instead of cancelling (rc $rc, $(grep -c '^dialog' "$M/log") dialogs)"
kc none
mt env STUB_PW=pw DLG_PWS="EMPTY EMPTY EMPTY" DLG_MODE=once "$MD" /dev/disk9 /tmp/m >/dev/null 2>&1; rc=$?
kcstop
[ $rc = 4 ] && [ "$(grep -c '^dialog' "$M/log")" = 3 ] && [ "$(grep -c '^args:' "$M/log")" = 1 ]; ok $? "three empty answers: three dialogs, exit 4, the CLI ran once (rc $rc)"
# a hint that is not UTF-8 does not cancel the dialog
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
# misuse
for bad_args in "" "/dev/disk9" "-o /dev/disk9 /tmp/m" "/dev/disk9 /tmp/m extra" "-x /dev/disk9 /tmp/m"; do
  # shellcheck disable=SC2086
  mt "$MD" $bad_args >/dev/null 2>&1; rc=$?
  [ $rc = 1 ] && [ ! -e "$M/log" ]; ok $? "misuse '$bad_args' exits 1 without running the CLI (rc $rc)"
done
echo "1..$n"; exit $bad
