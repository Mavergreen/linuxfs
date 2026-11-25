/*
 * The root mount daemon's judging functions (tools/mountd.c): pure, so a test drives each with the facts it names. The daemon
 * itself (16h, 16i) gathers the facts (the peer's credential, DiskArbitration's description, the node's owner, the mount
 * table, the probe, the mount point's stats) and acts on the verdict. Spec: item 5's amendment, §1 and §5.
 */
#ifndef LINUXFS_MOUNTD_H
#define LINUXFS_MOUNTD_H

#include "fsrules.h"
#include <stddef.h>
#include <sys/stat.h>
#include <sys/types.h>

/* One request: FS one of the six, BSD diskN or diskNsM, MNT /Volumes/<one name>; ro and owners from FLAGS. */
struct mountd_req { char fs[8], bsd[40], mnt[1024]; int ro, owners; };

/* Reads exactly one line of LEN bytes, mount<TAB>FS<TAB>BSD<TAB>FLAGS<TAB>MNT<LF>, at most 1024 bytes, no NUL:
 * - FS satisfies fsrules_name, BSD fsrules_valid_bsd;
 * - FLAGS is -, ro, owners, ro,owners or owners,ro;
 * - MNT is /Volumes/ and one component, not . or .., with no byte below 0x20 and no 0x7f (it comes last, so it may hold
 *   spaces, but a tab makes a sixth field).
 * 0 with *r filled, or -1 with *why a fixed reason (never the caller's text). */
int mountd_parse(const char *buf, size_t len, struct mountd_req *r, const char **why);

/* Who is asking. MP_SERVE: the console user (and not root). MP_ROOT: root, which mounts by itself (a final no). MP_USER: any
 * other uid, not the console user, which mounts as itself with its own rights (user). */
enum mountd_peer { MP_SERVE, MP_USER, MP_ROOT };
enum mountd_peer mountd_peer(uid_t peer, uid_t console);

/* What DiskArbitration and the node say of BSD:
 * - kind: VolumeKind ("macfuse_ext4"); content: MediaContent (the partition type);
 * - has_path: a VolumePath (mounted); leaf: MediaLeaf;
 * - ejectable: MediaEjectable or MediaRemovable, for the helper's media rule;
 * - removable: what DiskArbitration passes the util (DiskArbitration-266, the 10.9 one, always passes "removable":
 *   item-5-findings.md), for fsrules_claims;
 * - image: DeviceModel "Disk Image" or DeviceProtocol "Virtual Interface";
 * - node_uid: /dev/BSD's owner. */
struct mountd_disk { char bsd[40], kind[32], content[128]; int has_path, leaf, ejectable, removable, image; uid_t node_uid; };

/* MD_MOUNT: root mounts it. MD_USER: nothing was touched, and the mount program takes its own path with its own rights.
 * MD_REFUSE: a final no. */
enum mountd_verdict { MD_MOUNT, MD_USER, MD_REFUSE };

/* The spec's checks (§1, "Legitimacy"), in order, for request R from PEER of disk D, which the probe named TYPE (NULL: none it
 * knows) with probe FLAGS (FSF_*), under the console user's preferences P; MOUNTED_BSD and MOUNTED_MNT are whether the mount
 * table has anything from the disk (whole or any partition) and anything on MNT:
 * 1. DiskArbitration's facts: D is R's BSD, its kind exactly macfuse_<FS>, no VolumePath, a leaf;
 * 2. whose disk it is: unless fsrules_node_owner_ok(node_uid, PEER), and for an image unless node_uid is PEER, MD_USER
 *    ("not your disk: your own mount"). Root never publishes another user's disk; the user's own path still meets the
 *    helper's owner rule;
 * 3. the helper's media rule (helper_media_refusal), read-write unless R is ro;
 * 4. nothing mounted from the disk or on MNT;
 * 5. TYPE is fsrules_probe_type(FS), fsrules_claims(FS, TYPE, removable, P) holds (else rc 3), and an encrypted volume is
 *    MD_USER.
 * *rc is 3 for the claims refusal and 1 for every other refusal (0 otherwise); *why a fixed reason ("" for MD_MOUNT). */
enum mountd_verdict mountd_judge(const struct mountd_req *r, const struct mountd_disk *d, uid_t peer, const char *type,
				 unsigned flags, const struct fsprefs *p, int mounted_bsd, int mounted_mnt, int *rc, const char **why);

/* The mount point, before anything is changed: OPENED (fstat of MNT opened O_NOFOLLOW) is a directory, the same dev and inode
 * as ENTRY (a fresh lstat of MNT), on VOLUMES's device, EMPTY, and owned by root (*adopt 0) or by PEER (*adopt 1: it is
 * fchowned to root). 0, or -1 with *why. */
int mountd_mnt_facts(const struct stat *opened, const struct stat *entry, const struct stat *volumes, int empty, uid_t peer,
		     int *adopt, const char **why);

/* After fchown and fchmod: AFTER (fstat of the descriptor) is a directory, uid 0, mode 0755, the same dev and inode as
 * ENTRY_AFTER (a fresh lstat of MNT). 0, or -1 with *why, and then the caller gives the directory back to PEER. */
int mountd_adopted(const struct stat *after, const struct stat *entry_after, uid_t peer, const char **why);

/* A status for the reply: 1..255 as it is, anything else (0 included) 1. */
int mountd_rc(long rc);

/* The reply line into BUF (LEN bytes): ok<LF>, no<TAB>RC<TAB>WHY<LF> (RC through mountd_rc) or user<TAB>WHY<LF>. Tabs and
 * control characters in WHY become spaces. Cut to fit, it still ends in LF. Its length (0 when LEN < 2). */
size_t mountd_reply(char *buf, size_t len, enum mountd_verdict v, int rc, const char *why);

#endif
