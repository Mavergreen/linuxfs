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

/* The bounds, in seconds (N6, R2, R3). What the daemon may take for one request, end to end:
 * - MOUNTD_QUEUE_WAIT: waiting for a slot (then "user busy": nothing was touched);
 * - MOUNTD_REQUEST: reading the request line, one total bound (M4);
 * - MOUNTD_PREBEGIN: before begin (DiskArbitration's 15, then the probe and the mount point);
 * - MOUNTD_DEADLINE: the mount program, then SIGTERM; MOUNTD_GRACE: then its groups' SIGKILL.
 * Their sum, 285, plus 5 s of margin is MOUNTD_CLIENT_WAIT, what the mount program waits in all. MOUNTD_CLIENT_PREBEGIN is
 * what it waits from hi to begin: the daemon's pre-begin alarm cannot fire while its child is blocked in an uninterruptible
 * read (a wedged image's probe), so the client keeps its own bound. The smoke's 300 s bound on hdiutil attach caps the
 * whole mount. tests/mountd-policy-test.c (limits_fit) adds them up. */
#define MOUNTD_REQUEST 5
#define MOUNTD_QUEUE_WAIT 60
#define MOUNTD_PREBEGIN 30
#define MOUNTD_DEADLINE 170
#define MOUNTD_GRACE 20
#define MOUNTD_CLIENT_WAIT 290
#define MOUNTD_CLIENT_PREBEGIN (MOUNTD_QUEUE_WAIT + MOUNTD_REQUEST + MOUNTD_PREBEGIN + 5)

/* The slots (I3): children per uid and in all, requests queued per uid beyond them (first in, first out), and how long
 * the daemon stays with no child and nothing queued. */
#define MOUNTD_SLOTS_UID 4
#define MOUNTD_SLOTS 8
#define MOUNTD_QUEUE 16
#define MOUNTD_IDLE 60

/* One request: FS one of the six, BSD diskN or diskNsM, MNT /Volumes/<one name> (or, when mountd_parse gives 1, a mount point
 * elsewhere, answered "user"); ro and owners from FLAGS. */
struct mountd_req { char fs[8], bsd[40], mnt[1024]; int ro, owners; };

/* Reads exactly one line of LEN bytes, mount<TAB>FS<TAB>BSD<TAB>FLAGS<TAB>MNT<LF>, at most 1024 bytes, no NUL:
 * - FS satisfies fsrules_name, BSD fsrules_valid_bsd;
 * - FLAGS is -, ro, owners, ro,owners or owners,ro;
 * - MNT is /Volumes/ and one component of at most 255 bytes, not . or .., with no byte below 0x20 and no 0x7f (it comes
 *   last, so it may hold spaces, but a tab makes a sixth field).
 * 0 with *r filled, or -1 with *why a fixed reason (never the caller's text). A request well formed in every other way whose MNT
 * (with no control byte) is not /Volumes/ and one component, not . or .., gives 1 with *r filled and *why "... your own mount": no
 * request root serves, so the user's own mount (user), not a final no (16j fix round 1). */
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
 * 0. PEER 0 is refused, "root mounts by itself" (the design's final no for root; mountd_peer's MP_ROOT answers it first);
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
 * ENTRY_AFTER (a fresh lstat of MNT), and EMPTY_AFTER (read again through the descriptor: the peer could add an entry
 * before the fchown, and cannot after it). 0, or -1 with *why, and then the caller gives the directory back to PEER. */
int mountd_adopted(const struct stat *after, const struct stat *entry_after, int empty_after, uid_t peer, const char **why);

/* The CLI's group kill (N5, R1). A process as the daemon sees it (proc_pidinfo PROC_PIDTBSDINFO): pid, parent, group, effective
 * uid and start time. */
struct mountd_proc { pid_t pid, ppid, pgid; uid_t uid; unsigned long long sec, usec; };

/* Whether NOW (NULL: gone) is still WAS: the same pid, run as RUNAS, started at the same time to the microsecond. */
int mountd_still_ours(const struct mountd_proc *was, const struct mountd_proc *now, uid_t runas);

/* What the deadline may SIGKILL of the CLI's group PGID: its members that run as RUNAS, started since the mount program
 * (SINCE), refreshed once a second. A group id is recycled only after the group has ended, so (I1):
 * - the first look takes every such member; a leader (pid PGID) older than the program means the group is not ours: frozen,
 *   empty;
 * - each later look keeps the members still themselves (mountd_still_ours) and admits a newcomer only as a child of one;
 * - it freezes, admitting nothing more, once it sees the group empty, or pid PGID with another start time than the leader's.
 * So a recycled group's processes, which descend from no member, never enter it. */
#define MOUNTD_SNAP_MAX 256
struct mountd_snap {
	pid_t pgid;
	uid_t runas;
	unsigned long long since_sec, since_usec, leader_sec, leader_usec;
	int seen, frozen, leader_known, n;
	struct mountd_proc m[MOUNTD_SNAP_MAX];
};
void mountd_snap_init(struct mountd_snap *s, pid_t pgid, uid_t runas, unsigned long long since_sec,
		      unsigned long long since_usec);
/* One look: NOW is the group's processes as listed now (N of them, any uid; others are ignored). */
void mountd_snap_refresh(struct mountd_snap *s, const struct mountd_proc *now, int n);

/* A status for the reply: 1..255 as it is, anything else (0 included) 1. */
int mountd_rc(long rc);

/* The reply line into BUF (LEN bytes): ok<LF>, no<TAB>RC<TAB>WHY<LF> (RC through mountd_rc) or user<TAB>WHY<LF>. Tabs and
 * control characters in WHY become spaces. Cut to fit, it still ends in LF. Its length (0 when LEN < 2). */
size_t mountd_reply(char *buf, size_t len, enum mountd_verdict v, int rc, const char *why);

#endif
