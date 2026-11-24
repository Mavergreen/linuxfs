#!/bin/sh
# platform: host-agnostic
#   usage: check-fs.sh ext4|btrfs|xfs|ntfs|exfat|f2fs|apfs IMAGE
#          Checks IMAGE with Linux's own checker, read-only. For ext4 it also fails a journal that
#          still needs replaying, which `e2fsck -fn` lets through (it skips the replay and exits 0);
#          for btrfs, a log tree still to replay (log_root), which `btrfs check` lets through. xfs's
#          `xfs_repair -n` already fails a dirty log.
#          Linux only.
set -u
[ "$#" -eq 2 ] || { echo "usage: check-fs.sh ext4|btrfs|xfs|ntfs|exfat|f2fs|apfs IMAGE" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "check-fs.sh: needs Linux's fsck tools" >&2; exit 77; }
case $1 in
ext4)
  if dumpe2fs -h "$2" 2>/dev/null | grep -q needs_recovery; then
    echo "check-fs.sh: $2 has a journal that still needs replaying (not cleanly unmounted)"; exit 1
  fi
  e2fsck -fn "$2" ;;
btrfs)
  lr=$(btrfs inspect-internal dump-super "$2" | awk '$1 == "log_root" { print $2 }')
  if [ "$lr" != 0 ]; then
    echo "check-fs.sh: $2 has a log tree that still needs replaying (log_root $lr)"; exit 1
  fi
  btrfs check --readonly "$2" ;;
xfs) xfs_repair -n "$2" ;;
ntfs) ntfsfix -n "$2" ;;
exfat) fsck.exfat -n "$2" ;;
f2fs) fsck.f2fs -f --dry-run "$2" ;;
apfs) apfsck "$2" ;;
*) echo "check-fs.sh: unknown filesystem $1" >&2; exit 2 ;;
esac
