#!/bin/sh
# platform: host-agnostic
#   usage: fetch-lkl.sh DEST
#          Replaces DEST with the pinned LKL source (components/lkl/version, or $LKL_PIN_DIR/version),
#          verified against its tarball SHA-256, with patches/lkl/*.patch applied and linux-apfs-rw
#          (components/linux-apfs/version) grafted in as fs/apfs by build/graft-apfs.sh.
set -eu
[ "$#" -eq 1 ] || { echo "usage: fetch-lkl.sh DEST" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/msc.sh"
pin="${LKL_PIN_DIR:-$ROOT/components/lkl}/version"
val() { sed -n "s/^$1=//p" "$pin"; }
repo=$(val REPO); digest=$(val DIGEST); sha=$(val TARBALL_SHA256)
for k in REPO DIGEST TARBALL_SHA256; do
  [ -n "$(val $k)" ] || { echo "fetch-lkl.sh: $pin has no $k" >&2; exit 1; }
done
sh "$SHIPYARD_SCRIPTS/fetch_pinned_source.sh" "$repo" "$digest" "$sha" "$1"
if ls "$ROOT"/patches/lkl/*.patch >/dev/null 2>&1; then
  sh "$SHIPYARD_SCRIPTS/apply_patches.sh" "$1" "$ROOT/patches/lkl"
fi
# spec: linux-apfs-rw, built in as fs/apfs (read-only APFS)
a=$ROOT/components/linux-apfs/version
av() { sed -n "s/^$1=//p" "$a"; }
A=$(mktemp -d "${TMPDIR:-/tmp}/linux-apfs.XXXXXX")
sh "$SHIPYARD_SCRIPTS/fetch_pinned_source.sh" "$(av REPO)" "$(av DIGEST)" "$(av TARBALL_SHA256)" "$A/src"
sh "$ROOT/build/graft-apfs.sh" "$A/src" "$1" "$(av TAG)" "$ROOT/components/linux-apfs"
rm -rf "$A"
