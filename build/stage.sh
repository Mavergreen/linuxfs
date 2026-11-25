#!/bin/sh
# platform: host-agnostic
#   usage: stage.sh --built DIR --out STAGE [--version V]
#          Lays out linuxfs's install tree under STAGE (replaced): DIR/lklfuse as libexec/lklfuse, the CLI, prober and
#          linuxfs-open when DIR has them, DIR/linuxfs-helper as /Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.helper
#          with its LaunchDaemon, DIR/linuxfs-agent with its LaunchAgent, and packaging/pre-uninstall as libexec/mavergreen/pre-uninstall, all under
#          LINUXFS_PREFIX (build/lib.sh), files 0644 and programs 0755. When DIR has linuxfs-fs it also lays out the six DiskArbitration
#          bundles, version V, under System/Library/Filesystems (linuxfs-fs copied to each bundle's macfuse_<fs>.util, mount_macfuse_<fs>
#          and fsck_macfuse_<fs>), and Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d with copies of lklfuse, the CLI, the prober
#          and linuxfs-open for the before-login root path; --version V is then required (exit 2 without it). DIR's linuxfs-volicon goes
#          in the .d directory too, with art/tux.png: the postinstall, as root, makes each bundle's volume icon with them. Ownership (0/0)
#          is the packager's.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
usage() { echo "usage: stage.sh --built DIR --out STAGE [--version V]" >&2; exit 2; }
built=; out=; ver=
while [ $# -gt 0 ]; do
  case "$1" in
    --built) [ $# -ge 2 ] || usage; built=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    --version) [ $# -ge 2 ] || usage; ver=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$built" ] && [ -n "$out" ] || usage
[ ! -f "$built/linuxfs-fs" ] || [ -n "$ver" ] || usage
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
# spec: tests/package-test.sh -- DiskArbitration's bundles: one linuxfs-fs binary, copied to each role name (it picks its role
#       from argv[0], tools/fsrules.c). Root runs them, so they are in /System/Library/Filesystems, root:wheel (the packager's).
if [ -f "$built/linuxfs-fs" ]; then
  sh "$REPO_ROOT/build/fs-bundles.sh" --version "$ver" --out "$out/System/Library/Filesystems"
  for fs in ext4 ntfs btrfs xfs f2fs apfs; do
    r="$out/System/Library/Filesystems/macfuse_$fs.fs/Contents/Resources"
    mkdir -p "$r"
    for n in "macfuse_$fs.util" "mount_macfuse_$fs" "fsck_macfuse_$fs"; do put "$built/linuxfs-fs" "$r/$n" 755; done
  done
fi
# spec: tools/fs.c mount_as_root -- the before-login root path execs these (names and directory as it spells them), as _linuxfs
pd="$out/Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d"
mkdir -p "$pd"
put "$built/lklfuse" "$pd/lklfuse" 755
[ ! -f "$REPO_ROOT/cli/linuxfs" ] || put "$REPO_ROOT/cli/linuxfs" "$pd/linuxfs" 755
for p in linuxfs-probe linuxfs-open; do [ ! -f "$built/$p" ] || put "$built/$p" "$pd/$p" 755; done
# spec: item 6's amendment (the volume icon) -- root runs linuxfs-volicon at install, so it and the Tux it reads are where root's code is
if [ -f "$built/linuxfs-volicon" ]; then
  put "$built/linuxfs-volicon" "$pd/linuxfs-volicon" 755
  put "$REPO_ROOT/art/tux.png" "$pd/tux.png" 644
fi
rmdir "$t/bin" 2>/dev/null || :
find "$out" -type d -exec chmod 755 {} +
