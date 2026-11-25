#!/bin/sh
# platform: host-agnostic -- shipyard's stevedore seams build the pkg
# spec: tests/package-test.sh -- holds the contract.
#   usage: package.sh --stage DIR --version V --out DIR [--updater-app APP]
#          Packages build/stage.sh's stage DIR as OUT/linuxfs-V.pkg: dev.mavergreen.base first, then
#          dev.mavergreen.linuxfs, with the 10.9.5 floor; its preinstall refuses a volume without Mavergreen
#          macFUSE 5.5.0-mavericks.4 or later (--requires macfuse>=, the floor MACFUSE_MIN). V is UPSTREAM_VERSION with its -mavericks.N. A caller without git
#          exports SOURCE_DATE_EPOCH.
set -eu
umask 022
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
die() { echo "package: $*" >&2; exit 1; }
usage() { echo "usage: $0 --stage DIR --version V --out DIR [--updater-app APP]" >&2; exit 2; }
stage=; app=; V=; out=
while [ $# -gt 0 ]; do
  case "$1" in
    --stage|--updater-app|--version|--out) [ $# -ge 2 ] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --stage) stage=$2 ;; --updater-app) app=$2 ;; --version) V=$2 ;; --out) out=$2 ;;
  esac
  shift 2
done
[ -n "$stage" ] && [ -n "$V" ] && [ -n "$out" ] || usage
short=$LINUXFS_SHORT
# spec: tests/package-test.sh -- the floor: the macfuse release this linuxfs was tested with before the 10.9 job moved to the pin,
#       5.5.0-mavericks.5, whose name pass-through (-o nonorm_insensitive) lklfuse gates on the installed version itself and does
#       without, scanning for names (patches/lkl/0012-lklfuse-darwin-unicode.patch). .4 carries the single-threaded-loop fix, and lklfuse
#       ends on SIGTERM over /dev/fd/N (the before-login mount; tools/fs.c MACFUSE_FD_MOUNTPOINT_SINCE, 5.5.0-mavericks.2, is the
#       gate for mounting then at all). The 10.9 cause of lklfuse ignoring SIGTERM was LKL's setjmp saving the signal mask
#       (patches/0011), not macFUSE: .2 and .3 with that patch are untested. A floor, not the build's pin (components/macfuse/version):
#       linuxfs and macfuse update separately, so a floor that followed the pin would fail a linuxfs update until macfuse's
#       own updater had run. Raise it only when linuxfs needs a newer one.
MACFUSE_MIN=5.5.0-mavericks.4
id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" identifier "$short" 2>/dev/null)" ||
  die "the shipyard at $SHIPYARD_SCRIPTS does not register $short"
[ -z "${LINUXFS_TEST_EXTRA_FSTYPENAME:-}" ] || die "LINUXFS_TEST_EXTRA_FSTYPENAME is set: that test hook would ship an extra bundle"
up="$(upstream_version)"
case "$V" in "$up"-mavericks.[1-9]*) ;; *) die "--version $V is not $up with a -mavericks.N (UPSTREAM_VERSION)" ;; esac
[ -f "$stage$LINUXFS_PREFIX/libexec/lklfuse" ] || die "$stage is not a build/stage.sh stage"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
pkg="$out/$short-$V.pkg"
W="$(mktemp -d "${TMPDIR:-/tmp}/package.XXXXXX")"
trap 'rm -rf "$W"' EXIT
root="$W/root"
COPYFILE_DISABLE=1 cp -pR "$stage" "$root"
set -- --stage "$root" --product "$short" --name "Mavericks Linux Filesystems" --version "$V" --requires "macfuse>=$MACFUSE_MIN" \
  --scripts-out "$W/scripts" --postinstall-hook "$REPO_ROOT/packaging/postinstall-hook"
[ -z "$app" ] || set -- "$@" --updater-app "$app"
sh "$SHIPYARD_SCRIPTS/stage_product.sh" "$@" >&2
find "$root" -name '._*' -exec rm -f {} +
mkdir -p "$W/component"
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$root" --identifier "$id" --version "$V" \
  --install-location / --scripts "$W/scripts" --out "$W/component/$short.pkg" > /dev/null
sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier "$id" --title "Linux Filesystems for Mavericks" \
  --component "$W/component/$short.pkg" --out "$W/product.pkg" --host-arch x86_64 --min-os 10.9.5 --require-scripts > /dev/null
sh "$SHIPYARD_SCRIPTS/assert_pkg_installs_in_place.sh" "$W/product.pkg" >&2
mv "$W/product.pkg" "$pkg"
echo "package: $pkg" >&2
