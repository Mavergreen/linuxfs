/*
 * dev.mavergreen.linuxfs.mountd, the root mount daemon (linuxfs-mountd). Spec: item 5's amendment, §1 and §5.
 * usage: linuxfs-mountd            (run by launchd as dev.mavergreen.linuxfs.mountd, on demand, through its Sockets)
 *
 * Its judging functions (mountd.h) decide from facts the daemon gathers and change nothing. The daemon's main is built only
 * without LINUXFS_MOUNTD_NO_MAIN; the policy test (tests/mountd-test.sh) defines it and links these with tools/helper.c
 * (LINUXFS_HELPER_NO_MAIN), for its media rule.
 *
 * The front door (main): it checks in with launchd for its listener and, for each connection, in the parent (which uses no
 * CoreFoundation), reads the peer's credential (LOCAL_PEERCRED) before anything else:
 * - not the user at the console: "user<TAB>not the user at the console"; root: "no<TAB>1<TAB>root mounts by itself". Neither
 *   takes a slot, and each is logged to syslog at most once per 10 s per uid;
 * - the user at the console: "hi", the peer's uid and groups to syslog, then a child, at most MOUNTD_SLOTS_UID per uid and
 *   MOUNTD_SLOTS in all. Beyond that, MOUNTD_QUEUE per uid wait first in, first out; past MOUNTD_QUEUE_WAIT, or beyond the
 *   queue, "user<TAB>busy" (nothing was touched, so the mount program's own path is safe).
 * The child reads the one request line within MOUNTD_REQUEST seconds in all, and parses it (mountd_parse); a mount point
 * not directly under /Volumes is answered "user" (the user's own mount), never run. The daemon exits 0 after
 * MOUNTD_IDLE seconds with no child and nothing queued, and on SIGTERM (whose handler only sets a flag). The socket
 * (/var/run/dev.mavergreen.linuxfs.mountd.sock) sits in a directory group daemon may write: the mount program checks that
 * its peer is root before it sends anything. Syslog gets the peers, refusals and results; stderr (the log file) only a
 * failure to start.
 *
 * The parent takes at most ACCEPT_BATCH connections per pass, so a flood never keeps it from reaping, dispatching, SIGTERM
 * or the idle exit (I1). A queued request is served only if its uid is still the console user's (m2).
 *
 * The work (the child, after the parse; spec §1): DiskArbitration describes the disk (within DA_WAIT s); /dev/BSD's owner and
 * device, the mount table, a superblock probe of /dev/rBSD and the console user's preferences go to mountd_judge; the mount
 * point is opened without following a symlink, flocked for the request's life (two disks never stack on one), and judged
 * (mountd_mnt_facts). Until then nothing is changed, and a SIGALRM handler answers "user" when it takes longer than
 * MOUNTD_PREBEGIN. Then "begin"; a mount point of the peer's is adopted (root's, 0755, checked again, given back on any
 * doubt); the bundle's mount_macfuse_<fs>, trusted (trust_path), is spawned in a process group of its own with a fixed argv,
 * PATH alone and 0-2 only, its output drained (the first 64 KiB to syslog, and its first "cli-pgid N"). At MOUNTD_DEADLINE
 * it gets SIGTERM; MOUNTD_GRACE later, SIGKILL to its group and to the CLI's group N as mountd_snap_refresh keeps it: the
 * _linuxfs members first seen and their children, frozen once the group is seen empty or recycled, each still itself.
 * "ok" only when it exited 0 (after SIGTERM too), root's mount of /dev/BSD is on top of MNT and /dev/BSD is still the device
 * judged. Before any "no" after "begin", root's mount of the disk still on top of MNT is unmounted (undo_orphan, MNT_FORCE),
 * so no mount is ever left beside a "no"; any reply other than "ok" gives an adopted mount point back when nothing is mounted
 * on it. One result line per request goes to syslog, or,
 * after "too slow", one from the parent.
 *
 * The test build (LINUXFS_MOUNTD_TEST, never shipped) binds its own socket and takes the console's uid (or a file to read
 * it from), the slots, the queue and the idle time as options; --foreign-pgid stands peers of one process group in for
 * another uid. It logs to stderr as well as syslog, and LINUXFS_MOUNTD_TEST_CRED_FAIL makes every credential unreadable.
 * Without LINUXFS_MOUNTD_TEST_PROGRAM its child is a stub that sleeps LINUXFS_MOUNTD_TEST_CHILD_SLEEP seconds and answers
 * "user not yet" (the front door's tests). With it, the child does the work with stand-ins: the program's directory
 * (trusted as the test user's), LINUXFS_MOUNTD_TEST_DA (a key=value file for DiskArbitration; _DA_SLEEP delays it),
 * _VOLUMES, _MNTTAB, _RUNAS (the group kill's _linuxfs), _PROCTAB (a process table for the group kill, which then says
 * "kill PID" rather than signalling), _ADOPT_SWAP, _RDEV_SHIFT, and --deadline and --grace. Adoption
 * and giving back are said ("adopt MNT", "giveback MNT UID MODE") rather than done. --describe BSD prints what the real
 * DiskArbitration says of BSD, read in a forked child as the daemon reads it.
 */
#include "mountd.h"
#include <stdio.h>
#include <string.h>

/* tools/helper.c: why a partition must not be handed out, from what it is; NULL when it may */
const char *helper_media_refusal(const char *content, int leaf, int ejectable, const char *fstype, int rw);

#define MOUNTD_REQ_MAX 1024
#define VOLUMES "/Volumes/"
#define MOUNTD_NAME_MAX 255	/* NAME_MAX: a longer name could never be opened */

/* field F (N bytes) into OUT (LEN bytes) as a string: 1, or 0 when it does not fit */
static int field(char *out, size_t len, const char *f, size_t n)
{
	if (n >= len)
		return 0;
	memcpy(out, f, n);
	out[n] = '\0';
	return 1;
}

int mountd_parse(const char *buf, size_t len, struct mountd_req *r, const char **why)
{
	static const char *const flags[] = { "-", "ro", "owners", "ro,owners", "owners,ro" };
	struct mountd_req q;
	const char *f[5], *p, *end, *name;
	size_t n[5], i, nlen;
	int k;

	memset(&q, 0, sizeof(q));
	*why = "a request is one line of at most 1024 bytes";
	if (!buf || len == 0 || len > MOUNTD_REQ_MAX || memchr(buf, '\0', len) || buf[len - 1] != '\n' ||
	    memchr(buf, '\n', len - 1))
		return -1;
	end = buf + len - 1;
	*why = "a request is mount<TAB>FS<TAB>BSD<TAB>FLAGS<TAB>MNT";
	for (p = buf, i = 0; i < 5; i++) {
		const char *t = i < 4 ? memchr(p, '\t', (size_t)(end - p)) : end;

		if (!t)
			return -1;
		f[i] = p;
		n[i] = (size_t)(t - p);
		p = t + (i < 4);
	}
	if (memchr(f[4], '\t', n[4]) || n[0] != 5 || memcmp(f[0], "mount", 5) != 0)
		return -1;
	*why = "not a filesystem linuxfs mounts";
	if (!field(q.fs, sizeof(q.fs), f[1], n[1]) || !fsrules_name(q.fs))
		return -1;
	*why = "not a BSD disk name";
	if (!field(q.bsd, sizeof(q.bsd), f[2], n[2]) || !fsrules_valid_bsd(q.bsd))
		return -1;
	*why = "the flags are -, ro, owners, ro,owners or owners,ro";
	for (k = 0; k < 5; k++)
		if (n[3] == strlen(flags[k]) && memcmp(f[3], flags[k], n[3]) == 0)
			break;
	if (k == 5)
		return -1;
	q.ro = k == 1 || k == 3 || k == 4;
	q.owners = k >= 2;
	*why = "the mount point has no control characters";
	if (!field(q.mnt, sizeof(q.mnt), f[4], n[4]))
		return -1;
	for (i = 0; q.mnt[i]; i++)
		if ((unsigned char)q.mnt[i] < 0x20 || (unsigned char)q.mnt[i] == 0x7f)
			return -1;
	/* a well-formed request for a mount point not directly under /Volumes is none root serves, and nothing is wrong with it: the
	 * user's own mount (16j fix round 1, the controller's ruling), 1 */
	name = q.mnt + strlen(VOLUMES);
	if (strncmp(q.mnt, VOLUMES, strlen(VOLUMES)) != 0 || !*name || strchr(name, '/') || strcmp(name, ".") == 0 ||
	    strcmp(name, "..") == 0) {
		*r = q;
		*why = "the mount point is not directly under /Volumes: your own mount";
		return 1;
	}
	nlen = strlen(name);
	*why = "the mount point's name is at most 255 bytes";
	if (nlen > MOUNTD_NAME_MAX)
		return -1;
	*r = q;
	*why = "";
	return 0;
}

enum mountd_peer mountd_peer(uid_t peer, uid_t console)
{
	if (peer == 0)
		return MP_ROOT;
	return peer == console ? MP_SERVE : MP_USER;
}

enum mountd_verdict mountd_judge(const struct mountd_req *r, const struct mountd_disk *d, uid_t peer, const char *type,
				 unsigned flags, const struct fsprefs *p, int mounted_bsd, int mounted_mnt, int *rc, const char **why)
{
	const struct fsname *n = fsrules_name(r->fs);
	const char *media;

	*rc = 1;
#define REFUSE(w) do { *why = (w); return MD_REFUSE; } while (0)
	/* root mounts by itself (the peer check answers it before judging; this keeps "an image only the peer's" true for 0) */
	if (peer == 0)
		REFUSE("root mounts by itself");
	/* 1. DiskArbitration's facts */
	if (!n)
		REFUSE("not a filesystem linuxfs mounts");
	if (strcmp(d->bsd, r->bsd) != 0)
		REFUSE("DiskArbitration described another disk");
	if (strcmp(d->kind, n->bundle) != 0)
		REFUSE("DiskArbitration has not given the disk to this filesystem's bundle");
	if (d->has_path)
		REFUSE("DiskArbitration has the disk mounted already");
	if (!d->leaf)
		REFUSE("a disk with partitions under it");
	/* 2. whose disk it is: the Mac's or the peer's, and an image only the peer's. Nothing is touched, so the user's own
	 * path is safe, and there the helper's owner rule still holds */
	if (!fsrules_node_owner_ok(d->node_uid, peer) || (d->image && d->node_uid != peer)) {
		*rc = 0;
		*why = "not your disk: your own mount";
		return MD_USER;
	}
	/* 3. the helper's media rule */
	if ((media = helper_media_refusal(d->content, d->leaf, d->ejectable, type, !r->ro)))
		REFUSE(media);
	/* 4. the mount table */
	if (mounted_bsd || mounted_mnt)
		REFUSE("something is mounted on the mount point or from the disk already");
	/* 5. the probe */
	if (!type || strcmp(type, fsrules_probe_type(r->fs)) != 0)
		REFUSE("the disk does not hold the filesystem asked for");
	if (!fsrules_claims(r->fs, type, d->removable, p)) {
		*rc = 3;
		REFUSE("the preferences say not to");
	}
#undef REFUSE
	*rc = 0;
	if (flags & FSF_ENCRYPTED) {
		*why = "encrypted";
		return MD_USER;
	}
	*why = "";
	return MD_MOUNT;
}

int mountd_mnt_facts(const struct stat *opened, const struct stat *entry, const struct stat *volumes, int empty, uid_t peer,
		     int *adopt, const char **why)
{
	if (!S_ISDIR(opened->st_mode) || !S_ISDIR(entry->st_mode))
		*why = "the mount point is not a directory";
	else if (opened->st_dev != entry->st_dev || opened->st_ino != entry->st_ino)
		*why = "the mount point changed";
	else if (opened->st_dev != volumes->st_dev)
		*why = "the mount point is not on /Volumes's volume";
	else if (!empty)
		*why = "the mount point is not empty";
	else if (opened->st_uid != 0 && (peer == 0 || opened->st_uid != peer))
		*why = "the mount point is another user's";
	else {
		*adopt = opened->st_uid != 0;
		*why = "";
		return 0;
	}
	return -1;
}

int mountd_adopted(const struct stat *after, const struct stat *entry_after, int empty_after, uid_t peer, const char **why)
{
	(void)peer;	/* on -1 the caller gives the directory back to the peer */
	if (!S_ISDIR(after->st_mode) || after->st_uid != 0 || (after->st_mode & 07777) != 0755 ||
	    after->st_dev != entry_after->st_dev || after->st_ino != entry_after->st_ino) {
		*why = "the mount point changed";
		return -1;
	}
	if (!empty_after) {
		*why = "the mount point is not empty";
		return -1;
	}
	*why = "";
	return 0;
}

int mountd_still_ours(const struct mountd_proc *was, const struct mountd_proc *now, uid_t runas)
{
	return now && now->pid == was->pid && now->uid == runas && now->sec == was->sec && now->usec == was->usec;
}

void mountd_snap_init(struct mountd_snap *s, pid_t pgid, uid_t runas, unsigned long long since_sec, unsigned long long since_usec)
{
	memset(s, 0, sizeof *s);
	s->pgid = pgid;
	s->runas = runas;
	s->since_sec = since_sec;
	s->since_usec = since_usec;
}

/* P is in S's group, run as S's uid, and started no earlier than the mount program */
static int snap_candidate(const struct mountd_snap *s, const struct mountd_proc *p)
{
	return p->pgid == s->pgid && p->uid == s->runas && p->pid > 1 &&
	       (p->sec > s->since_sec || (p->sec == s->since_sec && p->usec >= s->since_usec));
}

static int snap_holds(const struct mountd_snap *s, pid_t pid)
{
	int i;

	for (i = 0; i < s->n; i++)
		if (s->m[i].pid == pid)
			return 1;
	return 0;
}

static const struct mountd_proc *snap_find(const struct mountd_proc *now, int n, pid_t pid)
{
	int i;

	for (i = 0; i < n; i++)
		if (now[i].pid == pid)
			return &now[i];
	return NULL;
}

void mountd_snap_refresh(struct mountd_snap *s, const struct mountd_proc *now, int n)
{
	const struct mountd_proc *leader;
	int i, k, grew, members = 0;

	if (s->frozen)
		return;
	for (i = 0; i < n; i++)
		members += now[i].pgid == s->pgid;
	leader = snap_find(now, n, s->pgid);
	if (leader && leader->pgid != s->pgid)
		leader = NULL;
	/* a group seen empty has ended, and its id may be anyone's next: nothing more is ever admitted */
	if (members == 0) {
		s->frozen = 1;
		return;
	}
	if (!s->seen) {
		s->seen = 1;
		/* a leader older than the program: a group that was never this mount's */
		if (leader && !snap_candidate(s, leader)) {
			s->frozen = 1;
			s->n = 0;
			return;
		}
		if (leader) {
			s->leader_known = 1;
			s->leader_sec = leader->sec;
			s->leader_usec = leader->usec;
		}
		for (i = 0; i < n && s->n < MOUNTD_SNAP_MAX; i++)
			if (snap_candidate(s, &now[i]))
				s->m[s->n++] = now[i];
		return;
	}
	/* keep the members still themselves */
	for (i = k = 0; i < s->n; i++)
		if (mountd_still_ours(&s->m[i], snap_find(now, n, s->m[i].pid), s->runas) &&
		    snap_find(now, n, s->m[i].pid)->pgid == s->pgid)
			s->m[k++] = s->m[i];
	s->n = k;
	/* the leader's pid with another start: the group id was recycled */
	if (s->leader_known && leader && (leader->sec != s->leader_sec || leader->usec != s->leader_usec)) {
		s->frozen = 1;
		return;
	}
	/* admit a newcomer only as a member's child, until no more are */
	do {
		grew = 0;
		for (i = 0; i < n && s->n < MOUNTD_SNAP_MAX; i++)
			if (snap_candidate(s, &now[i]) && !snap_holds(s, now[i].pid) && snap_holds(s, now[i].ppid)) {
				s->m[s->n++] = now[i];
				grew = 1;
			}
	} while (grew);
}

int mountd_rc(long rc)
{
	return rc >= 1 && rc <= 255 ? (int)rc : 1;
}

size_t mountd_reply(char *buf, size_t len, enum mountd_verdict v, int rc, const char *why)
{
	char head[16];
	const char *s;
	size_t n = 0;

	if (len < 2) {
		if (len)
			buf[0] = '\0';
		return 0;
	}
	if (v == MD_MOUNT) {
		snprintf(head, sizeof(head), "ok");
		why = NULL;
	} else if (v == MD_USER) {
		snprintf(head, sizeof(head), "user\t");
	} else {
		snprintf(head, sizeof(head), "no\t%d\t", mountd_rc(rc));
	}
	for (s = head; *s && n < len - 2; s++)
		buf[n++] = *s;
	for (s = why ? why : ""; *s && n < len - 2; s++)
		buf[n++] = (unsigned char)*s < 0x20 || (unsigned char)*s == 0x7f ? ' ' : *s;
	buf[n++] = '\n';
	buf[n] = '\0';
	return n;
}

#ifndef LINUXFS_MOUNTD_NO_MAIN
#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <launch.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/ucred.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>
#include "plist.h"
#include "probe.h"
#include "trust.h"

#define LISTENER "Listener"	/* the plist's Sockets key (16k) */
#define CHILDREN_MAX 64	/* room for the slots (MOUNTD_SLOTS, or the test build's --max) */
#define QUEUE_MAX 64	/* room for the queue, over every uid */
#define REFUSAL_EVERY_MS 10000	/* a refused uid is logged at most this often */
#define REFUSALS 16	/* uids remembered for that */
#define ACCEPT_BATCH 16	/* connections taken per pass of the loop (I1) */

#define DA_WAIT 15	/* seconds DiskArbitration may take (M6), of MOUNTD_PREBEGIN */
#define RUN_USER "_linuxfs"	/* who runs the CLI and lklfuse: the only uid the group kill reaches in the CLI's group */
#define PROGRAM_FMT "/System/Library/Filesystems/macfuse_%s.fs/Contents/Resources/mount_macfuse_%s"
#define PROGRAM_PATH "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
#define OUTPUT_LOGGED (64 * 1024)	/* the program's output to syslog; the rest is drained unread (M5) */
#define TOO_SLOW_EXIT 3	/* the child's status when it answered "too slow" from its SIGALRM handler (m2) */

struct limits { int slots_uid, slots, queue, queue_wait, idle, status; uid_t console; int console_given; int deadline, grace; };
static struct limits lim = { MOUNTD_SLOTS_UID, MOUNTD_SLOTS, MOUNTD_QUEUE, MOUNTD_QUEUE_WAIT, MOUNTD_IDLE, 0, 0, 0,
			     MOUNTD_DEADLINE, MOUNTD_GRACE };

/* The test build's hooks; the shipped build has neither their names nor their effect */
#ifdef LINUXFS_MOUNTD_TEST
#define TEST_ENV(name) getenv(name)
#else
#define TEST_ENV(name) ((char *)NULL)
#endif
static struct { pid_t pid; uid_t uid; } kids[CHILDREN_MAX];
static int nkids;
static struct { int fd; uid_t uid; long long since; } queue[QUEUE_MAX];
static int nqueued;
static struct { uid_t uid; long long at; } refusals[REFUSALS];
static volatile sig_atomic_t stopping, child_ended;
#ifdef LINUXFS_MOUNTD_TEST
static const char *console_file;	/* --console-file */
static pid_t foreign_pgid;	/* --foreign-pgid: peers in this process group stand for another uid */
#endif

static void on_term(int sig) { (void)sig; stopping = 1; }	/* only a flag: the loop acts on it */
static void on_child(int sig) { (void)sig; child_ended = 1; }	/* only a flag: it wakes the loop, which reaps */

static long long now_ms(void)
{
	static mach_timebase_info_data_t tb;

	if (!tb.denom)
		mach_timebase_info(&tb);
	return (long long)((double)mach_absolute_time() * tb.numer / tb.denom / 1e6);
}

#define IDENT "linuxfs-mountd"
#define FACILITY LOG_DAEMON

/* one line to syslog. The test build also writes it to stderr, for the tests to read; it still calls syslog, so its
 * children are forked from a parent that has used syslog (ASL), as the shipped daemon's are (m5). */
static void say_at(int pri, const char *fmt, va_list ap)
{
#ifdef LINUXFS_MOUNTD_TEST
	va_list cp;

	va_copy(cp, ap);
	vfprintf(stderr, fmt, cp);
	fputc('\n', stderr);
	va_end(cp);
#endif
	vsyslog(pri, fmt, ap);
}

static void say(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	say_at(LOG_NOTICE, fmt, ap);
	va_end(ap);
}

/* the same, loudly (LOG_ERR): the deadline */
static void shout(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	say_at(LOG_ERR, fmt, ap);
	va_end(ap);
}

/* a failure to start: the log file (stderr) as well as syslog */
static int start_failed(const char *what)
{
	fprintf(stderr, "linuxfs-mountd: %s: %s\n", what, strerror(errno));
	say("mountd: %s: %s", what, strerror(errno));
	return 1;
}

/* the test build's --status: stderr only, never syslog (it comes on every pass of the loop) */
static void status(void)
{
	if (lim.status)
		fprintf(stderr, "mountd: status slots %d queued %d\n", nkids, nqueued);
}

/* the reply V (mountd_reply) to C: never waiting in the parent (C is non-blocking there), and a peer that left is no harm
 * (SIGPIPE is ignored in the parent and the child) */
static void answer(int c, enum mountd_verdict v, int rc, const char *why)
{
	char buf[256];
	size_t n = mountd_reply(buf, sizeof(buf), v, rc, why);

	if (write(c, buf, n) < 0) {
		/* the peer is gone, or will read nothing: nothing to do */
	}
}

static int running(uid_t uid)
{
	int i, k = 0;

	for (i = 0; i < nkids; i++)
		k += kids[i].uid == uid;
	return k;
}

static int waiting(uid_t uid)
{
	int i, k = 0;

	for (i = 0; i < nqueued; i++)
		k += queue[i].uid == uid;
	return k;
}

#define UNKNOWN_PEER ((uid_t)-1)	/* the refusal log's key for a peer whose credential cannot be read */

/* 1 when a line about KEY (a uid, or UNKNOWN_PEER) may go to the log now: at most once per REFUSAL_EVERY_MS per key, with
 * the last REFUSALS keys remembered */
static int log_due(uid_t key)
{
	long long now = now_ms();
	int i, oldest = 0;

	for (i = 0; i < REFUSALS; i++) {
		if (refusals[i].at && refusals[i].uid == key)
			break;
		if (refusals[i].at < refusals[oldest].at)
			oldest = i;
	}
	if (i < REFUSALS && now - refusals[i].at < REFUSAL_EVERY_MS)
		return 0;
	if (i == REFUSALS)
		i = oldest;
	refusals[i].uid = key;
	refusals[i].at = now ? now : 1;
	return 1;
}

/* A refusal for a peer that is not served (UID, its reply V/RC/WHY): it takes no slot, and is logged at most once per
 * REFUSAL_EVERY_MS per uid. */
static void refuse(int c, uid_t uid, enum mountd_verdict v, int rc, const char *why)
{
	answer(c, v, rc, why);
	close(c);
	if (log_due(uid))
		say("mountd: refused uid %u: %s", (unsigned)uid, why);
}

/* /dev/console's owner, looked at each time: the helper's rule, so there is one definition of the console user (the test
 * build: --console, or --console-file read at each look) */
static uid_t console_uid(void)
{
	struct stat st;

#ifdef LINUXFS_MOUNTD_TEST
	if (console_file) {
		FILE *f = fopen(console_file, "r");
		unsigned u;
		int got = f && fscanf(f, "%u", &u) == 1;

		if (f)
			fclose(f);
		return got ? (uid_t)u : (uid_t)-1;
	}
#endif
	if (lim.console_given)
		return lim.console;
	return stat("/dev/console", &st) == 0 ? st.st_uid : (uid_t)-1;
}

/* ---- the child ---- */

/* The one request line from C into BUF (LEN bytes), under one MOUNTD_REQUEST bound in all (M4: not per read): its length,
 * up to and including its LF, or what came before EOF or before LEN filled (mountd_parse refuses those); -1 when the time
 * ran out. */
static ssize_t read_request(int c, char *buf, size_t len)
{
	long long deadline = now_ms() + MOUNTD_REQUEST * 1000LL, left;
	struct pollfd p = { c, POLLIN, 0 };
	size_t got = 0;
	ssize_t n;

	while (got < len && !memchr(buf, '\n', got)) {
		left = deadline - now_ms();
		if (left <= 0)
			return -1;
		n = poll(&p, 1, (int)left);
		if (n < 0 && errno == EINTR)
			continue;
		if (n == 0)
			return -1;
		if (n < 0)
			break;
		n = read(c, buf + got, len - got);
		if (n < 0 && (errno == EINTR || errno == EAGAIN))
			continue;
		if (n <= 0)
			break;
		got += (size_t)n;
	}
	return (ssize_t)got;
}

/* ---- the child's work (16i): describe, judge, adopt, spawn, reply ---- */

static int conn = -1;	/* the request's connection, for the pre-begin alarm */
static struct {
	const char *bsd, *mnt, *real;	/* the request's disk and mount point, and the mount point's path here */
	uid_t peer;
	long long da_ms;
	int adopted, mfd;	/* the mount point, adopted, on mfd */
	struct stat was;	/* its fstat before adoption */
} job;

/* Before begin (N2): nothing has been changed, so the mount program's own path is safe. A handler, since a blocked mach_msg
 * (DiskArbitration) is not reliably interrupted: the reply, then out, with a status the parent logs. */
static void too_slow(int sig)
{
	static const char r[] = "user\tthe daemon was too slow: your own mount\n";

	(void)sig;
	if (write(conn, r, sizeof r - 1) < 0) {
		/* the peer is gone: nothing to do */
	}
	_exit(TOO_SLOW_EXIT);	/* syslog is not safe here: the parent logs it (m2) */
}

static void give_back(int fd, const char *mnt, uid_t peer, const struct stat *was);
static int anything_on(const char *mnt);

/* The reply V/RC/WHY, the one result line to syslog, and the end of the child (the mount point's lock with it). A refused
 * request whose mount point was adopted gives it back when nothing is mounted on it (m5): the root path failed, the user's
 * path will not run, and the user must be able to reuse or remove it. */
static void __attribute__((noreturn)) finish(enum mountd_verdict v, int rc, const char *why)
{
	if (v != MD_MOUNT && job.adopted && anything_on(job.real) == 0)
		give_back(job.mfd, job.real, job.peer, &job.was);
	answer(conn, v, rc, why);
	if (v == MD_MOUNT)
		say("mountd: %s on %s: ok (peer %u, DA %lldms)", job.bsd, job.mnt, (unsigned)job.peer, job.da_ms);
	else if (v == MD_USER)
		say("mountd: %s on %s: user (peer %u, DA %lldms): %s", job.bsd, job.mnt, (unsigned)job.peer, job.da_ms, why);
	else
		say("mountd: %s on %s: no %d (peer %u, DA %lldms): %s", job.bsd, job.mnt, mountd_rc(rc), (unsigned)job.peer,
		    job.da_ms, why);
	_exit(0);
}

static const char *volumes_dir(void)
{
	const char *v = TEST_ENV("LINUXFS_MOUNTD_TEST_VOLUMES");

	return v && *v ? v : "/Volumes";
}

/* V (a CFString, CFBoolean, CFURL or CFNumber) as text into OUT (LEN bytes); "" when it is none of those or does not fit */
static void cf_text(CFTypeRef v, char *out, size_t len)
{
	long long n;

	out[0] = '\0';
	if (!v)
		return;
	if (CFGetTypeID(v) == CFStringGetTypeID()) {
		if (!CFStringGetCString((CFStringRef)v, out, (CFIndex)len, kCFStringEncodingUTF8))
			out[0] = '\0';
	} else if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
		snprintf(out, len, "%s", CFBooleanGetValue((CFBooleanRef)v) ? "true" : "false");
	} else if (CFGetTypeID(v) == CFURLGetTypeID()) {
		if (!CFURLGetFileSystemRepresentation((CFURLRef)v, true, (UInt8 *)out, (CFIndex)len))
			out[0] = '\0';
	} else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		if (CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &n))
			snprintf(out, len, "%lld", n);
	}
}

static int cf_true(CFDictionaryRef d, CFStringRef k)
{
	CFTypeRef v = CFDictionaryGetValue(d, k);

	return v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v);
}

/* S without trailing spaces (IOKit pads some device strings) */
static void trim(char *s)
{
	size_t n = strlen(s);

	while (n && s[n - 1] == ' ')
		s[--n] = '\0';
}

/* DiskArbitration's description of BSD into D (all but node_uid); with PRINT, each key it reads as KEY=VALUE on stdout
 * (the test build's --describe). removable is 1 always: DiskArbitration-266, 10.9's, probes with the literals "removable
 * readonly" (DAFileSystem.c, DAFileSystemProbe), so that is what the util saw (item-5-findings.md). 0, or -1 when
 * DiskArbitration does not know the disk. */
static int da_describe(const char *bsd, struct mountd_disk *d, int print)
{
	const CFStringRef keys[] = {
		kDADiskDescriptionMediaBSDNameKey, kDADiskDescriptionMediaLeafKey, kDADiskDescriptionMediaContentKey,
		kDADiskDescriptionMediaEjectableKey, kDADiskDescriptionMediaRemovableKey, kDADiskDescriptionDeviceModelKey,
		kDADiskDescriptionDeviceProtocolKey, kDADiskDescriptionVolumeKindKey, kDADiskDescriptionVolumePathKey,
	};
	DASessionRef s = DASessionCreate(kCFAllocatorDefault);
	DADiskRef disk = s ? DADiskCreateFromBSDName(kCFAllocatorDefault, s, bsd) : NULL;
	CFDictionaryRef desc = disk ? DADiskCopyDescription(disk) : NULL;
	char model[128], protocol[128];
	size_t i;

	if (desc && print)
		for (i = 0; i < sizeof keys / sizeof keys[0]; i++) {
			CFTypeRef v = CFDictionaryGetValue(desc, keys[i]);
			char k[64], t[1024];

			if (!v)
				continue;
			cf_text(keys[i], k, sizeof k);
			cf_text(v, t, sizeof t);
			printf("%s=%s\n", k, t);
		}
	if (desc) {
		cf_text(CFDictionaryGetValue(desc, kDADiskDescriptionMediaBSDNameKey), d->bsd, sizeof d->bsd);
		cf_text(CFDictionaryGetValue(desc, kDADiskDescriptionVolumeKindKey), d->kind, sizeof d->kind);
		cf_text(CFDictionaryGetValue(desc, kDADiskDescriptionMediaContentKey), d->content, sizeof d->content);
		d->has_path = CFDictionaryGetValue(desc, kDADiskDescriptionVolumePathKey) != NULL;
		d->leaf = cf_true(desc, kDADiskDescriptionMediaLeafKey);
		d->ejectable = cf_true(desc, kDADiskDescriptionMediaEjectableKey) || cf_true(desc, kDADiskDescriptionMediaRemovableKey);
		d->removable = 1;
		cf_text(CFDictionaryGetValue(desc, kDADiskDescriptionDeviceModelKey), model, sizeof model);
		cf_text(CFDictionaryGetValue(desc, kDADiskDescriptionDeviceProtocolKey), protocol, sizeof protocol);
		trim(model);
		trim(protocol);
		d->image = strcmp(model, "Disk Image") == 0 || strcmp(protocol, "Virtual Interface") == 0;
		CFRelease(desc);
	}
	if (disk)
		CFRelease(disk);
	if (s)
		CFRelease(s);
	return desc ? 0 : -1;
}

#ifdef LINUXFS_MOUNTD_TEST
/* The test build's DiskArbitration: FILE's key=value lines (bsd, kind, content, has_path, leaf, ejectable, image, node_uid;
 * the last of a key wins), BSD's unless it says otherwise; *NODE the node's owner it gives, or -1 */
static int da_test(const char *file, const char *bsd, struct mountd_disk *d, long *node)
{
	char line[256], *v;
	FILE *f = fopen(file, "r");

	if (!f)
		return -1;
	snprintf(d->bsd, sizeof d->bsd, "%s", bsd);
	while (fgets(line, sizeof line, f)) {
		line[strcspn(line, "\n")] = '\0';
		if (!(v = strchr(line, '=')))
			continue;
		*v++ = '\0';
		if (!strcmp(line, "bsd"))
			snprintf(d->bsd, sizeof d->bsd, "%s", v);
		else if (!strcmp(line, "kind"))
			snprintf(d->kind, sizeof d->kind, "%s", v);
		else if (!strcmp(line, "content"))
			snprintf(d->content, sizeof d->content, "%s", v);
		else if (!strcmp(line, "has_path"))
			d->has_path = atoi(v);
		else if (!strcmp(line, "leaf"))
			d->leaf = atoi(v);
		else if (!strcmp(line, "ejectable"))
			d->ejectable = atoi(v);
		else if (!strcmp(line, "image"))
			d->image = atoi(v);
		else if (!strcmp(line, "node_uid"))
			*node = atol(v);
	}
	fclose(f);
	d->removable = 1;
	return 0;
}
#endif

/* What DiskArbitration says of BSD, into D; *NODE a stand-in for the node's owner (the test build), or -1. 0 or -1. */
static int describe(const char *bsd, struct mountd_disk *d, long *node)
{
#ifdef LINUXFS_MOUNTD_TEST
	const char *s = getenv("LINUXFS_MOUNTD_TEST_DA_SLEEP");

	if (s)
		sleep((unsigned)atoi(s));
	if ((s = getenv("LINUXFS_MOUNTD_TEST_DA")) != NULL)
		return da_test(s, bsd, d, node);
#endif
	*node = -1;
	return da_describe(bsd, d, 0);
}

/* The mount table, as getmntinfo(MNT_NOWAIT) gives it (asking no file system, so nothing to bound): the number of entries, in
 * *m, or -1. The test build reads LINUXFS_MOUNTD_TEST_MNTTAB's TYPE<TAB>FROM<TAB>ON<TAB>OWNER lines instead, the last on top. */
static int mnt_table(struct statfs **m)
{
	int n;
#ifdef LINUXFS_MOUNTD_TEST
	const char *tab = getenv("LINUXFS_MOUNTD_TEST_MNTTAB");

	if (tab && *tab) {
		static struct statfs t[64];
		char line[3 * MAXPATHLEN + 64];
		FILE *f = fopen(tab, "r");

		if (!f)
			return -1;
		n = 0;
		while (n < (int)(sizeof t / sizeof t[0]) && fgets(line, sizeof line, f)) {
			char *a = line, *b, *c, *e;

			line[strcspn(line, "\n")] = '\0';
			if (!(b = strchr(a, '\t')) || !(c = strchr(b + 1, '\t')) || !(e = strchr(c + 1, '\t')))
				continue;
			*b++ = *c++ = *e++ = '\0';
			memset(&t[n], 0, sizeof t[n]);
			snprintf(t[n].f_fstypename, sizeof t[n].f_fstypename, "%s", a);
			snprintf(t[n].f_mntfromname, sizeof t[n].f_mntfromname, "%s", b);
			snprintf(t[n].f_mntonname, sizeof t[n].f_mntonname, "%s", c);
			t[n].f_owner = (uid_t)strtoul(e, NULL, 10);
			n++;
		}
		fclose(f);
		*m = t;
		return n;
	}
#endif
	n = getmntinfo(m, MNT_NOWAIT);
	return n > 0 ? n : -1;
}

/* Whether anything mounted refuses BSD (*from_disk: fsrules_mount_blocks, BSD itself or its whole disk, and for a whole disk any of
 * its partitions; a sibling partition never: final review r0 C1), and anything on MNT (*on_mnt), as root's mount program checks
 * (16f): 0, or -1 when the table cannot be read */
static int table_facts(const char *bsd, const char *mnt, int *from_disk, int *on_mnt)
{
	struct statfs *m;
	int n = mnt_table(&m), i;

	if (n < 0)
		return -1;
	for (i = 0; i < n; i++) {
		*from_disk |= fsrules_mount_blocks(m[i].f_mntfromname, bsd);
		*on_mnt |= strcmp(m[i].f_mntonname, mnt) == 0;
	}
	return 0;
}

/* Whether the topmost mount on MNT is root's own mount of FS from /dev/BSD */
static int topmost_is_roots(const char *fs, const char *bsd, const char *mnt)
{
	struct statfs *m;
	int n = mnt_table(&m), i;

	for (i = n - 1; i >= 0; i--)
		if (strcmp(m[i].f_mntonname, mnt) == 0)
			return fsrules_mount_is_roots(fs, bsd, m[i].f_fstypename, m[i].f_mntfromname, (unsigned)m[i].f_owner);
	return 0;
}

/* Whether anything is mounted on MNT: 1, 0, or -1 when the table cannot be read */
static int anything_on(const char *mnt)
{
	struct statfs *m;
	int n = mnt_table(&m), i;

	if (n < 0)
		return -1;
	for (i = 0; i < n; i++)
		if (strcmp(m[i].f_mntonname, mnt) == 0)
			return 1;
	return 0;
}

/* Whether the directory open on FD is empty (1), not (0), or cannot be read (-1). 10.9 has no fdopendir: the child stands in
 * the directory itself (fchdir, so a rename of MNT changes nothing) and reads ".", then goes back to /. One entry is
 * forgiven: a regular file (lstat, so never a symlink) named AUTODISKMOUNTED, which 10.9's diskarbitrationd leaves in each
 * mount point it makes (push F). Any other entry, or that name as anything but a regular file, is not empty. */
#define AUTODISKMOUNTED ".autodiskmounted"
static int dir_empty(int fd)
{
	struct dirent *e;
	struct stat st;
	DIR *dir;
	int n = -1;

	if (fchdir(fd) == 0 && (dir = opendir(".")) != NULL) {
		n = 1;
		while ((e = readdir(dir)) != NULL) {
			if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
				continue;
			if (strcmp(e->d_name, AUTODISKMOUNTED) == 0 && lstat(AUTODISKMOUNTED, &st) == 0 && S_ISREG(st.st_mode))
				continue;
			n = 0;
			break;
		}
		closedir(dir);
	}
	if (chdir("/") != 0)
		n = -1;
	return n;
}

/* MNT, open on FD and adopted, back to PEER with its group and mode before (WAS) (N9, m4); the test build says
 * "giveback MNT UID GID MODE" */
static void give_back(int fd, const char *mnt, uid_t peer, const struct stat *was)
{
#ifdef LINUXFS_MOUNTD_TEST
	(void)fd;
	fprintf(stderr, "giveback %s %u %u %o\n", mnt, (unsigned)peer, (unsigned)was->st_gid, (unsigned)(was->st_mode & 07777));
#else
	if (fchown(fd, peer, was->st_gid) != 0 || fchmod(fd, was->st_mode & 07777) != 0)
		say("mountd: %s: the mount point cannot be given back: %s", mnt, strerror(errno));
#endif
}

/* Adoption (M1, N9): MNT, open on FD and the peer's (WAS: its fstat before begin), becomes root's and 0755; then it must still
 * be the same directory, root's, 0755 and empty (mountd_adopted). 0; or -1 with *why, the directory given back to PEER with
 * its mode. The test build says "adopt MNT" instead of changing it, and takes its own uid for root's. */
static int adopt(int fd, const char *mnt, uid_t peer, const struct stat *was, const char **why)
{
	struct stat after, entry;
	int empty;

#ifdef LINUXFS_MOUNTD_TEST
	fprintf(stderr, "adopt %s\n", mnt);
	if (getenv("LINUXFS_MOUNTD_TEST_ADOPT_SWAP")) {
		char moved[PATH_MAX];

		snprintf(moved, sizeof moved, "%s.swapped", mnt);
		if (rename(mnt, moved) != 0 || mkdir(mnt, 0755) != 0)
			fprintf(stderr, "mountd: the swap failed: %s\n", strerror(errno));
	}
#else
	if (fchown(fd, 0, 0) != 0 || fchmod(fd, 0755) != 0) {
		say("mountd: %s: the mount point cannot be adopted: %s", mnt, strerror(errno));
		memset(&after, 0, sizeof after);
	}
#endif
	if (fstat(fd, &after) != 0)
		memset(&after, 0, sizeof after);
	if (lstat(mnt, &entry) != 0)
		memset(&entry, 0, sizeof entry);
	empty = dir_empty(fd) == 1;
#ifdef LINUXFS_MOUNTD_TEST
	if (after.st_uid == getuid())
		after.st_uid = 0;
#endif
	if (mountd_adopted(&after, &entry, empty, peer, why) == 0)
		return 0;
	give_back(fd, mnt, peer, was);
	return -1;
}

/* The bundle's mount program for R, on MNT, trusted (trust_path) and spawned in a process group of its own, with default
 * signals, no mask, 0-2 only (stdin /dev/null, stdout and stderr *OUT's pipe), PATH alone and the fixed argv. Its pid; -1
 * with *why. The test build runs LINUXFS_MOUNTD_TEST_PROGRAM's mount_macfuse_<fs>, trusted as the test user's. */
static pid_t spawn_program(const struct mountd_req *r, const char *mnt, int *out, struct timeval *since, const char **why)
{
	char prog[PATH_MAX], resolved[PATH_MAX], opts[64], dev[64];
	char *argv[6], *envp[] = { PROGRAM_PATH, NULL };
	const char *dir = TEST_ENV("LINUXFS_MOUNTD_TEST_PROGRAM"), *trust_root = NULL;
	uid_t owner = 0;
	posix_spawn_file_actions_t fa;
	posix_spawnattr_t at;
	sigset_t def, none;
	pid_t pid;
	int pp[2], e;

	if (dir) {
		snprintf(prog, sizeof prog, "%s/mount_macfuse_%s", dir, r->fs);
		owner = getuid();
		trust_root = dir;
	} else {
		snprintf(prog, sizeof prog, PROGRAM_FMT, r->fs, r->fs);
	}
	if (trust_path(prog, owner, trust_root, resolved, sizeof resolved) != 0) {
		*why = "the mount program is not root's alone";
		return -1;
	}
	snprintf(opts, sizeof opts, "nodev,nosuid,%s%s", r->owners ? "owners" : "noowners", r->ro ? ",rdonly" : "");
	snprintf(dev, sizeof dev, "/dev/%s", r->bsd);
	argv[0] = resolved;
	argv[1] = "-o";
	argv[2] = opts;
	argv[3] = dev;
	argv[4] = (char *)mnt;
	argv[5] = NULL;
	if (pipe(pp) != 0) {
		*why = "cannot make the mount program's pipe";
		return -1;
	}
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_adddup2(&fa, pp[1], 1);
	posix_spawn_file_actions_adddup2(&fa, pp[1], 2);
	posix_spawnattr_init(&at);
	posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK |
				 POSIX_SPAWN_CLOEXEC_DEFAULT);
	posix_spawnattr_setpgroup(&at, 0);
	sigemptyset(&def);
	sigaddset(&def, SIGPIPE);
	sigaddset(&def, SIGCHLD);
	sigaddset(&def, SIGALRM);
	sigaddset(&def, SIGTERM);
	posix_spawnattr_setsigdefault(&at, &def);
	sigemptyset(&none);
	posix_spawnattr_setsigmask(&at, &none);
	gettimeofday(since, NULL);	/* the CLI's group starts after this (I1) */
	e = posix_spawn(&pid, resolved, &fa, &at, argv, envp);
	posix_spawn_file_actions_destroy(&fa);
	posix_spawnattr_destroy(&at);
	close(pp[1]);
	if (e != 0) {
		close(pp[0]);
		say("mountd: %s: posix_spawn: %s", resolved, strerror(e));
		*why = "the mount program cannot be run";
		return -1;
	}
	*out = pp[0];
	return pid;
}

/* The uid the CLI and lklfuse run as: _linuxfs's (the test build: LINUXFS_MOUNTD_TEST_RUNAS), or 0 for none */
static uid_t run_as(void)
{
	const char *t = TEST_ENV("LINUXFS_MOUNTD_TEST_RUNAS");
	struct passwd *pw;

	if (t)
		return (uid_t)strtoul(t, NULL, 10);
	pw = getpwnam(RUN_USER);
	return pw ? pw->pw_uid : 0;
}

/* PID as the group kill sees it, into P: 0, or -1 when it is gone. The test build reads LINUXFS_MOUNTD_TEST_PROCTAB's
 * "pid ppid pgid uid sec usec" lines instead, at each look. */
#ifdef LINUXFS_MOUNTD_TEST
static int proctab(struct mountd_proc *p, int max, pid_t pid, pid_t pgid)
{
	FILE *f = fopen(getenv("LINUXFS_MOUNTD_TEST_PROCTAB"), "r");
	struct mountd_proc x;
	long a, b, c;
	unsigned long u;
	int k = 0;

	if (!f)
		return 0;
	while (k < max && fscanf(f, "%ld %ld %ld %lu %llu %llu", &a, &b, &c, &u, &x.sec, &x.usec) == 6) {
		x.pid = (pid_t)a;
		x.ppid = (pid_t)b;
		x.pgid = (pid_t)c;
		x.uid = (uid_t)u;
		if ((pid && x.pid == pid) || (pgid && x.pgid == pgid))
			p[k++] = x;
	}
	fclose(f);
	return k;
}
#endif

static int proc_facts(pid_t pid, struct mountd_proc *p)
{
	struct proc_bsdinfo bi;

#ifdef LINUXFS_MOUNTD_TEST
	if (getenv("LINUXFS_MOUNTD_TEST_PROCTAB"))
		return proctab(p, 1, pid, 0) == 1 ? 0 : -1;
#endif
	if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi)
		return -1;
	p->pid = pid;
	p->ppid = (pid_t)bi.pbi_ppid;
	p->pgid = (pid_t)bi.pbi_pgid;
	p->uid = bi.pbi_uid;
	p->sec = bi.pbi_start_tvsec;
	p->usec = bi.pbi_start_tvusec;
	return 0;
}

/* Process group PGID's members as they are now, into P (at most MAX): how many */
static int list_group(pid_t pgid, struct mountd_proc *p, int max)
{
	static pid_t pids[1024];
	int n, i, k = 0;

#ifdef LINUXFS_MOUNTD_TEST
	if (getenv("LINUXFS_MOUNTD_TEST_PROCTAB"))
		return proctab(p, max, 0, pgid);
#endif
	n = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, pids, sizeof pids);
	for (i = 0; n > 0 && i < n / (int)sizeof(pid_t) && k < max; i++)
		if (pids[i] > 0 && proc_facts(pids[i], &p[k]) == 0)
			k++;
	return k;
}

/* SIGKILL to each member of the snapshot still itself (mountd_still_ours); the test build with a process table says
 * "kill PID" instead. How many. */
static int kill_snapshot(const struct mountd_snap *s)
{
	struct mountd_proc now;
	int i, k = 0;

	for (i = 0; i < s->n; i++) {
		if (proc_facts(s->m[i].pid, &now) != 0 || !mountd_still_ours(&s->m[i], &now, s->runas))
			continue;
#ifdef LINUXFS_MOUNTD_TEST
		if (getenv("LINUXFS_MOUNTD_TEST_PROCTAB")) {
			fprintf(stderr, "kill %d\n", (int)s->m[i].pid);
			k++;
			continue;
		}
#endif
		if (kill(s->m[i].pid, SIGKILL) == 0)
			k++;
	}
	return k;
}

/* The program's output, as it comes: the first OUTPUT_LOGGED bytes to syslog, a line at a time, and the first "cli-pgid N"
 * line's N into *cli (N5). Lines past LINE_MAX bytes are cut. */
struct output { char line[1024]; size_t len, logged; int cut; pid_t cli; const char *name; };

static void output_line(struct output *o)
{
	char *end;
	long n;

	o->line[o->len] = '\0';
	if (o->logged < OUTPUT_LOGGED)
		say("mountd: %s: %s", o->name, o->line);
	o->logged += o->len + 1;
	if (!o->cli && !o->cut && strncmp(o->line, "cli-pgid ", 9) == 0) {
		n = strtol(o->line + 9, &end, 10);
		if (end != o->line + 9 && !*end && n > 1 && n < INT_MAX)
			o->cli = (pid_t)n;
	}
	o->len = 0;
	o->cut = 0;
}

static void output_take(struct output *o, const char *buf, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++) {
		if (buf[i] == '\n') {
			output_line(o);
		} else if (o->len < sizeof o->line - 1) {
			o->line[o->len++] = buf[i];
		} else {
			o->cut = 1;
		}
	}
}

/* Before any no after the program ran: root's mount of the disk left on MNT (topmost, fsrules_mount_is_roots) is unmounted, so a no
 * never stands beside an orphaned mount nobody would own (16j findings I1: a program SIGTERMed or SIGKILLed after its mount landed,
 * or one that failed without undoing it). The disk's lock and MNT's flock keep any other request's mount off MNT. The test build
 * says "unmount MNT" instead. */
static void undo_orphan(const struct mountd_req *r, const char *mnt)
{
	if (!topmost_is_roots(r->fs, r->bsd, mnt))
		return;
#ifdef LINUXFS_MOUNTD_TEST
	fprintf(stderr, "unmount %s\n", mnt);
#else
	if (unmount(mnt, MNT_FORCE) == 0)
		shout("mountd: %s on %s: root's mount was left there: unmounted", r->bsd, r->mnt);
	else
		shout("mountd: %s on %s: root's mount was left there and cannot be unmounted: %s", r->bsd, r->mnt, strerror(errno));
#endif
}

static void __attribute__((noreturn)) refuse_after(const struct mountd_req *r, const char *mnt, int rc, const char *why)
{
	undo_orphan(r, mnt);
	finish(MD_REFUSE, rc, why);
}

/* The mount program PID, its output on OUT, to the end or the deadline (I4): a timed loop of poll and waitpid. At
 * lim.deadline, SIGTERM to the program (the root path cleans up); lim.grace later, SIGKILL to its process group and to the
 * snapshot of the CLI's group (N5, R1, I1: mountd_snap_refresh, once a second, members since SINCE), and "deadline". Then the
 * reply. */
static void await(const struct mountd_req *r, const char *mnt, pid_t pid, int out, dev_t rdev, const struct timeval *since)
{
	static struct mountd_snap snap;
	static struct mountd_proc now[MOUNTD_SNAP_MAX];
	struct output o;
	struct stat node;
	char buf[16384], path[64];
	long long start = now_ms(), t, next_snap = 0, term_at = -1, next, wait;
	uid_t runas = run_as();
	int st = 0, killed;
	ssize_t n;
	int i;

	memset(&o, 0, sizeof o);
	o.name = r->fs;
	for (;;) {
		if (waitpid(pid, &st, WNOHANG) == pid)
			break;
		t = now_ms();
		if (o.cli && runas != 0 && t >= next_snap) {
			if (!next_snap)
				mountd_snap_init(&snap, o.cli, runas, (unsigned long long)since->tv_sec,
						 (unsigned long long)since->tv_usec);
			mountd_snap_refresh(&snap, now, list_group(o.cli, now, MOUNTD_SNAP_MAX));
			next_snap = t + 1000;
		}
		if (term_at < 0 && t - start >= lim.deadline * 1000LL) {
			shout("mountd: %s on %s: the mount program passed its %d s: SIGTERM", r->bsd, r->mnt, lim.deadline);
			kill(pid, SIGTERM);
			term_at = t;
		}
		if (term_at >= 0 && t - term_at >= lim.grace * 1000LL) {
			kill(-pid, SIGKILL);
			killed = o.cli && next_snap ? kill_snapshot(&snap) : 0;
			shout("mountd: %s on %s: still running %d s later: SIGKILL to its group %d and to %d of the CLI's group %d",
			      r->bsd, r->mnt, lim.grace, (int)pid, killed, (int)o.cli);
			for (i = 0; i < 10 && waitpid(pid, &st, WNOHANG) == 0; i++)
				usleep(100000);	/* reaped, when it goes at once; else launchd reaps it */
			refuse_after(r, mnt, 1, "deadline");
		}
		next = term_at < 0 ? start + lim.deadline * 1000LL : term_at + lim.grace * 1000LL;
		if (o.cli && runas != 0 && next_snap < next)
			next = next_snap;
		wait = next - t;
		if (wait > 100)
			wait = 100;	/* the program's exit: SIGCHLD is not caught, so look often */
		if (wait < 0)
			wait = 0;
		if (out >= 0) {
			struct pollfd p = { out, POLLIN, 0 };

			if (poll(&p, 1, (int)wait) > 0) {
				n = read(out, buf, sizeof buf);
				if (n > 0) {
					output_take(&o, buf, (size_t)n);
				} else if (n == 0 || (errno != EINTR && errno != EAGAIN)) {
					close(out);
					out = -1;
				}
			}
		} else {
			usleep((useconds_t)wait * 1000);
		}
	}
	/* what is left in the pipe now; its writers may outlive the program (mount_macfuse keeps 0-2) */
	if (out >= 0) {
		fcntl(out, F_SETFL, fcntl(out, F_GETFL) | O_NONBLOCK);
		while ((n = read(out, buf, sizeof buf)) > 0)
			output_take(&o, buf, (size_t)n);
		close(out);
	}
	if (o.len)
		output_line(&o);
	/* after SIGTERM, an exit 0 is judged as any other (the program holds SIGTERM once its mount is decided: 16j findings I1); any
	 * other end is the deadline's no, with root's mount, if left, unmounted first */
	if (term_at >= 0) {
		shout("mountd: %s on %s: the mount program ended after SIGTERM (%s)", r->bsd, r->mnt,
		      WIFEXITED(st) && WEXITSTATUS(st) == 0 ? "exit 0" : "failed");
		if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
			refuse_after(r, mnt, 1, "deadline");
	}
	if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
		refuse_after(r, mnt, WIFEXITED(st) ? WEXITSTATUS(st) : 1, "the mount program failed");
	if (!topmost_is_roots(r->fs, r->bsd, mnt))
		finish(MD_REFUSE, 1, "root's mount of the disk is not on the mount point");
	snprintf(path, sizeof path, "/dev/%s", r->bsd);
	if (stat(path, &node) != 0)
		refuse_after(r, mnt, 1, "the disk is gone");
#ifdef LINUXFS_MOUNTD_TEST
	if (getenv("LINUXFS_MOUNTD_TEST_RDEV_SHIFT"))
		node.st_rdev += atoi(getenv("LINUXFS_MOUNTD_TEST_RDEV_SHIFT"));
#endif
	if (node.st_rdev != rdev)
		refuse_after(r, mnt, 1, "another disk has the disk's name now");
	finish(MD_MOUNT, 0, "");
}

/* One parsed request R from PEER on C: the spec's §1, in order. Before begin nothing is changed, and SIGALRM's handler
 * answers "user" (too slow) if DiskArbitration (DA_WAIT s) or the rest (MOUNTD_PREBEGIN in all) takes too long. */
static void work(int c, uid_t peer, const struct mountd_req *r)
{
	struct sigaction sa;
	struct mountd_disk d;
	struct stat node, opened, entry, vols;
	struct fsprefs p;
	char path[64], whole[40], mnt[PATH_MAX], label[256];
	const char *type = NULL, *why;
	long long t0;
	long node_given = -1;
	int fd, mfd, rc, err = 0, from_disk = 0, on_mnt = 0, adopting = 0, empty, out = -1;
	unsigned flags = 0;
	enum mountd_verdict v;
	struct timeval since;
	pid_t pid;

	conn = c;
	job.bsd = r->bsd;
	job.mnt = r->mnt;
	job.peer = peer;
	job.da_ms = -1;
	job.mfd = -1;
	while ((fd = open("/dev/null", O_RDWR)) >= 0 && fd < 3)
		;	/* 0-2 open, so no pipe or descriptor below takes their place */
	if (fd >= 3)
		close(fd);
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = too_slow;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGALRM, &sa, NULL);

	/* 1. DiskArbitration, under its own bound (M6) */
	memset(&d, 0, sizeof d);
	alarm(DA_WAIT);
	t0 = now_ms();
	if (describe(r->bsd, &d, &node_given) != 0) {
		job.da_ms = now_ms() - t0;
		finish(MD_REFUSE, 1, "DiskArbitration does not know the disk");
	}
	job.da_ms = now_ms() - t0;
	alarm(MOUNTD_PREBEGIN - DA_WAIT);

	/* 2. the node (its owner, and its device, kept: M8) and the mount table */
	snprintf(path, sizeof path, "/dev/%s", r->bsd);
	if (stat(path, &node) != 0 || !S_ISBLK(node.st_mode))
		finish(MD_REFUSE, 1, "the disk's node cannot be read");
	d.node_uid = node_given >= 0 ? (uid_t)node_given : node.st_uid;
	if (!fsrules_whole_disk(r->bsd, whole, sizeof whole) ||
	    snprintf(mnt, sizeof mnt, "%s/%s", volumes_dir(), r->mnt + strlen(VOLUMES)) >= (int)sizeof mnt)
		finish(MD_REFUSE, 1, "not a BSD disk name");
	if (table_facts(r->bsd, mnt, &from_disk, &on_mnt) != 0)
		finish(MD_REFUSE, 1, "the mount table cannot be read");

	/* 3. the probe (a superblock), the console user's preferences, the verdict */
	snprintf(path, sizeof path, "/dev/r%s", r->bsd);
	if ((fd = open(path, O_RDONLY | O_NOCTTY)) >= 0) {
		struct stat rs;

		if (fstat(fd, &rs) == 0 && S_ISCHR(rs.st_mode) &&
		    (type = linuxfs_probe_fd(fd, label, sizeof label, &err)) != NULL)
			flags = fsrules_probe_flags(linuxfs_probe_extra(), linuxfs_probe_flags());
		close(fd);
	}
	prefs_read(&p);
	/* m6: the preferences are the console user's now; they must be the peer's */
	if (console_uid() != peer)
		finish(MD_USER, 0, "the console changed: your own mount");
	v = mountd_judge(r, &d, peer, type, flags, &p, from_disk, on_mnt, &rc, &why);
	if (v != MD_MOUNT)
		finish(v, rc, why);

	/* 4. the mount point: opened without following a symlink, locked for the request's life (M10), then judged */
	mfd = open(mnt, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK | O_NOCTTY);
	if (mfd < 0)
		finish(MD_REFUSE, 1, "the mount point is missing, a symlink or not a directory");
	if (flock(mfd, LOCK_EX | LOCK_NB) != 0)
		finish(MD_REFUSE, 1, errno == EWOULDBLOCK ? "another mount on the mount point is under way"
							  : "the mount point cannot be locked");
	if (fstat(mfd, &opened) != 0 || lstat(mnt, &entry) != 0 || stat(volumes_dir(), &vols) != 0 ||
	    (empty = dir_empty(mfd)) < 0)
		finish(MD_REFUSE, 1, "the mount point cannot be read");
	if (mountd_mnt_facts(&opened, &entry, &vols, empty, peer, &adopting, &why) != 0)
		finish(MD_REFUSE, 1, why);

	/* 5. begin (I5): nothing above changed anything; what follows may. No alarm from here: the deadline is await's. */
	alarm(0);
	signal(SIGALRM, SIG_IGN);
	if (write(c, "begin\n", 6) != 6) {
		say("mountd: %s on %s: the peer left before begin", r->bsd, r->mnt);
		_exit(0);
	}

	/* 6. adoption, when the mount point is the peer's (given back on any refusal from here with nothing on it: finish) */
	if (adopting && adopt(mfd, mnt, peer, &opened, &why) != 0)
		finish(MD_REFUSE, 1, why);
	job.real = mnt;
	job.mfd = mfd;
	job.was = opened;
	job.adopted = adopting;

	/* 7. the bundle's mount program */
	if ((pid = spawn_program(r, mnt, &out, &since, &why)) < 0)
		finish(MD_REFUSE, 1, why);

	/* 8, 9. the deadline, and the reply */
	await(r, mnt, pid, out, node.st_rdev, &since);
}

/* One request from the console user UID on C, in a forked child. */
static void serve(int c, uid_t uid)
{
	char buf[MOUNTD_REQ_MAX + 1];	/* one byte more than a request may have, so a longer one is seen as such */
	struct mountd_req r;
	const char *why;
	sigset_t none;
	ssize_t n;
	int fd, top = getdtablesize();

	/* hygiene (M5): nothing of the parent's but C and 0-2; default signals and no mask. SIGALRM is left as it is: the
	 * work (16i) gives it a handler before begin (N2). */
	closelog();	/* its socket is closed below, and a descriptor the work opens must never be taken for it */
	for (fd = 3; fd < top; fd++)
		if (fd != c)
			close(fd);
	openlog(IDENT, LOG_PID, FACILITY);	/* m4: the parent's ident and facility, not libc's defaults */
	signal(SIGCHLD, SIG_DFL);
	/* m3: a peer that left is EPIPE, never a death before the result line. Ignored rather than SO_NOSIGPIPE alone: XNU
	 * refuses socket options (EINVAL) once the peer has shut the socket both ways, which is just when it matters. The
	 * mount program still gets SIGPIPE's default (posix_spawn's SETSIGDEF). */
	signal(SIGPIPE, SIG_IGN);
	signal(SIGTERM, SIG_DFL);
	sigemptyset(&none);
	sigprocmask(SIG_SETMASK, &none, NULL);
	fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK);

	n = read_request(c, buf, sizeof(buf));
	if (n < 0) {
		say("mountd: uid %u sent no request within %d s", (unsigned)uid, MOUNTD_REQUEST);
		_exit(0);
	}
	switch (mountd_parse(buf, (size_t)n, &r, &why)) {
	case 0:
		break;
	case 1:
		say("mountd: uid %u: %s on %s: user: %s", (unsigned)uid, r.bsd, r.mnt, why);
		answer(c, MD_USER, 0, why);
		_exit(0);
	default:
		say("mountd: uid %u: a bad request: %s", (unsigned)uid, why);
		answer(c, MD_REFUSE, 1, why);
		_exit(0);
	}
	say("mountd: request from uid %u: %s %s on %s", (unsigned)uid, r.fs, r.bsd, r.mnt);
#ifdef LINUXFS_MOUNTD_TEST
	/* the front door's tests: with no stand-in program, a stub child that sleeps, then replies "user not yet" */
	if (!getenv("LINUXFS_MOUNTD_TEST_PROGRAM")) {
		if (getenv("LINUXFS_MOUNTD_TEST_CHILD_SLEEP"))
			sleep((unsigned)atoi(getenv("LINUXFS_MOUNTD_TEST_CHILD_SLEEP")));
		answer(c, MD_USER, 0, "not yet");
		_exit(0);
	}
#endif
	work(c, uid, &r);
}

/* ---- the parent ---- */

/* A child for C (from UID); C is closed in the parent either way. */
static void start_child(int c, uid_t uid)
{
	pid_t pid = fork();

	if (pid == 0)
		serve(c, uid);
	if (pid < 0) {
		say("mountd: fork: %s", strerror(errno));
		answer(c, MD_USER, 0, "busy");
	} else {
		kids[nkids].pid = pid;
		kids[nkids].uid = uid;
		nkids++;
	}
	close(c);
}

/* Children that ended free their slots. */
static void reap(void)
{
	pid_t pid;
	int i, st;

	child_ended = 0;
	while ((pid = waitpid(-1, &st, WNOHANG)) > 0)
		for (i = 0; i < nkids; i++)
			if (kids[i].pid == pid) {
				/* m2: its SIGALRM handler could not log; its request line (LOG_PID) names the disk */
				if (WIFEXITED(st) && WEXITSTATUS(st) == TOO_SLOW_EXIT)
					say("mountd: child %d (uid %u): too slow (before begin)", (int)pid, (unsigned)kids[i].uid);
				kids[i] = kids[--nkids];
				break;
			}
}

static void unqueue(int i)
{
	memmove(&queue[i], &queue[i + 1], (size_t)(nqueued - i - 1) * sizeof(queue[0]));
	nqueued--;
}

/* The queue, first in, first out, into the slots that are free; then any request queued past lim.queue_wait gets busy. */
static void dispatch(void)
{
	long long now = now_ms();
	int i;

	uid_t console = console_uid();

	for (i = 0; i < nqueued && nkids < lim.slots;)
		if (mountd_peer(queue[i].uid, console) != MP_SERVE) {
			/* m2: the console changed while it waited (a fast user switch): its own path, and no child */
			int c = queue[i].fd;
			uid_t uid = queue[i].uid;

			unqueue(i);
			refuse(c, uid, MD_USER, 0, "not the user at the console");
		} else if (running(queue[i].uid) < lim.slots_uid) {
			int c = queue[i].fd;
			uid_t uid = queue[i].uid;

			unqueue(i);
			start_child(c, uid);
		} else {
			i++;
		}
	for (i = 0; i < nqueued;)
		if (now - queue[i].since >= lim.queue_wait * 1000LL) {
			say("mountd: uid %u waited %d s for a slot: busy", (unsigned)queue[i].uid, lim.queue_wait);
			answer(queue[i].fd, MD_USER, 0, "busy");
			close(queue[i].fd);
			unqueue(i);
		} else {
			i++;
		}
}

/* C's peer's credential into XU: NULL, or why not (errno's text, taken where it failed) */
static const char *peer_cred(int c, struct xucred *xu)
{
	socklen_t len = sizeof(*xu);

#ifdef LINUXFS_MOUNTD_TEST
	if (getenv("LINUXFS_MOUNTD_TEST_CRED_FAIL"))
		return strerror(EINVAL);
#endif
	if (getsockopt(c, SOL_LOCAL, LOCAL_PEERCRED, xu, &len) != 0)
		return strerror(errno);
	if (len != sizeof(*xu) || xu->cr_version != XUCRED_VERSION)
		return "an unknown credential version";
#ifdef LINUXFS_MOUNTD_TEST
	if (foreign_pgid > 0) {
		pid_t pid;

		len = sizeof(pid);
		if (getsockopt(c, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 && getpgid(pid) == foreign_pgid)
			xu->cr_uid = (uid_t)-2;
	}
#endif
	return NULL;
}

/* One accepted connection: the peer first (I3), before any slot is counted. */
static void arrive(int c)
{
	struct xucred xu;
	char groups[NGROUPS * 12] = "";
	const char *why;
	size_t at = 0;
	int i;

	fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK);
	{
		int one = 1;	/* the socket's own guard as well (m3); it fails only on a peer already gone */

		setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
	}
	if ((why = peer_cred(c, &xu)) != NULL) {
		/* no reply: no hi, so the mount program takes its own path */
		close(c);
		if (log_due(UNKNOWN_PEER))
			say("mountd: a peer's credential cannot be read: %s", why);
		return;
	}
	switch (mountd_peer(xu.cr_uid, console_uid())) {
	case MP_USER:
		refuse(c, xu.cr_uid, MD_USER, 0, "not the user at the console");
		return;
	case MP_ROOT:
		refuse(c, xu.cr_uid, MD_REFUSE, 1, "root mounts by itself");
		return;
	case MP_SERVE:
		break;
	}
	if (write(c, "hi\n", 3) != 3) {
		close(c);
		return;
	}
	for (i = 0; i < xu.cr_ngroups && i < NGROUPS; i++)
		at += (size_t)snprintf(groups + at, sizeof(groups) - at, "%s%u", i ? "," : "", (unsigned)xu.cr_groups[i]);
	say("mountd: peer uid %u groups %s", (unsigned)xu.cr_uid, groups);
	if (nqueued == 0 && running(xu.cr_uid) < lim.slots_uid && nkids < lim.slots) {
		start_child(c, xu.cr_uid);
	} else if (waiting(xu.cr_uid) < lim.queue && nqueued < QUEUE_MAX) {
		queue[nqueued].fd = c;
		queue[nqueued].uid = xu.cr_uid;
		queue[nqueued].since = now_ms();
		nqueued++;
		dispatch();
	} else {
		say("mountd: uid %u: the queue is full: busy", (unsigned)xu.cr_uid);
		answer(c, MD_USER, 0, "busy");
		close(c);
	}
}

/* launchd's listener for this job (Sockets, Listener), or -1 */
static int check_in(void)
{
	launch_data_t req = launch_data_new_string(LAUNCH_KEY_CHECKIN), resp, socks, fds, fd;
	int s = -1;

	resp = launch_msg(req);
	launch_data_free(req);
	if (resp && launch_data_get_type(resp) == LAUNCH_DATA_DICTIONARY &&
	    (socks = launch_data_dict_lookup(resp, LAUNCH_JOBKEY_SOCKETS)) &&
	    (fds = launch_data_dict_lookup(socks, LISTENER)) && launch_data_get_type(fds) == LAUNCH_DATA_ARRAY &&
	    launch_data_array_get_count(fds) >= 1 && (fd = launch_data_array_get_index(fds, 0)) &&
	    launch_data_get_type(fd) == LAUNCH_DATA_FD)
		s = launch_data_get_fd(fd);
	/* resp is kept: the listener is its, for the daemon's life */
	if (s < 0 && resp)
		errno = ENOENT;
	return s;
}

#ifdef LINUXFS_MOUNTD_TEST
/* --describe BSD: the fields the daemon reads from DiskArbitration, as KEY=VALUE lines, read as the daemon reads them: in a
 * child forked from a parent that has used syslog (M6, m5). 0, or 1 when DiskArbitration does not know BSD. */
static int describe_main(const char *bsd)
{
	struct mountd_disk d;
	pid_t pid;
	int st;

	say("mountd: describe %s", bsd);
	fflush(stdout);
	if ((pid = fork()) == 0) {
		alarm(DA_WAIT);
		memset(&d, 0, sizeof d);
		st = da_describe(bsd, &d, 1);
		fflush(stdout);
		_exit(st == 0 ? 0 : 1);
	}
	if (pid < 0 || waitpid(pid, &st, 0) != pid)
		return 1;
	return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}

/* the test build's own socket at PATH, or -1 */
static int bind_test(const char *path)
{
	struct sockaddr_un sa = { 0 };
	int s = socket(AF_UNIX, SOCK_STREAM, 0);

	sa.sun_family = AF_UNIX;
	if (s < 0 || strlen(path) >= sizeof(sa.sun_path))
		return -1;
	strcpy(sa.sun_path, path);
	unlink(path);
	if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) < 0 || chmod(path, 0666) < 0 || listen(s, 64) < 0)
		return -1;
	return s;
}

/* a whole number of at least MIN from S, or -1 */
static int number(const char *s, int min)
{
	char *end;
	long v = strtol(s, &end, 10);

	return *s && !*end && v >= min && v <= 1000000 ? (int)v : -1;
}
#endif

int main(int argc, char **argv)
{
	struct sigaction sa = { 0 };
	struct pollfd p;
	long long idle_since = now_ms(), wait, t;
	int s, c, i, k;
#ifdef LINUXFS_MOUNTD_TEST
	const char *path = NULL;
	int console = -1, pgid = 0;
#endif

	openlog(IDENT, LOG_PID, FACILITY);
#ifdef LINUXFS_MOUNTD_TEST
	if (argc == 3 && strcmp(argv[1], "--describe") == 0)
		return describe_main(argv[2]);
	for (i = 1; i < argc; i++) {
		int *to = NULL, min = 1, v;

		if (strcmp(argv[i], "--status") == 0) {
			lim.status = 1;
			continue;
		}
		if (i + 1 < argc && strcmp(argv[i], "--socket") == 0) {
			path = argv[++i];
			continue;
		}
		if (i + 1 < argc && strcmp(argv[i], "--console-file") == 0) {
			console_file = argv[++i];
			continue;
		}
		if (strcmp(argv[i], "--console") == 0)
			to = &console, min = 0;
		else if (strcmp(argv[i], "--foreign-pgid") == 0)
			to = &pgid;
		else if (strcmp(argv[i], "--idle") == 0)
			to = &lim.idle;
		else if (strcmp(argv[i], "--max-uid") == 0)
			to = &lim.slots_uid;
		else if (strcmp(argv[i], "--max") == 0)
			to = &lim.slots;
		else if (strcmp(argv[i], "--queue") == 0)
			to = &lim.queue, min = 0;
		else if (strcmp(argv[i], "--queue-wait") == 0)
			to = &lim.queue_wait;
		else if (strcmp(argv[i], "--deadline") == 0)
			to = &lim.deadline;
		else if (strcmp(argv[i], "--grace") == 0)
			to = &lim.grace;
		if (!to || i + 1 >= argc || (v = number(argv[++i], min)) < 0) {
			fprintf(stderr, "usage: linuxfs-mountd [--socket PATH] [--console UID | --console-file PATH] "
					"[--foreign-pgid PGID] [--idle S] [--max-uid N] [--max N] [--queue N] [--queue-wait S] "
					"[--deadline S] [--grace S] [--status] | --describe BSD\n");
			return 2;
		}
		*to = v;
	}
	foreign_pgid = (pid_t)pgid;
	if (console >= 0)
		lim.console = (uid_t)console, lim.console_given = 1;
	if (lim.slots > CHILDREN_MAX)
		lim.slots = CHILDREN_MAX;
	s = path ? bind_test(path) : check_in();
#else
	(void)argv;
	if (argc != 1) {
		fprintf(stderr, "usage: linuxfs-mountd (launchd runs it, as dev.mavergreen.linuxfs.mountd)\n");
		return 2;
	}
	s = check_in();
#endif
	if (s < 0)
		return start_failed("no listener from launchd");
	fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK);
	signal(SIGPIPE, SIG_IGN);	/* a peer that left never kills the parent on hi */
	sa.sa_handler = on_child;
	sa.sa_flags = SA_NOCLDSTOP;	/* no SA_RESTART: poll wakes */
	sigaction(SIGCHLD, &sa, NULL);
	sa.sa_handler = on_term;
	sa.sa_flags = 0;
	sigaction(SIGTERM, &sa, NULL);
	for (;;) {
		reap();
		dispatch();
		status();
		if (stopping)
			break;
		t = now_ms();
		wait = 1000;	/* at most: the flags are seen within a second even if a signal came just before poll */
		if (nkids || nqueued)
			idle_since = t;
		else if (t - idle_since >= lim.idle * 1000LL)
			return 0;
		else if (idle_since + lim.idle * 1000LL - t < wait)
			wait = idle_since + lim.idle * 1000LL - t;
		for (i = 0; i < nqueued; i++)
			if (queue[i].since + lim.queue_wait * 1000LL - t < wait)
				wait = queue[i].since + lim.queue_wait * 1000LL - t;
		p.fd = s;
		p.events = POLLIN;
		if (poll(&p, 1, wait < 0 ? 0 : (int)wait) <= 0)
			continue;
		/* I1: a bounded batch, then back to the top (reap, dispatch, SIGTERM, idle), so a flood of connections from
		 * any uid cannot hold the parent here */
		for (k = 0; k < ACCEPT_BATCH && (c = accept(s, NULL, NULL)) >= 0; k++)
			arrive(c);
#ifdef LINUXFS_MOUNTD_TEST
		if (lim.status && k)
			fprintf(stderr, "mountd: status took %d\n", k);
#endif
		if (k < ACCEPT_BATCH && (errno == EMFILE || errno == ENFILE))
			usleep(100000);	/* out of descriptors: let children end, rather than spin */
	}
	/* stopping (launchd's SIGTERM): the queue is told to take its own path; children finish their own requests */
	for (i = 0; i < nqueued; i++) {
		answer(queue[i].fd, MD_USER, 0, "the daemon is stopping");
		close(queue[i].fd);
	}
	return 0;
}
#endif
