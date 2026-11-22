#!/bin/sh
# platform: host-agnostic
#   usage: upstream-release-notes-url.sh <upstream-version>
#          LKL publishes no release notes; this prints the pinned commit's history on lkl/linux.
set -eu
[ $# -eq 1 ] || { echo "usage: upstream-release-notes-url.sh <upstream-version>" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
printf 'https://github.com/lkl/linux/commits/%s\n' "$(sed -n 's/^DIGEST=//p' "$ROOT/components/lkl/version")"
