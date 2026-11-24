#!/bin/sh
# platform: host-agnostic -- stevedore and shipyard's seams build and read the pkg; cpio lists its payload
# spec: build/package.sh -- it makes linuxfs-V.pkg from build/stage.sh's stage: dev.mavergreen.base first, then
#       dev.mavergreen.linuxfs, whose preinstall refuses a volume without macfuse; every payload entry is 0/0 with no
#       group or other write; libexec/lklfuse and libexec/mavergreen/pre-uninstall are 100755; artifact conformance
#       passes. packaging/pre-uninstall refuses while a linuxfs lklfuse runs.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/package-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
SOURCE_DATE_EPOCH=1763600000; export SOURCE_DATE_EPOCH
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "FAIL: no clang22" >&2; exit 1; }
LIPO="$CL/bin/llvm-lipo"; OTOOL="$CL/bin/llvm-otool"; NM="$CL/bin/llvm-nm"; STRINGS="$CL/bin/llvm-strings"
export LIPO OTOOL NM STRINGS
STEVEDORE="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")" || { echo "FAIL: no stevedore" >&2; exit 1; }
UP="$(upstream_version)"
V="$UP-mavericks.1"
P=".$LINUXFS_PREFIX"

mkdir -p "$T/built"
for f in lklfuse linuxfs-probe linuxfs-open linuxfs-fs linuxfs-helper linuxfs-agent; do printf '#!/bin/sh\n' > "$T/built/$f"; chmod 775 "$T/built/$f"; done
sh "$REPO_ROOT/build/stage.sh" --built "$T/built" --out "$T/stage" --version "$V" > "$T/log" 2>&1 ||
  { cat "$T/log" >&2; echo "FAIL: stage.sh refused the fixtures" >&2; exit 1; }
sh "$REPO_ROOT/build/package.sh" --stage "$T/stage" --version "$V" --out "$T/dist" > "$T/log" 2>&1 ||
  { cat "$T/log" >&2; echo "FAIL: package.sh refused the stage" >&2; exit 1; }
if sh "$REPO_ROOT/build/stage.sh" --built "$T/built" --out "$T/stage-nover" > "$T/log" 2>&1; then fail "stage.sh stages linuxfs-fs without --version"
else [ $? -eq 2 ] || fail "stage.sh without --version does not exit 2"; fi
pkg="$T/dist/linuxfs-$V.pkg"
[ -f "$pkg" ] || { echo "FAIL: no $pkg" >&2; exit 1; }

"$STEVEDORE" expand "$pkg" "$T/x" > /dev/null || { echo "FAIL: stevedore cannot expand $pkg" >&2; exit 1; }
comp=
for d in "$T"/x/*; do
  if [ -f "$d/PackageInfo" ] && grep -q 'identifier="dev.mavergreen.linuxfs"' "$d/PackageInfo"; then comp=$d; fi
done
[ -n "$comp" ] || { echo "FAIL: $pkg has no dev.mavergreen.linuxfs component" >&2; exit 1; }
first="$(sed -n 's/.*<pkg-ref id="\([^"]*\)".*/\1/p' "$T/x/Distribution" | head -n 1)"
[ "$first" = dev.mavergreen.base ] || fail "the first component is '$first', not dev.mavergreen.base"
gzip -dc < "$comp/Payload" > "$T/payload.cpio"
sh "$REPO_ROOT/build/list-payload.sh" "$T/payload.cpio" "$T/list"
H=dev.mavergreen.linuxfs.helper
for e in "$P/libexec/lklfuse	100755	0/0" "$P/libexec/mavergreen/pre-uninstall	100755	0/0" "$P/mavergreen.plist	100644	0/0" \
  "$P/libexec/linuxfs-probe	100755	0/0" "$P/libexec/linuxfs-open	100755	0/0" "$P/bin/linuxfs	100755	0/0" \
  "./Library/PrivilegedHelperTools/$H	100755	0/0" "./Library/LaunchDaemons/$H.plist	100644	0/0" \
  "$P/libexec/linuxfs-agent	100755	0/0" "./Library/LaunchAgents/dev.mavergreen.linuxfs.agent.plist	100644	0/0"; do
  grep -qxF "$e" "$T/list" || fail "the payload lacks: $e"
done
awk -F'\t' '$3 != "0/0" || ($2 !~ /^12/ && substr($2, length($2) - 1, 2) ~ /[2367]/) { print }' "$T/list" > "$T/bad"
[ ! -s "$T/bad" ] || { cat "$T/bad" >&2; fail "payload entries not 0/0, or writable by group or other"; }
grep -q "$P/libexec/linuxfs-helper\|$P/libexec/[^	]*helper" "$T/list" && fail "the root helper is under the prefix (root-run code may not be under /usr/local)"
mkdir -p "$T/plist"; (cd "$T/plist" && gzip -dc < "$comp/Payload" | cpio -id --quiet "./Library/LaunchDaemons/$H.plist" 2>/dev/null)
pl="$T/plist/Library/LaunchDaemons/$H.plist"
grep -q "<string>$H</string>" "$pl" 2>/dev/null || fail "the daemon's Label is not $H"
grep -q "<string>/Library/PrivilegedHelperTools/$H</string>" "$pl" 2>/dev/null || fail "the daemon does not run /Library/PrivilegedHelperTools/$H"
A=dev.mavergreen.linuxfs.agent
(cd "$T/plist" && gzip -dc < "$comp/Payload" | cpio -id --quiet "./Library/LaunchAgents/$A.plist" 2>/dev/null)
al="$T/plist/Library/LaunchAgents/$A.plist"
grep -q "<string>$A</string>" "$al" 2>/dev/null || fail "the agent's Label is not $A"
grep -q "<string>$LINUXFS_PREFIX/libexec/linuxfs-agent</string>" "$al" 2>/dev/null || fail "the agent does not run libexec/linuxfs-agent"
grep -A1 LimitLoadToSessionType "$al" 2>/dev/null | grep -q "<string>Aqua</string>" || fail "the agent is not limited to the console (Aqua) session"
grep -q "launchctl load.*/Library/LaunchAgents/$A.plist" "$comp/Scripts/postinstall" 2>/dev/null || fail "the postinstall does not load the agent for the console user"
grep -q "launchctl load.*/Library/LaunchDaemons/$H.plist" "$comp/Scripts/postinstall" 2>/dev/null || fail "the postinstall does not load the helper"
grep -q 'needs macfuse\|macfuse.*not installed\|requires macfuse\|macfuse' "$comp/Scripts/preinstall" ||
  fail "the preinstall does not mention macfuse"
grep -q "'5\.5\.0-mavericks\.1'" "$comp/Scripts/preinstall" ||
  fail "the preinstall does not require macfuse 5.5.0-mavericks.1 (its first release) or later"
# platform: the preinstall reads macfuse's version with PlistBuddy, which only macOS has
if [ -x /usr/libexec/PlistBuddy ]; then
  for mv in 5.4.9-mavericks.3:refused 5.5.0-mavericks.1:accepted; do
    ver=${mv%%:*} want=${mv#*:} r="$T/mf-$ver"
    mkdir -p "$r/usr/local/mavergreen/macfuse"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>version</key><string>%s</string></dict></plist>\n' \
      "$ver" > "$r/usr/local/mavergreen/macfuse/mavergreen.plist"
    ROOT="$r" sh "$comp/Scripts/preinstall" "$pkg" "$r" "$r" "$r" > "$T/pre-$ver.out" 2>&1 || :
    if grep -q '5\.5\.0-mavericks\.1' "$T/pre-$ver.out"; then got=refused; else got=accepted; fi
    [ "$got" = "$want" ] || fail "the preinstall $got macfuse $ver (want $want): $(cat "$T/pre-$ver.out")"
  done
fi
mkdir -p "$T/vol"
if ROOT="$T/vol" sh "$comp/Scripts/preinstall" "$pkg" "$T/vol" "$T/vol" "$T/vol" > "$T/pre.out" 2>&1; then
  fail "the preinstall accepts a volume without macfuse"
else
  grep -q macfuse "$T/pre.out" || fail "the preinstall's refusal does not name macfuse: $(cat "$T/pre.out")"
fi

# spec: build/fs-bundles.sh, build/stage.sh -- six filesystem bundles DiskArbitration runs, and the .d directory the
#       before-login root path execs; all root:wheel, nothing group- or world-writable (the awk check above)
S=./System/Library/Filesystems
D=./Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d
for fs in ext4 ntfs btrfs xfs f2fs apfs; do
  b=$S/linuxfs_$fs.fs/Contents
  grep -qxF "$b/Info.plist	100644	0/0" "$T/list" || fail "the payload lacks $b/Info.plist (0644)"
  for prog in linuxfs_$fs.util mount_linuxfs_$fs fsck_linuxfs_$fs; do
    grep -qxF "$b/Resources/$prog	100755	0/0" "$T/list" || fail "the payload lacks $b/Resources/$prog (0755)"
  done
done
for prog in lklfuse linuxfs linuxfs-probe linuxfs-open; do
  grep -qxF "$D/$prog	100755	0/0" "$T/list" || fail "the payload lacks $D/$prog (0755)"
done
n="$(grep -c "^$D/" "$T/list" || :)"
[ "$n" -eq 4 ] || fail "$D holds $n entries, not four programs"
mkdir -p "$T/bundles"; (cd "$T/bundles" && gzip -dc < "$comp/Payload" | cpio -id --quiet "$S/*")
for fs in ext4 ntfs btrfs xfs f2fs apfs; do
  ip="$T/bundles/System/Library/Filesystems/linuxfs_$fs.fs/Contents/Info.plist"
  case $fs in ntfs) pers=NTFS-linuxfs ;; xfs) pers=XFS ;; f2fs) pers=F2FS ;; apfs) pers=APFS ;; *) pers=$fs ;; esac
  python3 -I - "$ip" "$fs" "$pers" "$V" <<'PY' || fail "linuxfs_$fs.fs/Contents/Info.plist is wrong"
import plistlib, sys
ip, fs, pers, v = sys.argv[1:5]
d = plistlib.load(open(ip, "rb"))
def need(c, m):
    if not c: print(m, file=sys.stderr); sys.exit(1)
need(d["CFBundleIdentifier"] == "dev.mavergreen.linuxfs." + fs, "CFBundleIdentifier")
need(d["CFBundleShortVersionString"] == v and d["CFBundleVersion"] == v, "version")
need(list(d["FSPersonalities"]) == [pers], "personality is %r, want %s" % (list(d["FSPersonalities"]), pers))
p = d["FSPersonalities"][pers]
need(p["FSMountExecutable"] == "mount_linuxfs_" + fs, "FSMountExecutable")
for k in p: need(not k.startswith(("FSFormat", "FSVerification", "FSRepair")), "unexpected key " + k)
mt = d["FSMediaTypes"]
want = {"ntfs": ["EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Windows_NTFS", "Partitionless"],
        "apfs": ["7C3457EF-0000-11AA-AA11-00306543ECAC", "Partitionless"]}.get(fs,
        ["0FC63DAF-8483-4772-8E79-3D69D8477DE4", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Linux", "Partitionless"])
need(sorted(mt) == sorted(want), "FSMediaTypes %r" % sorted(mt))
for m in mt.values():
    need(m["FSProbeExecutable"] == "linuxfs_%s.util" % fs and m["FSProbeOrder"] == 900 and m["FSProbeArguments"] == "-p", "probe keys")
PY
  if command -v plutil > /dev/null 2>&1; then plutil -lint "$ip" > /dev/null || fail "plutil -lint refuses linuxfs_$fs.fs's Info.plist"; fi
done
grep -q 'killall diskarbitrationd' "$comp/Scripts/postinstall" || fail "the postinstall does not restart diskarbitrationd"
grep -q 'dscl \. -create /Users/_linuxfs' "$comp/Scripts/postinstall" || fail "the postinstall does not create _linuxfs with dscl"

printf '## Linux Filesystems %s for Mavericks (%s)\n\n### What changed\n\n- Test.\n' "$UP" "$V" > "$T/dist/RELEASE_NOTES.md"
facts="$(sh "$SHIPYARD_SCRIPTS/artifact-facts.sh" "$T/dist" "$V" "$REPO_ROOT")" || fail "artifact-facts could not read the dist"
printf '%s\n' "$facts" | sh "$SHIPYARD_SCRIPTS/check-artifact-conformance.sh" > "$T/conformance" 2>&1 ||
  { grep -v "^conformance: [a-z-]*: \(checked\|no \)" "$T/conformance" >&2; fail "the pkg does not conform"; }

# spec: packaging/postinstall-hook -- _linuxfs is made with dscl from the first ID of 200-400 free as a user and a group; every command
#       is a stub that logs, so this never touches the machine it runs on
mkdir -p "$T/pbin" "$T/ds"
cat > "$T/pbin/dscl" <<'STUB'
#!/bin/sh
ds="$PH_DIR/ds"
case "$*" in
  ". -read /Users/_linuxfs"*) [ -f "$ds/user" ] ;;
  ". -read /Groups/_linuxfs"*) [ -f "$ds/gid" ] && echo "PrimaryGroupID: $(cat "$ds/gid")" ;;
  ". -list /Users"*) cat "$ds/users" ;;
  ". -list /Groups"*) cat "$ds/groups" ;;
  ". -create"*) [ "$*" != ". -create /Users/_linuxfs" ] || : > "$ds/user"; echo "dscl $*" >> "$PH_DIR/calls" ;;
esac
STUB
for c in mkdir chown chmod touch killall launchctl stat pgrep defaults sudo; do
  printf '#!/bin/sh\necho "%s $*" >> "$PH_DIR/calls"\n' "$c" > "$T/pbin/$c"
done
printf '[ "$*" != "-f %%Su /dev/console" ] || echo "${PH_USER:-}"\n' >> "$T/pbin/stat"
# the root helper's migration: a stub that prints what PH_MIGRATED holds, as DOMAIN<TAB>LABEL lines
printf '#!/bin/sh\necho "helper $*" >> "$PH_DIR/calls"\n[ "$*" = --migrate-prefs ] && printf "%%b" "${PH_MIGRATED:-}"\n' > "$T/pbin/helper"
chmod 755 "$T/pbin"/*
run_post() {  # users groups-file-lines gid-or-empty user-exists(1/0)
  rm -f "$T/ds"/* "$T/calls"; : > "$T/calls"
  printf '%s\n' "$1" > "$T/ds/users"; printf '%s\n' "$2" > "$T/ds/groups"
  [ -z "$3" ] || echo "$3" > "$T/ds/gid"
  [ "$4" != 1 ] || : > "$T/ds/user"
  sed "s|/Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.helper|$T/pbin/helper|g" "$REPO_ROOT/packaging/postinstall-hook" > "$T/post.sh"
  PH_DIR="$T" PATH="$T/pbin:$PATH" sh "$T/post.sh" > "$T/post.out" 2>&1
}
want() { grep -qxF "$1" "$T/calls" || fail "postinstall: $2 (no '$1')"; }
run_post "root 0
_x 5" "wheel 0
staff 200" "" 0 || fail "postinstall failed with 200 taken as a group ID"
want "dscl . -create /Users/_linuxfs UniqueID 201" "200 taken as a GID gives 201"
want "dscl . -create /Groups/_linuxfs PrimaryGroupID 201" "the new group gets 201"
want "dscl . -create /Users/_linuxfs PrimaryGroupID 201" "the user's group is 201"
want "dscl . -create /Users/_linuxfs UserShell /usr/bin/false" "UserShell"
want "dscl . -create /Users/_linuxfs NFSHomeDirectory /var/empty" "NFSHomeDirectory"
want "dscl . -create /Users/_linuxfs IsHidden 1" "IsHidden"
want "touch /private/var/db/linuxfs/.created-group" "the made group is marked"
[ "$(tail -n 1 "$T/calls")" = "killall diskarbitrationd" ] || fail "postinstall does not restart diskarbitrationd last: $(tail -n 1 "$T/calls")"
grep -n 'launchctl load' "$T/calls" > /dev/null || fail "postinstall did not load the helper"
run_post "root 0" "wheel 0" 250 0 || fail "postinstall failed with the group already there"
grep -q 'create /Groups/_linuxfs' "$T/calls" && fail "postinstall remade an existing _linuxfs group"
want "dscl . -create /Users/_linuxfs PrimaryGroupID 250" "the existing group is reused"
grep -q 'touch ' "$T/calls" && fail "postinstall marked a group it did not make"
run_post "$(seq 200 400 | sed 's/^/u /')" "wheel 0" "" 0 || fail "postinstall failed with the range full"
grep -q 'no free user ID' "$T/post.out" || fail "postinstall does not warn when 200-400 is full"
grep -q 'create /Users' "$T/calls" && fail "postinstall made a user with the range full"
want "killall diskarbitrationd" "the install continues when the range is full"
run_post "root 0" "wheel 0" 250 1 || fail "postinstall failed with _linuxfs there"
grep -q 'dscl . -create' "$T/calls" && fail "postinstall changed an existing _linuxfs"
# spec: packaging/postinstall-hook -- the old Ignore:<LABEL> preferences become /etc/fstab noauto entries through the root
#       helper (--migrate-prefs: it reads the plists and writes fstab itself); each converted key is deleted from its domain,
#       the user's as the user, and Automount from both; what the helper did not convert stays
grep -q 'dev.mavergreen.linuxfs.helper --migrate-prefs' "$REPO_ROOT/packaging/postinstall-hook" || fail "the postinstall does not migrate Ignore:<LABEL> to /etc/fstab"
PH_USER=alice PH_MIGRATED='user\tmy data\nmachine\told\tone\n' run_post "root 0" "wheel 0" 250 1 || fail "postinstall failed migrating preferences"
want "helper --migrate-prefs" "the migration runs the helper"
want "sudo -u alice defaults delete dev.mavergreen.linuxfs Ignore:my data" "a converted user key is deleted as the user"
want "defaults delete /Library/Preferences/dev.mavergreen.linuxfs Ignore:old	one" "a converted machine key is deleted, whole (a tab in it)"
want "defaults delete /Library/Preferences/dev.mavergreen.linuxfs Automount" "Automount is deleted from the machine's domain"
want "sudo -u alice defaults delete dev.mavergreen.linuxfs Automount" "and from the user's"
[ "$(grep -c 'defaults delete' "$T/calls")" = 4 ] || fail "postinstall deleted keys the helper did not convert: $(grep 'defaults delete' "$T/calls" | tr '\n' '|')"
[ "$(tail -n 1 "$T/calls")" = "killall diskarbitrationd" ] || fail "postinstall does not restart diskarbitrationd after the migration"
PH_USER=root run_post "root 0" "wheel 0" 250 1 || fail "postinstall failed with root at the console"
grep -q 'sudo -u' "$T/calls" && fail "postinstall ran defaults as root for the user's domain"

mkdir -p "$T/bin"
# pre-uninstall deletes _linuxfs and its home: dscl and rm are stubs that only log, so this never touches the machine it runs on
printf '#!/bin/sh\necho "dscl $*" >> "%s/acct.calls"\n' "$T" > "$T/bin/dscl"
printf '#!/bin/sh\necho "rm $*" >> "%s/acct.calls"\n' "$T" > "$T/bin/rm"
printf '#!/bin/sh\n[ -f "%s/created-group" ]\n' "$T" > "$T/bin/ls"
chmod 755 "$T/bin/dscl" "$T/bin/rm" "$T/bin/ls"; : > "$T/acct.calls"
printf '#!/bin/sh\nprintf "%%s\\n" "  PID COMMAND" "  412 %s/libexec/lklfuse -f -o type=ext4 /dev/fd/3 /Volumes/data"\n' "$LINUXFS_PREFIX" > "$T/bin/ps"
chmod 755 "$T/bin/ps"
# the helper's --noauto-remove-all is a stub that logs (the real one would edit this machine's /etc/fstab)
printf '#!/bin/sh\necho "helper $*" >> "%s/launchctl.calls"\n' "$T" > "$T/bin/helper"; chmod 755 "$T/bin/helper"
sed "s|/Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.helper|$T/bin/helper|g" "$REPO_ROOT/packaging/pre-uninstall" > "$T/pre-uninstall"
h="$T/pre-uninstall"
if PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > "$T/u.out" 2>&1; then fail "pre-uninstall allows uninstall while lklfuse runs"
else grep -q /Volumes/data "$T/u.out" || fail "pre-uninstall's refusal does not name the volume: $(cat "$T/u.out")"; fi
printf '#!/bin/sh\nprintf "%%s\\n" "  PID COMMAND" "  412 /Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d/lklfuse -f -o type=ext4 /dev/fd/3 /Volumes/dd"\n' > "$T/bin/ps"
if PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > "$T/u.out" 2>&1; then fail "pre-uninstall allows uninstall while the .d lklfuse runs"
else grep -q /Volumes/dd "$T/u.out" || fail "pre-uninstall's refusal does not name the .d volume: $(cat "$T/u.out")"; fi
! grep -q 'noauto-remove-all' "$T/launchctl.calls" 2>/dev/null || fail "pre-uninstall removed the fstab entries though it refused"
[ ! -s "$T/acct.calls" ] || fail "pre-uninstall touched _linuxfs while a volume was mounted: $(cat "$T/acct.calls")"
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/Volumes/Other sh "$h" > /dev/null 2>&1 || fail "pre-uninstall refuses for another volume"
printf '#!/bin/sh\necho "  PID COMMAND"\necho "    1 /sbin/launchd"\n' > "$T/bin/ps"
printf '#!/bin/sh\necho "launchctl $*" >> "%s/launchctl.calls"\n' "$T" > "$T/bin/launchctl"; chmod 755 "$T/bin/launchctl"
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > /dev/null 2>&1 || fail "pre-uninstall refuses with nothing mounted"
grep -q "launchctl unload.*/Library/LaunchDaemons/$H.plist" "$T/launchctl.calls" 2>/dev/null || fail "pre-uninstall does not unload the helper"
# spec: packaging/pre-uninstall -- linuxfs's /etc/fstab noauto lines go with it (the helper's --noauto-remove-all, as root),
#       before the helper is unloaded
grep -qx "helper --noauto-remove-all" "$T/launchctl.calls" || fail "pre-uninstall does not remove linuxfs's /etc/fstab entries"
[ "$(grep -n 'helper --noauto-remove-all' "$T/launchctl.calls" | cut -d: -f1)" -lt "$(grep -n "launchctl unload.*$H.plist" "$T/launchctl.calls" | cut -d: -f1)" ] ||
  fail "pre-uninstall removes the fstab entries after unloading the helper"
grep -q 'dev.mavergreen.linuxfs.helper --noauto-remove-all' "$REPO_ROOT/packaging/pre-uninstall" || fail "pre-uninstall does not run the installed helper's --noauto-remove-all"
printf '#!/bin/sh\ncase "$*" in "-u _linuxfs") exit 0 ;; esac\necho 77\n' > "$T/bin/pgrep"; chmod 755 "$T/bin/pgrep"; : > "$T/launchctl.calls"; : > "$T/acct.calls"
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > "$T/u.out" 2>&1 || fail "pre-uninstall refuses with only _linuxfs processes"
grep -q '_linuxfs' "$T/u.out" || fail "pre-uninstall says nothing when a _linuxfs process keeps the account"
[ ! -s "$T/acct.calls" ] || fail "pre-uninstall deleted _linuxfs while a process runs as it: $(cat "$T/acct.calls")"
printf '#!/bin/sh\ncase "$*" in "-u _linuxfs") exit 1 ;; esac\necho 77\n' > "$T/bin/pgrep"; : > "$T/acct.calls"
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > /dev/null 2>&1 || fail "pre-uninstall refuses with nothing running as _linuxfs"
for c in "dscl . -delete /Users/_linuxfs" "rm -rf /private/var/db/linuxfs"; do
  grep -qxF "$c" "$T/acct.calls" 2>/dev/null || fail "pre-uninstall did not run: $c"
done
! grep -q 'Groups/_linuxfs' "$T/acct.calls" || fail "pre-uninstall deleted a _linuxfs group the postinstall did not make"
: > "$T/created-group"; : > "$T/acct.calls"
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > /dev/null 2>&1 || fail "pre-uninstall refuses with the group marker"
grep -qxF "dscl . -delete /Groups/_linuxfs" "$T/acct.calls" || fail "pre-uninstall kept the group the postinstall made"
rm -f "$T/created-group"
: > "$T/launchctl.calls"
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > /dev/null 2>&1
grep -q "launchctl bsexec 77 .*launchctl unload .*/Library/LaunchAgents/dev.mavergreen.linuxfs.agent.plist" "$T/launchctl.calls" ||
  fail "pre-uninstall does not unload the agent in the console session"

[ "$fails" -eq 0 ] || { echo "package-test: $fails failure(s)" >&2; exit 1; }
echo "package-test: ok"
