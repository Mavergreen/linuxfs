/*
 * linuxfs-agent: the per-user keychain keeper (LaunchAgent dev.mavergreen.linuxfs.agent, in the console session).
 * usage: linuxfs-agent
 *        linuxfs-agent --offer DISK     (reads one password from stdin)
 * DiskArbitration recognises, mounts and unmounts linuxfs's disks itself (the filesystem bundles); the agent is what is
 * left for the one thing the mount program cannot do from outside the user's session: reach the login keychain.
 * It listens on $HOME/Library/Caches/dev.mavergreen.linuxfs/keychain.sock (the directory 0700, the socket 0600) and
 * answers peers of its own uid only. One request per connection, in lines; the password is never logged:
 *     find TAB DISK NL            -> "offered NL PW NL" (an --offer for DISK within the last 60 s, used once), else
 *                                    "saved NL PW NL" (the login keychain: service dev.mavergreen.linuxfs, account the
 *                                    partition's UUID), else "none NL"
 *     save TAB DISK NL PW NL      -> "ok NL"      (keeps PW in the keychain)
 *     forget TAB DISK NL          -> "ok NL"
 *     offer TAB DISK NL PW NL     -> "ok NL"      (PW, for the next find of DISK only; kept in memory)
 * A request it does not understand is dropped with no answer. `linuxfs-agent --offer DISK` sends an offer, exits 0 when
 * the agent says ok and 1 when no agent answers within 5 s.
 * Login sweep: once, 15 s after it starts (LINUXFS_SWEEP_DELAY seconds instead, unless root), for every disk whose
 * DiskArbitration volume kind is one of the six macfuse_<fs> names and that has no volume path (DiskArbitration did not mount it, say
 * because the keychain was not ready), it runs `linuxfs automount DISK` -- unless /etc/fstab has linuxfs's noauto entry
 * for the volume's UUID or name (linuxfs ignore), which is why DiskArbitration left it alone.
 * At start (login), one notice for each Ignore:<LABEL> = true preference (the user's or the machine's) still there: the
 * install turns those into /etc/fstab entries only for disks attached then, and nothing reads them any more. Each label is
 * told of once: those told of are kept in the user's preference IgnoreNotified (an array).
 * LINUXFS_CLI names another linuxfs, LINUXFS_FSTAB another fstab, LINUXFS_PREFS_DOMAIN another preferences domain (an
 * absolute path), LINUXFS_MACHINE_PLIST another machine plist, LINUXFS_NOTICE_LOG a file the notices are appended to instead
 * of shown, and LINUXFS_KEYCHAIN=off swaps the keychain for a store in memory (tests); like LINUXFS_SWEEP_DELAY, they are
 * honoured only when not root.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <Security/Security.h>
#include <ctype.h>
#include <strings.h>
#include <mach/mach_time.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include "fsrules.h"
#include "fstab.h"

extern char **environ;

#define PREFIX "/usr/local/mavergreen/linuxfs"
#define DIRNAME "Library/Caches/dev.mavergreen.linuxfs"
#define SOCKNAME "keychain.sock"
#define OFFER_TTL 60
#define CLIENT_TIMEOUT 5
#define SERVER_TIMEOUT 5
#define SWEEP_DELAY 15
#define SWEEP_WINDOW 10
#define REQUEST_DEADLINE 5
#define PW_MAX 1024

/*
 * A request's first line, LINE ("VERB TAB BSD", a trailing newline allowed): split in place, *VERB and *BSD set. 0 when it
 * is one of the four verbs with a disk name (letters and digits only, as a BSD name is); -1 otherwise.
 */
int agent_parse_request(char *line, char **verb, char **bsd)
{
	static const char *verbs[] = { "find", "save", "forget", "offer", NULL };
	size_t n = strlen(line);
	char *tab;
	int ok = 0;

	if (n && line[n - 1] == '\n')
		line[--n] = '\0';
	tab = strchr(line, '\t');
	if (!tab || !tab[1] || n - (size_t)(tab + 1 - line) > 63)
		return -1;
	*tab = '\0';
	for (int i = 0; verbs[i]; i++)
		ok |= strcmp(line, verbs[i]) == 0;
	for (char *p = tab + 1; *p; p++)
		if (!isalnum((unsigned char)*p))
			return -1;
	if (!ok)
		return -1;
	*verb = line;
	*bsd = tab + 1;
	return 0;
}

/* Whether the login sweep mounts a disk: DiskArbitration gave it one of the six macfuse_<fs> volume kinds and no volume path. */
int agent_sweeps(const char *kind, int has_path)
{
	return fsrules_fs_of_type(kind) != NULL && !has_path;
}

/* And when FSTAB (LEN bytes of /etc/fstab) has no linuxfs noauto entry for the volume's UUID or name (either may be NULL). */
int agent_sweeps_volume(const char *kind, int has_path, const char *fstab, size_t len, const char *uuid, const char *volname)
{
	return agent_sweeps(kind, has_path) && !fstab_has_noauto(fstab, len, uuid, volname);
}

/* a preference value that means true: a true boolean, a nonzero number, or YES/true/1 */
static int truthy(CFTypeRef v)
{
	char b[8];
	int n;

	if (!v)
		return 0;
	if (CFGetTypeID(v) == CFBooleanGetTypeID())
		return CFBooleanGetValue(v);
	if (CFGetTypeID(v) == CFNumberGetTypeID())
		return CFNumberGetValue(v, kCFNumberIntType, &n) && n != 0;
	if (CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString(v, b, sizeof(b), kCFStringEncodingUTF8))
		return !strcasecmp(b, "yes") || !strcasecmp(b, "true") || !strcmp(b, "1");
	return 0;
}

static void collect_unconverted(const void *key, const void *value, void *ctx)
{
	CFMutableArrayRef out = ((CFMutableArrayRef *)ctx)[0];
	CFArrayRef notified = ((CFArrayRef *)ctx)[1];
	CFStringRef label;

	if (CFGetTypeID(key) != CFStringGetTypeID() || !CFStringHasPrefix(key, CFSTR("Ignore:")) || !truthy(value))
		return;
	label = CFStringCreateWithSubstring(NULL, key, CFRangeMake(7, CFStringGetLength(key) - 7));
	if (!label)
		return;
	if (CFStringGetLength(label) > 0 && !CFArrayContainsValue(out, CFRangeMake(0, CFArrayGetCount(out)), label) &&
	    !(notified && CFArrayContainsValue(notified, CFRangeMake(0, CFArrayGetCount(notified)), label)))
		CFArrayAppendValue(out, label);
	CFRelease(label);
}

/* The labels of the Ignore:<LABEL> = true keys in USER and MACHINE (either may be NULL) that are not in NOTIFIED (may be
 * NULL), each once: a new array, the caller's to release; NULL only when out of memory. */
CFArrayRef agent_unconverted(CFDictionaryRef user, CFDictionaryRef machine, CFArrayRef notified)
{
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	const void *ctx[2] = { out, notified && CFGetTypeID(notified) == CFArrayGetTypeID() ? notified : NULL };

	if (!out)
		return NULL;
	if (user)
		CFDictionaryApplyFunction(user, collect_unconverted, ctx);
	if (machine)
		CFDictionaryApplyFunction(machine, collect_unconverted, ctx);
	return out;
}

#ifndef LINUXFS_AGENT_NO_MAIN
static const char *cli;
static DASessionRef session;
static int use_keychain;

/* A test hook's value: honoured only when not root (an agent running as root takes nothing from its environment). */
static const char *env_or(const char *name, const char *dflt)
{
	const char *v = geteuid() == 0 ? NULL : getenv(name);

	return v && *v ? v : dflt;
}

/* the socket's directory and path under HOME; 0 when HOME is unset or the path is too long for a socket */
static int paths(char *dir, size_t dlen, char *sock, size_t slen)
{
	const char *home = getenv("HOME");
	struct sockaddr_un sa;

	if (!home || !*home)
		return 0;
	snprintf(dir, dlen, "%s/%s", home, DIRNAME);
	snprintf(sock, slen, "%s/%s", dir, SOCKNAME);
	return strlen(sock) < sizeof(sa.sun_path);
}

/* ---- the keychain, or with LINUXFS_KEYCHAIN=off a store in memory, by BSD name ---- */

#define KC_SERVICE "dev.mavergreen.linuxfs"
#define SLOTS 16

/* a monotonic clock, in milliseconds (the wall clock may be set; TTLs and deadlines must not care) */
static uint64_t now_ms(void)
{
	static mach_timebase_info_data_t tb;

	if (!tb.denom)
		mach_timebase_info(&tb);
	return mach_absolute_time() * tb.numer / tb.denom / 1000000;
}

struct slot {
	char bsd[64];
	char pw[PW_MAX];
	uint64_t at;
};
static struct slot memstore[SLOTS];	/* LINUXFS_KEYCHAIN=off */
static struct slot offers[SLOTS];	/* --offer, kept in memory in either case */

static struct slot *slot_find(struct slot *t, const char *bsd)
{
	for (int i = 0; i < SLOTS; i++)
		if (t[i].bsd[0] && strcmp(t[i].bsd, bsd) == 0)
			return &t[i];
	return NULL;
}

static void slot_clear(struct slot *s)
{
	memset(s, 0, sizeof(*s));
}

static void slot_put(struct slot *t, const char *bsd, const char *pw)
{
	struct slot *s = slot_find(t, bsd);

	for (int i = 0; !s && i < SLOTS; i++)
		if (!t[i].bsd[0])
			s = &t[i];
	if (!s) {	/* full: the oldest-written slot goes */
		s = &t[0];
		for (int i = 1; i < SLOTS; i++)
			if (t[i].at < s->at)
				s = &t[i];
	}
	slot_clear(s);
	snprintf(s->bsd, sizeof(s->bsd), "%s", bsd);
	snprintf(s->pw, sizeof(s->pw), "%s", pw);
	s->at = now_ms();
}

/* The keychain account for disk BSD: its partition's UUID; 0 when it has none (then nothing is kept). */
static int keychain_account(const char *bsd, char *acct, size_t len)
{
	DADiskRef d = DADiskCreateFromBSDName(NULL, session, bsd);
	CFDictionaryRef desc = d ? DADiskCopyDescription(d) : NULL;
	CFUUIDRef u = desc ? CFDictionaryGetValue(desc, kDADiskDescriptionMediaUUIDKey) : NULL;
	CFStringRef s = u ? CFUUIDCreateString(NULL, u) : NULL;
	int ok = s && CFStringGetCString(s, acct, len, kCFStringEncodingUTF8);

	if (s)
		CFRelease(s);
	if (desc)
		CFRelease(desc);
	if (d)
		CFRelease(d);
	return ok;
}

static int keychain_find(const char *bsd, char *pw, size_t len)
{
	char acct[64];
	UInt32 n = 0;
	void *data = NULL;
	int ok;

	if (!use_keychain) {
		struct slot *s = slot_find(memstore, bsd);

		if (!s || strlen(s->pw) >= len)
			return 0;
		snprintf(pw, len, "%s", s->pw);
		return 1;
	}
	if (!keychain_account(bsd, acct, sizeof(acct)) ||
	    SecKeychainFindGenericPassword(NULL, strlen(KC_SERVICE), KC_SERVICE, strlen(acct), acct, &n, &data, NULL) != errSecSuccess)
		return 0;
	ok = n < len;
	if (ok) {
		memcpy(pw, data, n);
		pw[n] = '\0';
	}
	memset(data, 0, n);
	SecKeychainItemFreeContent(NULL, data);
	return ok;
}

static void keychain_save(const char *bsd, const char *pw)
{
	char acct[64];
	SecKeychainItemRef item = NULL;
	OSStatus st;

	if (!use_keychain) {
		slot_put(memstore, bsd, pw);
		return;
	}
	if (!keychain_account(bsd, acct, sizeof(acct))) {
		syslog(LOG_NOTICE, "%s has no partition UUID; its password is not kept", bsd);
		return;
	}
	st = SecKeychainAddGenericPassword(NULL, strlen(KC_SERVICE), KC_SERVICE, strlen(acct), acct, strlen(pw), pw, NULL);
	if (st == errSecDuplicateItem &&
	    SecKeychainFindGenericPassword(NULL, strlen(KC_SERVICE), KC_SERVICE, strlen(acct), acct, NULL, NULL, &item) == errSecSuccess) {
		st = SecKeychainItemModifyAttributesAndData(item, NULL, strlen(pw), pw);
		CFRelease(item);
	}
	if (st != errSecSuccess)
		syslog(LOG_ERR, "cannot keep %s's password in the keychain (%d)", bsd, (int)st);
	else
		syslog(LOG_NOTICE, "kept %s's password in the keychain", bsd);
}

static void keychain_forget(const char *bsd)
{
	char acct[64];
	SecKeychainItemRef item = NULL;

	if (!use_keychain) {
		struct slot *s = slot_find(memstore, bsd);

		if (s)
			slot_clear(s);
		return;
	}
	if (!keychain_account(bsd, acct, sizeof(acct)))
		return;
	/* every matching item, not just the first */
	while (SecKeychainFindGenericPassword(NULL, strlen(KC_SERVICE), KC_SERVICE, strlen(acct), acct, NULL, NULL, &item) == errSecSuccess) {
		OSStatus st = SecKeychainItemDelete(item);

		CFRelease(item);
		if (st != errSecSuccess) {
			syslog(LOG_ERR, "cannot forget %s's password in the keychain (%d)", bsd, (int)st);
			return;
		}
		syslog(LOG_NOTICE, "forgot %s's password in the keychain", bsd);
	}
}

/* An --offer for BSD, taken (used once); 0 when there is none or it is older than OFFER_TTL. */
static int offer_take(const char *bsd, char *pw, size_t len)
{
	struct slot *s = slot_find(offers, bsd);
	int ok;

	if (!s)
		return 0;
	ok = now_ms() - s->at <= OFFER_TTL * 1000 && strlen(s->pw) < len;
	if (ok)
		snprintf(pw, len, "%s", s->pw);
	slot_clear(s);
	return ok;
}

/* Offers older than OFFER_TTL are forgotten, their passwords zeroed. */
static void offers_purge(void)
{
	for (int i = 0; i < SLOTS; i++)
		if (offers[i].bsd[0] && now_ms() - offers[i].at > OFFER_TTL * 1000)
			slot_clear(&offers[i]);
}

/* ---- the socket ---- */

static void put(int fd, const char *s)
{
	size_t n = strlen(s);

	while (n) {
		ssize_t w = write(fd, s, n);

		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			return;
		s += w;
		n -= (size_t)w;
	}
}

/*
 * Reads from FD until LINES newlines have come (or EOF, the DEADLINE (now_ms) or BUF's CAP is full); the length,
 * NUL-terminated. It polls with what is left of the deadline before each read, so a client that drips bytes is dropped.
 */
static size_t read_lines(int fd, char *buf, size_t cap, int lines, uint64_t deadline)
{
	size_t n = 0;

	while (n < cap - 1) {
		uint64_t now = now_ms();
		struct pollfd p = { fd, POLLIN, 0 };
		int pr;
		ssize_t r;

		if (now >= deadline)
			break;
		pr = poll(&p, 1, (int)(deadline - now));
		if (pr < 0 && errno == EINTR)
			continue;
		if (pr <= 0)
			break;
		r = read(fd, buf + n, cap - 1 - n);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			break;
		n += (size_t)r;
		buf[n] = '\0';
		for (size_t i = 0; i < n && lines > 0; i++)
			if (buf[i] == '\n')
				lines--;
		if (lines <= 0)
			break;
	}
	buf[n] = '\0';
	return n;
}

static void serve(int fd)
{
	char buf[PW_MAX + 128], pw[PW_MAX], *verb, *bsd, *pwline, *nl;
	uid_t uid;
	gid_t gid;
	struct timeval tv = { SERVER_TIMEOUT, 0 };
	uint64_t deadline = now_ms() + REQUEST_DEADLINE * 1000;
	int one = 1, fl = fcntl(fd, F_GETFL);
	int want_pw;

	if (getpeereid(fd, &uid, &gid) != 0 || uid != geteuid()) {
		syslog(LOG_NOTICE, "dropped a connection from uid %d", getpeereid(fd, &uid, &gid) == 0 ? (int)uid : -1);
		return;
	}
	if (fl >= 0)
		fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
	read_lines(fd, buf, sizeof(buf), 1, deadline);
	nl = strchr(buf, '\n');
	if (!nl)
		goto done;
	/* the first line is parsed on its own, in place: a password after it is kept apart */
	{
		char first[128];
		size_t fl1 = (size_t)(nl - buf);

		if (fl1 >= sizeof(first))
			goto done;
		memcpy(first, buf, fl1);
		first[fl1] = '\0';
		if (agent_parse_request(first, &verb, &bsd) != 0)
			goto done;
		want_pw = strcmp(verb, "save") == 0 || strcmp(verb, "offer") == 0;
		if (want_pw && !strchr(nl + 1, '\n'))
			read_lines(fd, buf + (nl + 1 - buf) + strlen(nl + 1), sizeof(buf) - (size_t)(nl + 1 - buf) - strlen(nl + 1), 1, deadline);
		pwline = nl + 1;
		if (want_pw) {
			char *e = strchr(pwline, '\n');

			if (!e || e == pwline || (size_t)(e - pwline) >= sizeof(pw))
				goto done;
			memcpy(pw, pwline, (size_t)(e - pwline));
			pw[e - pwline] = '\0';
		}
		if (strcmp(verb, "find") == 0) {
			char out[PW_MAX + 16];

			if (offer_take(bsd, pw, sizeof(pw))) {
				snprintf(out, sizeof(out), "offered\n%s\n", pw);
				syslog(LOG_NOTICE, "%s: gave out an offered password", bsd);
			} else if (keychain_find(bsd, pw, sizeof(pw))) {
				snprintf(out, sizeof(out), "saved\n%s\n", pw);
				syslog(LOG_NOTICE, "%s: gave out the saved password", bsd);
			} else {
				snprintf(out, sizeof(out), "none\n");
			}
			put(fd, out);
			memset(out, 0, sizeof(out));
		} else if (strcmp(verb, "save") == 0) {
			keychain_save(bsd, pw);
			put(fd, "ok\n");
		} else if (strcmp(verb, "forget") == 0) {
			keychain_forget(bsd);
			put(fd, "ok\n");
		} else {
			slot_put(offers, bsd, pw);
			syslog(LOG_NOTICE, "%s: took an offered password", bsd);
			put(fd, "ok\n");
		}
	}
done:
	memset(buf, 0, sizeof(buf));
	memset(pw, 0, sizeof(pw));
}

static void accepted(CFSocketRef s, CFSocketCallBackType type, CFDataRef addr, const void *data, void *ctx)
{
	int fd;

	(void)s;
	(void)addr;
	(void)ctx;
	if (type != kCFSocketAcceptCallBack)
		return;
	fd = *(const CFSocketNativeHandle *)data;
	serve(fd);
	close(fd);
}

/* 1 when an agent already answers at PATH */
static int answers(const char *path)
{
	struct sockaddr_un sa;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0), ok;
	struct timeval tv = { 1, 0 };

	if (fd < 0)
		return 0;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	ok = connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0;
	close(fd);
	return ok;
}

/* -1 on failure, -2 when another agent already answers */
static int listen_on(const char *dir, const char *path)
{
	struct sockaddr_un sa;
	struct stat st;
	int fd;
	char parent[1024];
	const char *sub[] = { "Library", "Library/Caches", NULL };

	/* Library and Library/Caches exist for any user; creating them is only for a bare HOME in tests */
	for (int i = 0; sub[i]; i++) {
		snprintf(parent, sizeof(parent), "%s/%s", getenv("HOME"), sub[i]);
		mkdir(parent, 0700);
	}
	if (mkdir(dir, 0700) < 0 && errno != EEXIST)
		return -1;
	/* a real directory of ours, not a symlink or someone else's */
	if (lstat(dir, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != geteuid()) {
		syslog(LOG_ERR, "%s is not a directory of this user's own; not listening", dir);
		return -1;
	}
	if (chmod(dir, 0700) < 0)
		return -1;
	if (answers(path))
		return -2;
	unlink(path);	/* a stale socket from an agent that died */
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0 || chmod(path, 0600) < 0 || listen(fd, 16) < 0) {
		close(fd);
		return -1;
	}
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	return fd;
}

/* ---- --offer DISK ---- */

static int offer_main(const char *bsd)
{
	char dir[1024], path[1024], line[128], pw[PW_MAX], req[PW_MAX + 128], reply[16], *verb, *b;
	struct sockaddr_un sa;
	struct timeval tv = { CLIENT_TIMEOUT, 0 };
	struct pollfd p;
	int fd, one = 1, fl;

	snprintf(line, sizeof(line), "offer\t%s", bsd);
	if (agent_parse_request(line, &verb, &b) != 0 || !paths(dir, sizeof(dir), path, sizeof(path))) {
		fprintf(stderr, "linuxfs-agent: no such disk or no HOME\n");
		return 2;
	}
	read_lines(0, pw, sizeof(pw), 1, now_ms() + CLIENT_TIMEOUT * 1000);
	pw[strcspn(pw, "\n")] = '\0';
	if (!pw[0]) {
		fprintf(stderr, "linuxfs-agent: no password on stdin\n");
		return 2;
	}
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
	fl = fcntl(fd, F_GETFL);
	fcntl(fd, F_SETFL, fl | O_NONBLOCK);
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		p.fd = fd;
		p.events = POLLOUT;
		if ((errno != EINPROGRESS && errno != EAGAIN) || poll(&p, 1, CLIENT_TIMEOUT * 1000) != 1) {
			close(fd);
			return 1;
		}
	}
	fcntl(fd, F_SETFL, fl);
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	snprintf(req, sizeof(req), "offer\t%s\n%s\n", bsd, pw);
	put(fd, req);
	memset(req, 0, sizeof(req));
	memset(pw, 0, sizeof(pw));
	read_lines(fd, reply, sizeof(reply), 1, now_ms() + CLIENT_TIMEOUT * 1000);
	close(fd);
	return strcmp(reply, "ok\n") == 0 ? 0 : 1;
}

/* ---- the login sweep ---- */

static void reap(CFRunLoopTimerRef t, void *ctx)
{
	int status;

	(void)t;
	(void)ctx;
	while (waitpid(-1, &status, WNOHANG) > 0)
		;
	offers_purge();
}

static void automount(const char *bsd)
{
	const char *argv[] = { cli, "automount", bsd, NULL };
	pid_t pid;
	posix_spawnattr_t attr;
	sigset_t def;

	syslog(LOG_NOTICE, "%s automount %s", cli, bsd);
	/* the agent ignores SIGPIPE (a client may go away mid-answer); its child must not inherit that */
	sigemptyset(&def);
	sigaddset(&def, SIGPIPE);
	posix_spawnattr_init(&attr);
	posix_spawnattr_setsigdefault(&attr, &def);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF);
	if (posix_spawn(&pid, cli, NULL, &attr, (char **)argv, environ) != 0)
		syslog(LOG_ERR, "cannot run %s: %s", cli, strerror(errno));
	posix_spawnattr_destroy(&attr);
}

static int swept;
static char fstab[FSTAB_MAX];
static size_t fstab_len;

/* /etc/fstab, at most FSTAB_MAX bytes of it, into fstab; none when it is missing or not a regular file */
static void read_fstab(void)
{
	struct stat st;
	ssize_t r;
	int fd = open(env_or("LINUXFS_FSTAB", "/etc/fstab"), O_RDONLY | O_NONBLOCK | O_NOCTTY);

	fstab_len = 0;
	if (fd < 0)
		return;
	if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode))
		while (fstab_len < sizeof(fstab) && (r = read(fd, fstab + fstab_len, sizeof(fstab) - fstab_len)) > 0)
			fstab_len += (size_t)r;
	close(fd);
}

static void sweep_appeared(DADiskRef disk, void *ctx)
{
	const char *bsd = DADiskGetBSDName(disk);
	CFDictionaryRef d = bsd ? DADiskCopyDescription(disk) : NULL;
	CFStringRef k, name, us;
	CFUUIDRef u;
	char kind[64] = "", vol[1024] = "", uuid[40] = "";

	(void)ctx;
	if (!d)
		return;
	swept++;
	k = CFDictionaryGetValue(d, kDADiskDescriptionVolumeKindKey);
	if (k)
		CFStringGetCString(k, kind, sizeof(kind), kCFStringEncodingUTF8);
	name = CFDictionaryGetValue(d, kDADiskDescriptionVolumeNameKey);
	if (name && CFGetTypeID(name) == CFStringGetTypeID())
		CFStringGetCString(name, vol, sizeof(vol), kCFStringEncodingUTF8);
	u = CFDictionaryGetValue(d, kDADiskDescriptionVolumeUUIDKey);
	if (u && CFGetTypeID(u) == CFUUIDGetTypeID() && (us = CFUUIDCreateString(NULL, u))) {
		CFStringGetCString(us, uuid, sizeof(uuid), kCFStringEncodingUTF8);
		CFRelease(us);
	}
	if (agent_sweeps(k ? kind : NULL, CFDictionaryGetValue(d, kDADiskDescriptionVolumePathKey) != NULL)) {
		if (agent_sweeps_volume(kind, 0, fstab, fstab_len, uuid, vol))
			automount(bsd);
		else
			syslog(LOG_NOTICE, "%s: left alone: /etc/fstab says noauto (linuxfs ignore)", bsd);
	}
	CFRelease(d);
}

/* The sweep's own session sees every disk there already is, as "appeared"; a moment later it is let go. */
static void sweep_end(CFRunLoopTimerRef t, void *ctx)
{
	DASessionRef s = ctx;

	(void)t;
	syslog(LOG_NOTICE, "login sweep looked at %d disks", swept);
	DAUnregisterCallback(s, sweep_appeared, NULL);
	DASessionUnscheduleFromRunLoop(s, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	CFRelease(s);
}

static void sweep(CFRunLoopTimerRef t, void *ctx)
{
	DASessionRef s = DASessionCreate(NULL);

	(void)t;
	(void)ctx;
	syslog(LOG_NOTICE, "login sweep");
	if (!s)
		return;
	read_fstab();
	DARegisterDiskAppearedCallback(s, NULL, sweep_appeared, NULL);
	DASessionScheduleWithRunLoop(s, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	{
		CFRunLoopTimerContext tc = { 0, s, NULL, NULL, NULL };

		CFRunLoopTimerRef et = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + SWEEP_WINDOW, 0, 0, 0, sweep_end, &tc);

		CFRunLoopAddTimer(CFRunLoopGetCurrent(), et, kCFRunLoopDefaultMode);
		CFRelease(et);	/* the run loop keeps it until it fires */
	}
}

/* ---- at login: the Ignore:<LABEL> preferences the install left ---- */

#define MACHINE_PLIST_MAX (1024 * 1024)

/* the machine's plist (root's, world-readable), at most 1 MiB, as a dictionary; NULL for anything else */
static CFDictionaryRef machine_prefs(void)
{
	struct stat st;
	char *buf = NULL;
	size_t got = 0;
	ssize_t r;
	CFDictionaryRef d = NULL;
	int fd = open(env_or("LINUXFS_MACHINE_PLIST", "/Library/Preferences/dev.mavergreen.linuxfs.plist"), O_RDONLY | O_NONBLOCK | O_NOCTTY);

	if (fd < 0)
		return NULL;
	if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size <= MACHINE_PLIST_MAX &&
	    (buf = malloc((size_t)st.st_size)) != NULL)
		while (got < (size_t)st.st_size && (r = read(fd, buf + got, (size_t)st.st_size - got)) > 0)
			got += (size_t)r;
	close(fd);
	if (buf && got == (size_t)st.st_size) {
		CFDataRef data = CFDataCreate(NULL, (const UInt8 *)buf, (CFIndex)got);
		CFPropertyListRef pl = data ? CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL) : NULL;

		if (pl && CFGetTypeID(pl) == CFDictionaryGetTypeID())
			d = pl;
		else if (pl)
			CFRelease(pl);
		if (data)
			CFRelease(data);
	}
	free(buf);
	return d;
}

static void notice(CFStringRef label)
{
	const char *log = env_or("LINUXFS_NOTICE_LOG", NULL);
	CFStringRef msg = CFStringCreateWithFormat(NULL, NULL, CFSTR("linuxfs no longer skips \"%@\" by name: attach it and run linuxfs ignore"), label);
	char text[2048];

	if (!msg)
		return;
	if (log) {
		FILE *f = fopen(log, "a");

		if (f && CFStringGetCString(msg, text, sizeof(text), kCFStringEncodingUTF8))
			fprintf(f, "%s\n", text);
		if (f)
			fclose(f);
	} else {
		/* shown and left: DisplayNotice does not wait for the OK */
		CFUserNotificationDisplayNotice(0, kCFUserNotificationNoteAlertLevel, NULL, NULL, NULL, CFSTR("Linux Filesystems"), msg, CFSTR("OK"));
	}
	CFRelease(msg);
}

static void notify_unconverted(void)
{
	const char *dom = env_or("LINUXFS_PREFS_DOMAIN", "dev.mavergreen.linuxfs");
	CFStringRef app = CFStringCreateWithCString(NULL, dom, kCFStringEncodingUTF8), key = CFSTR("IgnoreNotified");
	CFDictionaryRef user, machine;
	CFPropertyListRef was;
	CFMutableArrayRef told;
	CFArrayRef labels;
	CFIndex i;

	if (!app)
		return;
	user = CFPreferencesCopyMultiple(NULL, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	machine = machine_prefs();
	was = CFPreferencesCopyAppValue(key, app);
	if (was && CFGetTypeID(was) != CFArrayGetTypeID()) {
		CFRelease(was);
		was = NULL;
	}
	labels = agent_unconverted(user, machine, was);
	told = was ? CFArrayCreateMutableCopy(NULL, 0, was) : CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (labels && told && CFArrayGetCount(labels) > 0) {
		for (i = 0; i < CFArrayGetCount(labels); i++) {
			notice(CFArrayGetValueAtIndex(labels, i));
			CFArrayAppendValue(told, CFArrayGetValueAtIndex(labels, i));
		}
		CFPreferencesSetAppValue(key, told, app);
		CFPreferencesAppSynchronize(app);
		syslog(LOG_NOTICE, "told of %d Ignore: preferences the install could not convert", (int)CFArrayGetCount(labels));
	}
	if (labels)
		CFRelease(labels);
	if (told)
		CFRelease(told);
	if (was)
		CFRelease(was);
	if (user)
		CFRelease(user);
	if (machine)
		CFRelease(machine);
	CFRelease(app);
}

int main(int argc, char **argv)
{
	char dir[1024], path[1024];
	const char *delay;
	CFSocketRef cs;
	CFRunLoopSourceRef src;
	CFRunLoopTimerRef timer;
	int fd;

	if (argc == 3 && strcmp(argv[1], "--offer") == 0)
		return offer_main(argv[2]);
	if (argc != 1) {
		fprintf(stderr, "usage: linuxfs-agent\n       linuxfs-agent --offer DISK     (the password on stdin)\n");
		return 2;
	}
	openlog("linuxfs-agent", LOG_PERROR | LOG_PID, LOG_USER);
	signal(SIGPIPE, SIG_IGN);
	cli = env_or("LINUXFS_CLI", PREFIX "/bin/linuxfs");
	use_keychain = strcmp(env_or("LINUXFS_KEYCHAIN", "on"), "off") != 0;
	session = DASessionCreate(NULL);
	if (!session) {
		syslog(LOG_ERR, "no DiskArbitration session");
		return 1;
	}
	if (!paths(dir, sizeof(dir), path, sizeof(path))) {
		syslog(LOG_ERR, "no usable HOME for the keychain socket");
		return 1;
	}
	fd = listen_on(dir, path);
	if (fd == -2) {
		syslog(LOG_NOTICE, "already running (an agent answers at %s)", path);
		return 0;
	}
	if (fd < 0) {
		syslog(LOG_ERR, "cannot listen on the keychain socket %s", path);
		return 1;
	}
	cs = CFSocketCreateWithNative(NULL, fd, kCFSocketAcceptCallBack, accepted, NULL);
	src = cs ? CFSocketCreateRunLoopSource(NULL, cs, 0) : NULL;
	if (!src) {
		syslog(LOG_ERR, "cannot watch the keychain socket");
		return 1;
	}
	CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
	delay = env_or("LINUXFS_SWEEP_DELAY", NULL);
	timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + (delay ? atof(delay) : SWEEP_DELAY), 0, 0, 0, sweep, NULL);
	CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
	CFRelease(timer);	/* the run loop keeps it until it has fired */
	timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0, reap, NULL);
	CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
	CFRelease(timer);
	syslog(LOG_NOTICE, "keeping the keychain at %s", path);
	notify_unconverted();
	CFRunLoopRun();
	return 0;
}
#endif
