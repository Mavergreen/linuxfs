#!/bin/sh
# platform: host-agnostic
#   usage: pin-lkl.sh [PIN]
#          With PIN (another source pin in the same REPO/DIGEST/TARBALL_SHA256 form, components/linux-apfs/version),
#          does the same check and writes only that file's TARBALL_SHA256: UPSTREAM_VERSION is LKL's alone.
#          CI and dev only; needs git (the one script that does). For the commit components/lkl/version names (REPO,
#          DIGEST), fetches GitHub's tarball of it, checks with git that the tarball holds exactly that commit's tree, and
#          writes the tarball's SHA-256 as that file's TARBALL_SHA256 and the version it derives
#          (build/derive-upstream-version.sh --source) as UPSTREAM_VERSION. Renovate moves DIGEST and cannot compute
#          either; .github/workflows/pins-bot.yml runs this on its branch. Nothing is written until the check passes; then
#          each file is replaced by a rename. Prints what it wrote, or that both already held it. On a Mac, run it through
#          build/linux-host.sh: the kernel tree has paths that differ only in case, which a case-insensitive volume folds.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/build/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
[ $# -le 1 ] || { echo "usage: $0 [PIN]" >&2; exit 2; }
fail() { echo "pin-lkl: $*" >&2; exit 1; }
pin="$ROOT/components/lkl/version" lkl=1
if [ $# -eq 1 ]; then
  case $1 in /*) pin=$1 ;; *) pin=$ROOT/$1 ;; esac
  [ "$pin" = "$ROOT/components/lkl/version" ] || lkl=
fi
[ -f "$pin" ] || fail "no $pin"
val() { sed -n "s/^$1=//p" "$pin"; }
repo="$(val REPO)"; commit="$(val DIGEST)"
case "$repo" in https://github.com/*/*) ;; *) fail "$pin: REPO is '$repo', not a GitHub repository URL" ;; esac
case "$commit" in *[!0-9a-f]*|'') fail "$pin: DIGEST is '$commit', not a commit" ;; esac
[ "${#commit}" -eq 40 ] || fail "$pin: DIGEST is '$commit', not a 40-hex commit"

T="$(mktemp -d "${TMPDIR:-/tmp}/pin-lkl.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git="git -c core.precomposeunicode=false -c core.ignorecase=false -c core.autocrlf=false -c core.fileMode=true -c core.symlinks=true"

url="$(sh "$SHIPYARD_SCRIPTS/fetch_pinned_source.sh" --url "$repo" "$commit")" || fail "no tarball URL for $repo at $commit"
echo "==> $url" >&2
shipyard_curl --quiet "$url" "$T/src.tgz" || fail "cannot fetch $url"
sha="$(shasum -a 256 < "$T/src.tgz" | cut -c1-64)"
mkdir "$T/x" && tar xzf "$T/src.tgz" -C "$T/x" || fail "cannot extract $url"
top="$(ls -A "$T/x")"
[ -d "$T/x/$top" ] && [ "$(printf '%s\n' "$top" | wc -l | tr -d ' ')" = 1 ] || fail "$url holds more than one entry: $top"
# platform: git status never looks at an entry named .git and never reports an empty directory, so a tarball could carry
#           either unseen; neither is in a commit's tree.
extra="$(find "$T/x/$top" \( -name .git -o -type d -empty \) -print | head -5)"
[ -z "$extra" ] || { printf '%s\n' "$extra" >&2; fail "$url is not commit $commit's tree: it holds the .git or empty directory above"; }
g="$T/g.git"
$git init -q --bare "$g" && $git --git-dir="$g" fetch -q --depth 1 "$repo" "$commit" || fail "cannot fetch commit $commit of $repo"
$git --git-dir="$g" read-tree "$commit" && $git --git-dir="$g" update-ref --no-deref HEAD "$commit" || fail "cannot read commit $commit"
diffs="$($git --git-dir="$g" --work-tree="$T/x/$top" status --porcelain --untracked-files=all --ignored)" || fail "git cannot compare $url with commit $commit"
[ -z "$diffs" ] || { printf '%s\n' "$diffs" | head -20 >&2; fail "$url is not commit $commit's tree (the differences above)"; }
if [ -z "$lkl" ]; then
  if [ "$(val TARBALL_SHA256)" = "$sha" ]; then echo "pin-lkl: $pin already holds $sha"; exit 0; fi
  awk -v s="$sha" 'BEGIN { n = 0 } /^TARBALL_SHA256=/ { print "TARBALL_SHA256=" s; n++; next } { print } END { if (n != 1) exit 1 }' \
    "$pin" > "$T/pin" || fail "$pin has no single TARBALL_SHA256 line"
  cp "$T/pin" "$pin.new.$$" && mv "$pin.new.$$" "$pin" || fail "cannot write $pin"
  echo "pin-lkl: $pin TARBALL_SHA256=$sha (the commit's tree, file for file)"; exit 0
fi
up="$(sh "$ROOT/build/derive-upstream-version.sh" --source "$T/x/$top")" || fail "cannot derive the upstream version of $commit"

if [ "$(val TARBALL_SHA256)" = "$sha" ] && [ "$(tr -d ' \t\r\n' < "$ROOT/UPSTREAM_VERSION")" = "$up" ]; then
  echo "pin-lkl: components/lkl/version and UPSTREAM_VERSION already hold $sha and $up"; exit 0
fi
awk -v s="$sha" 'BEGIN { n = 0 } /^TARBALL_SHA256=/ { print "TARBALL_SHA256=" s; n++; next } { print } END { if (n != 1) exit 1 }' \
  "$pin" > "$T/pin" || fail "$pin has no single TARBALL_SHA256 line"
echo "$up" > "$T/up"
cp "$T/pin" "$pin.new.$$" && mv "$pin.new.$$" "$pin" || fail "cannot write $pin"
cp "$T/up" "$ROOT/UPSTREAM_VERSION.new.$$" && mv "$ROOT/UPSTREAM_VERSION.new.$$" "$ROOT/UPSTREAM_VERSION" || fail "cannot write UPSTREAM_VERSION"
echo "pin-lkl: TARBALL_SHA256=$sha UPSTREAM_VERSION=$up (the commit's tree, file for file)"
