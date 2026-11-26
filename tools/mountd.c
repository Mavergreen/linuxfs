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
 * The child reads the one request line within MOUNTD_REQUEST seconds in all, and parses it (mountd_parse). It exits 0 after
 * MOUNTD_IDLE seconds with no child and nothing queued, and on SIGTERM (whose handler only sets a flag). The socket
 * (/var/run/dev.mavergreen.linuxfs.mountd.sock) sits in a directory group daemon may write: the mount program checks that
 * its peer is root before it sends anything. Syslog gets the peers, refusals and results; stderr (the log file) only a
 * failure to start.
 *
 * The test build (LINUXFS_MOUNTD_TEST, never shipped) binds its own socket and takes the console's uid, the slots, the queue
 * and the idle time as options, logs to stderr, and its stub child sleeps LINUXFS_MOUNTD_TEST_CHILD_SLEEP seconds.
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
	*why = "the mount point is /Volumes/ and one name, with no control characters";
	if (!field(q.mnt, sizeof(q.mnt), f[4], n[4]) || strncmp(q.mnt, VOLUMES, strlen(VOLUMES)) != 0)
		return -1;
	name = q.mnt + strlen(VOLUMES);
	nlen = strlen(name);
	if (nlen == 0 || nlen > MOUNTD_NAME_MAX || strchr(name, '/') || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
		return -1;
	for (i = 0; i < nlen; i++)
		if ((unsigned char)name[i] < 0x20 || (unsigned char)name[i] == 0x7f)
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
#include <errno.h>
#include <fcntl.h>
#include <launch.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/ucred.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

#define LISTENER "Listener"	/* the plist's Sockets key (16k) */
#define CHILDREN_MAX 64	/* room for the slots (MOUNTD_SLOTS, or the test build's --max) */
#define QUEUE_MAX 64	/* room for the queue, over every uid */
#define REFUSAL_EVERY_MS 10000	/* a refused uid is logged at most this often */
#define REFUSALS 16	/* uids remembered for that */

struct limits { int slots_uid, slots, queue, queue_wait, idle, status; uid_t console; int console_given; };
static struct limits lim = { MOUNTD_SLOTS_UID, MOUNTD_SLOTS, MOUNTD_QUEUE, MOUNTD_QUEUE_WAIT, MOUNTD_IDLE, 0, 0, 0 };
static struct { pid_t pid; uid_t uid; } kids[CHILDREN_MAX];
static int nkids;
static struct { int fd; uid_t uid; long long since; } queue[QUEUE_MAX];
static int nqueued;
static struct { uid_t uid; long long at; } refusals[REFUSALS];
static volatile sig_atomic_t stopping, child_ended;

static void on_term(int sig) { (void)sig; stopping = 1; }	/* only a flag: the loop acts on it */
static void on_child(int sig) { (void)sig; child_ended = 1; }	/* only a flag: it wakes the loop, which reaps */

static long long now_ms(void)
{
	static mach_timebase_info_data_t tb;

	if (!tb.denom)
		mach_timebase_info(&tb);
	return (long long)((double)mach_absolute_time() * tb.numer / tb.denom / 1e6);
}

/* one line to syslog (the test build: to stderr) */
static void say(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
#ifdef LINUXFS_MOUNTD_TEST
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
#else
	vsyslog(LOG_NOTICE, fmt, ap);
#endif
	va_end(ap);
}

/* a failure to start: the log file (stderr) as well as syslog */
static int start_failed(const char *what)
{
	fprintf(stderr, "linuxfs-mountd: %s: %s\n", what, strerror(errno));
	say("mountd: %s: %s", what, strerror(errno));
	return 1;
}

static void status(void)
{
	if (lim.status)
		say("mountd: status slots %d queued %d", nkids, nqueued);
}

/* the reply V (mountd_reply) to C, never waiting: C is non-blocking in the parent, and a peer that left is no harm (SIGPIPE
 * is ignored) */
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
	closelog();	/* its socket is closed below; syslog reopens one when next used */
	for (fd = 3; fd < top; fd++)
		if (fd != c)
			close(fd);
	signal(SIGCHLD, SIG_DFL);
	signal(SIGPIPE, SIG_DFL);
	signal(SIGTERM, SIG_DFL);
	sigemptyset(&none);
	sigprocmask(SIG_SETMASK, &none, NULL);
	fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK);

	n = read_request(c, buf, sizeof(buf));
	if (n < 0) {
		say("mountd: uid %u sent no request within %d s", (unsigned)uid, MOUNTD_REQUEST);
		_exit(0);
	}
	if (mountd_parse(buf, (size_t)n, &r, &why) != 0) {
		say("mountd: uid %u: a bad request: %s", (unsigned)uid, why);
		answer(c, MD_REFUSE, 1, why);
		_exit(0);
	}
	say("mountd: request from uid %u: %s %s on %s", (unsigned)uid, r.fs, r.bsd, r.mnt);
#ifdef LINUXFS_MOUNTD_TEST
	if (getenv("LINUXFS_MOUNTD_TEST_CHILD_SLEEP"))
		sleep((unsigned)atoi(getenv("LINUXFS_MOUNTD_TEST_CHILD_SLEEP")));
#endif
	answer(c, MD_USER, 0, "not yet");	/* the work comes in 16i */
	_exit(0);
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

	for (i = 0; i < nqueued && nkids < lim.slots;)
		if (running(queue[i].uid) < lim.slots_uid) {
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

/* A refusal for a peer that is not served (UID, its reply V/RC/WHY), logged at most once per REFUSAL_EVERY_MS per uid. */
static void refuse(int c, uid_t uid, enum mountd_verdict v, int rc, const char *why)
{
	long long now = now_ms();
	int i, oldest = 0;

	answer(c, v, rc, why);
	close(c);
	for (i = 0; i < REFUSALS; i++) {
		if (refusals[i].at && refusals[i].uid == uid)
			break;
		if (refusals[i].at < refusals[oldest].at)
			oldest = i;
	}
	if (i < REFUSALS && now - refusals[i].at < REFUSAL_EVERY_MS)
		return;
	if (i == REFUSALS)
		i = oldest;
	refusals[i].uid = uid;
	refusals[i].at = now ? now : 1;
	say("mountd: refused uid %u: %s", (unsigned)uid, why);
}

static uid_t console_uid(void)
{
	struct stat st;

	if (lim.console_given)
		return lim.console;
	return stat("/dev/console", &st) == 0 ? st.st_uid : (uid_t)-1;
}

/* One accepted connection: the peer first (I3), before any slot is counted. */
static void arrive(int c)
{
	struct xucred xu;
	socklen_t len = sizeof(xu);
	char groups[NGROUPS * 12] = "";
	size_t at = 0;
	int i;

	fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK);
	if (getsockopt(c, SOL_LOCAL, LOCAL_PEERCRED, &xu, &len) != 0 || xu.cr_version != XUCRED_VERSION) {
		say("mountd: a peer's credential cannot be read: %s", strerror(errno));
		close(c);
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
	int s, c, i;

#ifdef LINUXFS_MOUNTD_TEST
	const char *path = NULL;
	int console = -1;

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
		if (strcmp(argv[i], "--console") == 0)
			to = &console, min = 0;
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
		if (!to || i + 1 >= argc || (v = number(argv[++i], min)) < 0) {
			fprintf(stderr, "usage: linuxfs-mountd [--socket PATH] [--console UID] [--idle S] [--max-uid N] [--max N] "
					"[--queue N] [--queue-wait S] [--status]\n");
			return 2;
		}
		*to = v;
	}
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
	openlog("linuxfs-mountd", LOG_PID, LOG_DAEMON);
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
		while ((c = accept(s, NULL, NULL)) >= 0)
			arrive(c);
		if (errno == EMFILE || errno == ENFILE)
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
