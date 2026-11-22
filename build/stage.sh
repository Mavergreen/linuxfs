#!/bin/sh
# platform: host-agnostic
#   usage: stage.sh --built DIR --out STAGE
#          Lays out linuxfs's install tree under STAGE (replaced): DIR/lklfuse as libexec/lklfuse, the CLI, prober and
#          linuxfs-open when DIR has them, DIR/linuxfs-helper as /Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.helper
#          with its LaunchDaemon, DIR/linuxfs-agent with its LaunchAgent, and packaging/pre-uninstall as libexec/mavergreen/pre-uninstall, all under
#          LINUXFS_PREFIX (build/lib.sh), files 0644 and programs 0755. Ownership (0/0) is the packager's.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
usage() { echo "usage: stage.sh --built DIR --out STAGE" >&2; exit 2; }
built=; out=
while [ $# -gt 0 ]; do
  case "$1" in
    --built) [ $# -ge 2 ] || usage; built=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$built" ] && [ -n "$out" ] || usage
[ -f "$built/lklfuse" ] || { echo "stage.sh: no lklfuse in $built" >&2; exit 1; }
rm -rf "$out"
t="$out$LINUXFS_PREFIX"
mkdir -p "$t/libexec/mavergreen" "$t/bin"
put() { cp "$1" "$2" && chmod "$3" "$2"; }
put "$built/lklfuse" "$t/libexec/lklfuse" 755
for p in linuxfs-probe linuxfs-open; do [ ! -f "$built/$p" ] || put "$built/$p" "$t/libexec/$p" 755; done
[ ! -f "$REPO_ROOT/cli/linuxfs" ] || put "$REPO_ROOT/cli/linuxfs" "$t/bin/linuxfs" 755
put "$REPO_ROOT/packaging/pre-uninstall" "$t/libexec/mavergreen/pre-uninstall" 755
# spec: INGREDIENTS.md "Conformance deviations" install-path -- root-run code goes where the OS keeps it, not under /usr/local
if [ -f "$built/linuxfs-helper" ]; then
  mkdir -p "$out/Library/PrivilegedHelperTools" "$out/Library/LaunchDaemons"
  put "$built/linuxfs-helper" "$out/Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.helper" 755
  put "$REPO_ROOT/packaging/dev.mavergreen.linuxfs.helper.plist" "$out/Library/LaunchDaemons/dev.mavergreen.linuxfs.helper.plist" 644
fi
if [ -f "$built/linuxfs-agent" ]; then
  put "$built/linuxfs-agent" "$t/libexec/linuxfs-agent" 755
  mkdir -p "$out/Library/LaunchAgents"
  put "$REPO_ROOT/packaging/dev.mavergreen.linuxfs.agent.plist" "$out/Library/LaunchAgents/dev.mavergreen.linuxfs.agent.plist" 644
fi
rmdir "$t/bin" 2>/dev/null || :
find "$out" -type d -exec chmod 755 {} +
