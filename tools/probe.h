/* The superblock check linuxfs-probe and linuxfs-helper share. */
#ifndef LINUXFS_PROBE_H
#define LINUXFS_PROBE_H
#include <signal.h>
#include <stddef.h>
/*
 * Reads the start of fd (at most 68 KiB, from offset 0) and returns the filesystem's name as lklfuse's
 * type= spells it, filling label (NUL-terminated, empty when none is read); NULL when no superblock it
 * knows is there. Returns NULL and sets *err to an errno value when fd cannot be read; *err is 0 otherwise.
 */
const char *linuxfs_probe_fd(int fd, char *label, size_t labellen, int *err);
/* When set, a read of linuxfs_probe_fd's that a signal interrupts (EINTR) gives up, NULL with *err EINTR, once *linuxfs_probe_stop
 * is nonzero, rather than reading on: the mount program's SIGTERM flag (tools/fs.c). NULL (the default): it always reads on. */
extern volatile sig_atomic_t *linuxfs_probe_stop;
/* After linuxfs_probe_fd: a third field, or "": "fusion-main UUID" or "fusion-tier2 UUID" for an APFS Fusion device. */
const char *linuxfs_probe_extra(void);
/* After linuxfs_probe_fd: a fourth field, or "": space-separated words, "encrypted" for an APFS container whose volume 0
 * needs a password, "dirty" for an NTFS volume Windows left in use (fsrules.h reads them). */
const char *linuxfs_probe_flags(void);
/* After linuxfs_probe_fd: the line every prober prints (without its newline): TYPE<TAB>LABEL, then <TAB>EXTRA and
 * <TAB>FLAGS when there are any (EXTRA empty when only FLAGS are). 0, or -1 when it does not fit in len. */
int linuxfs_probe_line(char *out, size_t len, const char *type, const char *label);
/* After linuxfs_probe_fd: writes the filesystem's UUID, uppercase 8-4-4-4-12, to out (outlen at least 37) and returns 0;
 * -1 when it has none (ntfs3, vfat, exfat), it is all zero (as blkid), or out is too small. APFS's is the container's.
 * An APFS Fusion container's second (tier2) device deliberately has none: two disks sharing one UUID would confuse
 * DiskArbitration, and tier2 never mounts on its own. */
int linuxfs_probe_uuid(char *out, size_t outlen);
#endif
