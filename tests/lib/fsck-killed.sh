#!/bin/sh
# platform: host-agnostic
#   usage: fsck-killed.sh IMAGE [ext4|ntfs]
#          After a kill -9 mid-write: Linux's own checker, not LKL, must replay the journal and
#          find the file system clean. Works on a copy (IMAGE.fsck), so the image itself is left for
#          LKL's own replay. Passes only if there was a journal to replay, `e2fsck -fy` fixed no
#          more than that (exit 0 or 1), and a second `e2fsck -fn` finds nothing. For ntfs (no
#          journal replay in ntfs-3g): `ntfsfix -n` must first find damage (the MFT mirror out of
#          date), then `ntfsfix` must repair the copy and `ntfsfix -n` find it consistent. Linux only.
set -u
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "usage: fsck-killed.sh IMAGE [ext4|ntfs]" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "fsck-killed.sh: needs Linux's e2fsck" >&2; exit 77; }
img=$1 copy=$1.fsck
if [ "${2:-ext4}" = ntfs ]; then
  ntfsfix -n "$img" && { echo "fsck-killed.sh: $img looks undamaged (was it killed mid-write?)" >&2; exit 1; }
  cp "$img" "$copy" || exit 1
  ntfsfix "$copy"; rc=$?
  [ "$rc" -eq 0 ] || { echo "fsck-killed.sh: ntfsfix could not repair the killed volume (exit $rc)" >&2; rm -f "$copy"; exit 1; }
  ntfsfix -n "$copy"; rc=$?
  rm -f "$copy"
  exit $rc
fi
dumpe2fs -h "$img" 2>/dev/null | grep -q needs_recovery \
  || { echo "fsck-killed.sh: $img has no journal to replay (was it killed mid-write?)" >&2; exit 1; }
cp "$img" "$copy" || exit 1
e2fsck -fy "$copy"; rc=$?
[ "$rc" -le 1 ] || { echo "fsck-killed.sh: e2fsck -fy exit $rc: more than a journal replay" >&2; rm -f "$copy"; exit 1; }
e2fsck -fn "$copy"; rc=$?
rm -f "$copy"
exit $rc
