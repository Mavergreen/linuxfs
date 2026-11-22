#!/bin/sh
# platform: host-agnostic
#   usage: build-updater.sh VERSION APP
#          Builds the Sparkle updater (updater/CMakeLists.txt), x86_64 for 10.9 only, with the clang22 release
#          components/clang22 pins (shipyard's fetch_clang22.sh) and shipyard's MavericksToolchain.cmake, configured by
#          shipyard-cmake on a Mac and the host's cmake on Linux, in a fresh directory under the build root that is removed
#          afterwards; and copies linuxfs-updater.app to APP, which must not exist. VERSION is
#          <UPSTREAM_VERSION>-mavericks.N. Its icon is the generic macOS application icon, by explicit opt-in
#          (updater/ICON-CREDIT.txt): LKL has no release and no artwork to take one from. The build log goes to stderr.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
[ $# -eq 2 ] || { echo "usage: $0 VERSION APP" >&2; exit 2; }
V=$1
APP=$2
die() { echo "build-updater: $*" >&2; exit 1; }
case "$V" in
  "$(upstream_version)"-mavericks.[1-9]*) ;;
  *) die "$V is not $(upstream_version) with a -mavericks.N (UPSTREAM_VERSION)" ;;
esac
case "$APP" in /*) ;; *) APP="$(pwd)/$APP" ;; esac
[ ! -e "$APP" ] && [ ! -L "$APP" ] || die "$APP already exists"
if [ "$(uname -s)" = Linux ]; then
  SC="$(command -v cmake)" || die "no cmake on PATH"
else
  # platform: /usr/local/mavergreen/bin reaches PATH only through a login shell's paths.d
  SC="$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)"
fi
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || die "no clang22"
LIPO="$CL/bin/llvm-lipo"; OTOOL="$CL/bin/llvm-otool"; NM="$CL/bin/llvm-nm"; STRINGS="$CL/bin/llvm-strings"
export LIPO OTOOL NM STRINGS
BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
mkdir -p "$BUILD"
W="$(mktemp -d "$BUILD/updater.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SY="$(dirname "$SHIPYARD_SCRIPTS")"
"$SC" -S "$REPO_ROOT/updater" -B "$W/b" -DCMAKE_TOOLCHAIN_FILE="$SY/MavericksToolchain.cmake" -DMavericksShipyard_DIR="$SY" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 \
  -DCMAKE_OBJC_COMPILER="$CL/bin/clang" -DCMAKE_OBJC_COMPILER_TARGET=x86_64-apple-macos10.9 \
  -DCMAKE_OBJC_FLAGS=--no-default-config -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld --ld-path=$CL/bin/ld64.lld" \
  -DLINUXFS_VERSION="$V" >&2 || die "the updater did not configure"
"$SC" --build "$W/b" >&2 || die "the updater did not build"
mkdir -p "$(dirname "$APP")"
# platform: COPYFILE_DISABLE keeps macOS's cp from writing AppleDouble ._* files for extended attributes
COPYFILE_DISABLE=1 cp -Rp "$W/b/linuxfs-updater.app" "$APP"
echo "build-updater: $APP" >&2
