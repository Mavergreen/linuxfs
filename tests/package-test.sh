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
. "$REPO_ROOT/tests/lib/shipyard-registry.sh" "$T"
SOURCE_DATE_EPOCH=1763600000; export SOURCE_DATE_EPOCH
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "FAIL: no clang22" >&2; exit 1; }
LIPO="$CL/bin/llvm-lipo"; OTOOL="$CL/bin/llvm-otool"; NM="$CL/bin/llvm-nm"; STRINGS="$CL/bin/llvm-strings"
export LIPO OTOOL NM STRINGS
STEVEDORE="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")" || { echo "FAIL: no stevedore" >&2; exit 1; }
UP="$(upstream_version)"
V="$UP-mavericks.1"
P=".$LINUXFS_PREFIX"

mkdir -p "$T/built"
for f in lklfuse linuxfs-probe linuxfs-open linuxfs-helper linuxfs-agent; do printf '#!/bin/sh\n' > "$T/built/$f"; chmod 775 "$T/built/$f"; done
sh "$REPO_ROOT/build/stage.sh" --built "$T/built" --out "$T/stage" > "$T/log" 2>&1 ||
  { cat "$T/log" >&2; echo "FAIL: stage.sh refused the fixtures" >&2; exit 1; }
sh "$REPO_ROOT/build/package.sh" --stage "$T/stage" --version "$V" --out "$T/dist" > "$T/log" 2>&1 ||
  { cat "$T/log" >&2; echo "FAIL: package.sh refused the stage" >&2; exit 1; }
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

printf '## Linux Filesystems %s for Mavericks (%s)\n\n### What changed\n\n- Test.\n' "$UP" "$V" > "$T/dist/RELEASE_NOTES.md"
facts="$(sh "$SHIPYARD_SCRIPTS/artifact-facts.sh" "$T/dist" "$V" "$REPO_ROOT")" || fail "artifact-facts could not read the dist"
printf '%s\n' "$facts" | sh "$SHIPYARD_SCRIPTS/check-artifact-conformance.sh" > "$T/conformance" 2>&1 ||
  { grep -v "^conformance: [a-z-]*: \(checked\|no \)" "$T/conformance" >&2; fail "the pkg does not conform"; }

mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "  PID COMMAND" "  412 %s/libexec/lklfuse -f -o type=ext4 /dev/fd/3 /Volumes/data"\n' "$LINUXFS_PREFIX" > "$T/bin/ps"
chmod 755 "$T/bin/ps"
h="$REPO_ROOT/packaging/pre-uninstall"
if PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > "$T/u.out" 2>&1; then fail "pre-uninstall allows uninstall while lklfuse runs"
else grep -q /Volumes/data "$T/u.out" || fail "pre-uninstall's refusal does not name the volume: $(cat "$T/u.out")"; fi
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/Volumes/Other sh "$h" > /dev/null 2>&1 || fail "pre-uninstall refuses for another volume"
printf '#!/bin/sh\necho "  PID COMMAND"\necho "    1 /sbin/launchd"\n' > "$T/bin/ps"
printf '#!/bin/sh\necho "launchctl $*" >> "%s/launchctl.calls"\n' "$T" > "$T/bin/launchctl"; chmod 755 "$T/bin/launchctl"
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > /dev/null 2>&1 || fail "pre-uninstall refuses with nothing mounted"
grep -q "launchctl unload.*/Library/LaunchDaemons/$H.plist" "$T/launchctl.calls" 2>/dev/null || fail "pre-uninstall does not unload the helper"
printf '#!/bin/sh\necho 77\n' > "$T/bin/pgrep"; chmod 755 "$T/bin/pgrep"; : > "$T/launchctl.calls"
PATH="$T/bin:$PATH" MAVERGREEN_ROOT=/ sh "$h" > /dev/null 2>&1
grep -q "launchctl bsexec 77 .*launchctl unload .*/Library/LaunchAgents/dev.mavergreen.linuxfs.agent.plist" "$T/launchctl.calls" ||
  fail "pre-uninstall does not unload the agent in the console session"

[ "$fails" -eq 0 ] || { echo "package-test: $fails failure(s)" >&2; exit 1; }
echo "package-test: ok"
