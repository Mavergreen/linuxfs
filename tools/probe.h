/* The superblock check linuxfs-probe and linuxfs-helper share. */
#ifndef LINUXFS_PROBE_H
#define LINUXFS_PROBE_H
#include <stddef.h>
/*
 * Reads the start of fd (at most 68 KiB, from offset 0) and returns the filesystem's name as lklfuse's
 * type= spells it, filling label (NUL-terminated, empty when none is read); NULL when no superblock it
 * knows is there. Returns NULL and sets *err to an errno value when fd cannot be read; *err is 0 otherwise.
 */
const char *linuxfs_probe_fd(int fd, char *label, size_t labellen, int *err);
/* After linuxfs_probe_fd: a third field, or "": "fusion-main UUID" or "fusion-tier2 UUID" for an APFS Fusion device. */
const char *linuxfs_probe_extra(void);
#endif
