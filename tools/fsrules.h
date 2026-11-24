/*
 * The bundles' portable rules: pure C99, libc only, so they build and test on any host. The multi-call program
 * in each filesystem bundle (probe, quick check, mount) calls these for every decision that is not about the Mac.
 */
#ifndef LINUXFS_FSRULES_H
#define LINUXFS_FSRULES_H

#include <stddef.h>

enum fsrole { FS_UTIL, FS_MOUNT, FS_FSCK };

/* The filesystem a program's name stands for: linuxfs_<fs>.util, mount_linuxfs_<fs> or fsck_linuxfs_<fs>
 * (any directory before it). NULL for anything else, or an <fs> that is not ext4, btrfs, xfs, f2fs, apfs or
 * ntfs; *role is then untouched. role may be NULL. */
const char *fsrules_fs_from_name(const char *argv0, enum fsrole *role);

/* The name tools/probe.c gives that filesystem: ntfs is ntfs3, the others unchanged. */
const char *fsrules_probe_type(const char *fs);

struct fsprefs { int readonly, ntfs_takeover, apfs_write; };
void fsrules_default_prefs(struct fsprefs *p);

/* Whether the bundle for <fs> claims a disk the probe named <probed_type>. NTFS is the Mac's unless
 * NTFSTakeover is on and the disk is removable. A NULL fs, probed_type or prefs declines (returns 0). There is no
 * global Automount: a volume is kept from mounting by itself by its own /etc/fstab noauto entry (fstab.h). */
int fsrules_claims(const char *fs, const char *probed_type, int removable, const struct fsprefs *p);

struct mountreq { int asked, ro; const char *dev, *mnt; };

/* mount_linuxfs_<fs>'s arguments: [-o a,b]... (or -oa,b) DEV MNT. `owners` sets asked, `rdonly` or `ro` sets ro.
 * 0, or -1 on misuse. */
int fsrules_parse_mount(int argc, char **argv, struct mountreq *m);

/* A volume's name from its label, by cli/linuxfs's safe_name: / : , = \ and control characters become -, leading dots go, at most
 * 200 characters cut on a character boundary; "Linux" when that leaves nothing or the label is not UTF-8. */
void fsrules_volname(const char *label, char *out, size_t outlen);

/* The hint in the CLI's "(hint: HINT)" at the end of its encrypted-volume and wrong-password messages (the last one in ERR),
 * into HINT (LEN bytes, cut to fit on a character boundary); 0 when ERR names none or the hint is not valid UTF-8. */
int fsrules_hint(const char *err, char *hint, size_t len);

#endif
