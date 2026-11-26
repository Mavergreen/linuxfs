/*
 * The bundles' portable rules: pure C99, libc only, so they build and test on any host. The multi-call program
 * in each filesystem bundle (probe, quick check, mount) calls these for every decision that is not about the Mac.
 */
#ifndef LINUXFS_FSRULES_H
#define LINUXFS_FSRULES_H

#include <stddef.h>
#include <sys/types.h>

enum fsrole { FS_UTIL, FS_MOUNT, FS_FSCK };

/* The one table of names: what each filesystem is called to DiskArbitration (bundle, personality), to macFUSE
 * (fstypename, which is the statfs f_fstypename without the "macfuse_" a Mac shows as its own, and fssubtype) and to
 * Finder (fsname, the kind Get Info shows). fstypename is at most 6 bytes: macFUSE joins it to "macfuse_" in a
 * 16-byte field. Entries are in the order ext4, ntfs, btrfs, xfs, f2fs, apfs. */
struct fsname { const char *fs, *probe_type, *bundle, *fstypename, *personality, *fsname; int subtype; };

/* The entry for <fs> (ext4, ntfs, btrfs, xfs, f2fs or apfs), else NULL. */
const struct fsname *fsrules_name(const char *fs);

/* Entry I, 0..5, then NULL. */
const struct fsname *fsrules_name_at(size_t i);

/* The fs whose bundle name is F_FSTYPENAME (statfs's f_fstypename of its volumes, "macfuse_ext4"), or NULL: only the six
 * exact names match, never "macfuse" or a longer or other name. */
const char *fsrules_fs_of_type(const char *f_fstypename);

/* Whether a mount-table entry is root's own mount of <fs> from disk <bsd> (diskN or diskNsM): 1 only when its type
 * (f_fstypename) is <fs>'s macfuse_ name, its source (f_mntfromname) is exactly /dev/<bsd>, and its owner (f_owner) is
 * root. Anything else on that mount point (another type, another source, a user's macFUSE mount) is not root's to
 * unmount. NULL arguments give 0. */
int fsrules_mount_is_roots(const char *fs, const char *bsd, const char *f_fstypename, const char *f_mntfromname, unsigned owner);

/* The filesystem a program's name stands for: macfuse_<fs>.util, mount_macfuse_<fs> or fsck_macfuse_<fs>
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

/* What linuxfs-probe says of a volume beyond its type and label (probe.h): its third field, an APFS Fusion device's role
 * ("fusion-main UUID", "fusion-tier2 UUID") or "", and its fourth, space-separated words: "encrypted" (an APFS volume 0
 * that needs its password), "dirty" (an NTFS volume Windows left in use) and "nocase" (an APFS volume 0 case-insensitive
 * as a whole, which lklfuse's nocase tells macFUSE; it changes nothing in fsrules_access). Other words are ignored; NULL
 * is "". */
#define FSF_FUSION 1u
#define FSF_ENCRYPTED 2u
#define FSF_DIRTY 4u
#define FSF_NOCASE 8u
unsigned fsrules_probe_flags(const char *fusion, const char *words);

enum fsaccess { FSA_RW, FSA_RO, FSA_REFUSE };

/* How a volume the probe named probed_type, with flags, mounts: the one rule the root mount program (before it has
 * macFUSE mount) and cli/linuxfs (through linuxfs-probe --access) both follow. Before login an encrypted volume is
 * refused: no keychain and no one to ask for its password. Otherwise read-only when asked (ro, which DiskArbitration's
 * rdonly sets), when the ReadOnly preference is on, for an encrypted volume or an APFS Fusion container, for APFS without
 * APFSWrite (linux-apfs-rw's writing is experimental), and for a dirty NTFS volume (ntfs3 refuses to write it). *why, when
 * why is not NULL, is the reason: "encrypted" for the refusal; for read-only the first of "asked", "ReadOnly",
 * "encrypted", "fusion", "apfs" and "dirty"; "" for read-write. A NULL probed_type or prefs is refused. */
enum fsaccess fsrules_access(const char *probed_type, unsigned flags, int ro, int before_login, const struct fsprefs *p,
			     const char **why);

struct mountreq { int ro, owners, update; const char *dev, *mnt; };

/* mount_macfuse_<fs>'s arguments: [-o a,b]... (or -oa,b) DEV MNT. `rdonly` or `ro` sets ro. `owners` or `perm` sets owners
 * and `noowners` or `noperm` clears it, the last one given winning, as in mount(8): 10.9's DiskArbitration passes noowners
 * for every external disk, then any `owners` from an /etc/fstab entry or the vsdb (/var/db/volinfo.database) for the
 * volume's UUID. With neither, owners is 0. `update` (mount -u, which vsdbutil runs to change ownership in place) sets
 * update. Every other option is ignored. 0, or -1 on misuse. */
int fsrules_parse_mount(int argc, char **argv, struct mountreq *m);

/* A volume's name from its label, by cli/linuxfs's safe_name: / : , = \ and control characters become -, leading dots go, at most
 * 200 characters cut on a character boundary; "Linux" when that leaves nothing or the label is not UTF-8. */
void fsrules_volname(const char *label, char *out, size_t outlen);

/* The hint in the CLI's "(hint: HINT)" at the end of its encrypted-volume and wrong-password messages (the last one in ERR),
 * into HINT (LEN bytes, cut to fit on a character boundary); 0 when ERR names none or the hint is not valid UTF-8. */
int fsrules_hint(const char *err, char *hint, size_t len);

/* Whether S is a BSD disk name, disk[0-9]+(s[0-9]+)? and at most 32 characters: what root opens as /dev/r<S>. */
int fsrules_valid_bsd(const char *s);

/* The whole disk a BSD name is on (disk2 for disk2s1, disk2 for disk2) into OUT: 1, or 0 when BSD is not a BSD name or OUT
 * (OUTLEN bytes) has no room for it. */
int fsrules_whole_disk(const char *bsd, char *out, size_t outlen);

/* Whether a mount's source (f_mntfromname) is the whole disk WHOLE or one of its partitions: exactly /dev/WHOLE or
 * /dev/WHOLEs<digits>. /dev/disk22 is not disk2's, nor is a raw node or any other name. NULL arguments give 0. */
int fsrules_from_disk(const char *f_mntfromname, const char *whole);

/* Whether a mount from F_MNTFROMNAME already there refuses a mount of BSD (final review r0 C1, as HFS+'s partitions mount side
 * by side): for a partition diskNsM, a mount from exactly /dev/diskNsM or from its whole disk /dev/diskN; for a whole disk
 * diskN, a mount from /dev/diskN or any of its partitions (fsrules_from_disk). A sibling partition never refuses. NULL, or a
 * BSD that is not a BSD name, gives 0. */
int fsrules_mount_blocks(const char *f_mntfromname, const char *bsd);

/* Whose disk it is, the one rule both root processes use (the helper's open, probe and uuid; the mount daemon's judge): 1 when
 * the disk's node (/dev/BSD's st_uid) is root's, the Mac's own, or the asking user PEER's, as hdiutil makes an image's node for
 * the user who attached it; else 0. The mount daemon adds that an image's node must be the peer's. */
int fsrules_node_owner_ok(uid_t node, uid_t peer);

#endif
