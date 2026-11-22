#!/bin/sh
# platform: macOS-only -- CommonCrypto stands in for the kernel's AES and SHA-256
#   usage: sh tests/apfs-unlock-test.sh
#          Builds components/linux-apfs/src/unlock.c against CommonCrypto with tests/apfs-unlock-test.c and runs it:
#          the published vectors, keybags built here, and the encrypted container macOS made
#          (tests/fixtures/apfs/enc.img.gz), unlocked with its password down to a decrypted node.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(mktemp -d "${TMPDIR:-/tmp}/apfs-unlock-test.XXXXXX")
trap 'rm -rf "$D"' EXIT
cc -std=c99 -Wall -Wextra -Werror -I"$ROOT/tests/lib" -I"$ROOT/components/linux-apfs/src" \
  -o "$D/t" "$ROOT/tests/apfs-unlock-test.c" "$ROOT/components/linux-apfs/src/unlock.c"
gzip -dc "$ROOT/tests/fixtures/apfs/enc.img.gz" > "$D/enc.img"
"$D/t" "$D/enc.img"
