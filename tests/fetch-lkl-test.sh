#!/bin/sh
# platform: host-agnostic
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fetch-lkl-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "not ok - $1"; exit 1; }

digest=$(sed -n 's/^DIGEST=//p' "$ROOT/components/lkl/version")
[ -n "$digest" ] || fail "components/lkl/version has no DIGEST"
up=$(tr -d ' \t\r\n' < "$ROOT/UPSTREAM_VERSION")
sh "$ROOT/build/fetch-lkl.sh" "$T/lkl" || fail "fetch-lkl.sh exited non-zero for the committed pin"
grep -q "^VERSION = ${up%%.*}\$" "$T/lkl/Makefile" || fail "fetched tree is not the kernel UPSTREAM_VERSION ($up) names"
pl=${up#*.}; pl=${pl%%.*}
grep -q "^PATCHLEVEL = $pl\$" "$T/lkl/Makefile" || fail "fetched tree is not the kernel UPSTREAM_VERSION ($up) names"
[ -f "$T/lkl/tools/lkl/lklfuse.c" ] || fail "fetched tree has no tools/lkl/lklfuse.c"
grep -q "$digest" "$T/lkl/.mavergreen-source" || fail "source stamp does not name the pinned digest ($digest)"
echo "ok - committed pin fetches the pinned LKL tree"

mkdir -p "$T/badpin"
grep -v '^TARBALL_SHA256=' "$ROOT/components/lkl/version" > "$T/badpin/version"
if LKL_PIN_DIR="$T/badpin" sh "$ROOT/build/fetch-lkl.sh" "$T/lkl2" 2>/dev/null; then
  fail "a pin with no TARBALL_SHA256 must be refused, not fetched unverified"
fi
echo "ok - a pin missing its tarball hash is refused"
