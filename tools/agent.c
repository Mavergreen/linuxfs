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
 * DiskArbitration volume kind starts with linuxfs_ and that has no volume path (DiskArbitration did not mount it, say
 * because the keychain was not ready), it runs `linuxfs automount DISK`.
 * LINUXFS_CLI names another linuxfs, and LINUXFS_KEYCHAIN=off swaps the keychain for a store in memory (tests).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <Security/Security.h>
#include <ctype.h>
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

extern char **environ;

#define PREFIX "/usr/local/mavergreen/linuxfs"
#define DIRNAME "Library/Caches/dev.mavergreen.linuxfs"
#define SOCKNAME "keychain.sock"
#define OFFER_TTL 60
#define CLIENT_TIMEOUT 5
#define SERVER_TIMEOUT 2
#define SWEEP_DELAY 15
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

/* Whether the login sweep mounts a disk: DiskArbitration gave it a linuxfs_ volume kind and no volume path. */
int agent_sweeps(const char *kind, int has_path)
{
	return kind && strncmp(kind, "linuxfs_", 8) == 0 && !has_path;
}

#ifndef LINUXFS_AGENT_NO_MAIN
static const char *cli;
static DASessionRef session;
static int use_keychain;

static const char *env_or(const char *name, const char *dflt)
{
	const char *v = getenv(name);

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

struct slot {
	char bsd[64];
	char pw[PW_MAX];
	time_t at;
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
	if (!s)
		s = &t[0];	/* full: the oldest-written slot is as good as any */
	slot_clear(s);
	snprintf(s->bsd, sizeof(s->bsd), "%s", bsd);
	snprintf(s->pw, sizeof(s->pw), "%s", pw);
	s->at = time(NULL);
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
	if (keychain_account(bsd, acct, sizeof(acct)) &&
	    SecKeychainFindGenericPassword(NULL, strlen(KC_SERVICE), KC_SERVICE, strlen(acct), acct, NULL, NULL, &item) == errSecSuccess) {
		OSStatus st = SecKeychainItemDelete(item);

		CFRelease(item);
		if (st == errSecSuccess)
			syslog(LOG_NOTICE, "forgot %s's password in the keychain", bsd);
		else
			syslog(LOG_ERR, "cannot forget %s's password in the keychain (%d)", bsd, (int)st);
	}
}

/* An --offer for BSD, taken (used once); 0 when there is none or it is older than OFFER_TTL. */
static int offer_take(const char *bsd, char *pw, size_t len)
{
	struct slot *s = slot_find(offers, bsd);
	int ok;

	if (!s)
		return 0;
	ok = time(NULL) - s->at <= OFFER_TTL && strlen(s->pw) < len;
	if (ok)
		snprintf(pw, len, "%s", s->pw);
	slot_clear(s);
	return ok;
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

/* Reads from FD until LINES newlines have come (or EOF, the timeout, or BUF's CAP is full); the length, NUL-terminated. */
static size_t read_lines(int fd, char *buf, size_t cap, int lines)
{
	size_t n = 0;

	while (n < cap - 1) {
		ssize_t r = read(fd, buf + n, cap - 1 - n);

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
	read_lines(fd, buf, sizeof(buf), 1);
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
			read_lines(fd, buf + (nl + 1 - buf) + strlen(nl + 1), sizeof(buf) - (size_t)(nl + 1 - buf) - strlen(nl + 1), 1);
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

static int listen_on(const char *dir, const char *path)
{
	struct sockaddr_un sa;
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
	if (chmod(dir, 0700) < 0)
		return -1;
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
	size_t n = 0;
	int fd, one = 1, fl;

	snprintf(line, sizeof(line), "offer\t%s", bsd);
	if (agent_parse_request(line, &verb, &b) != 0 || !paths(dir, sizeof(dir), path, sizeof(path))) {
		fprintf(stderr, "linuxfs-agent: no such disk or no HOME\n");
		return 2;
	}
	while (n < sizeof(pw) - 1) {
		ssize_t r = read(0, pw + n, sizeof(pw) - 1 - n);

		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			break;
		n += (size_t)r;
	}
	pw[n] = '\0';
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
	read_lines(fd, reply, sizeof(reply), 1);
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
}

static void automount(const char *bsd)
{
	const char *argv[] = { cli, "automount", bsd, NULL };
	pid_t pid;

	syslog(LOG_NOTICE, "%s automount %s", cli, bsd);
	if (posix_spawn(&pid, cli, NULL, NULL, (char **)argv, environ) != 0)
		syslog(LOG_ERR, "cannot run %s: %s", cli, strerror(errno));
}

static int swept;

static void sweep_appeared(DADiskRef disk, void *ctx)
{
	const char *bsd = DADiskGetBSDName(disk);
	CFDictionaryRef d = bsd ? DADiskCopyDescription(disk) : NULL;
	CFStringRef k;
	char kind[64] = "";

	(void)ctx;
	if (!d)
		return;
	swept++;
	k = CFDictionaryGetValue(d, kDADiskDescriptionVolumeKindKey);
	if (k)
		CFStringGetCString(k, kind, sizeof(kind), kCFStringEncodingUTF8);
	if (agent_sweeps(k ? kind : NULL, CFDictionaryGetValue(d, kDADiskDescriptionVolumePathKey) != NULL))
		automount(bsd);
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
	DARegisterDiskAppearedCallback(s, NULL, sweep_appeared, NULL);
	DASessionScheduleWithRunLoop(s, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	{
		CFRunLoopTimerContext tc = { 0, s, NULL, NULL, NULL };

		CFRunLoopAddTimer(CFRunLoopGetCurrent(),
				  CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 3, 0, 0, 0, sweep_end, &tc),
				  kCFRunLoopDefaultMode);
	}
}

int main(int argc, char **argv)
{
	char dir[1024], path[1024];
	const char *delay;
	CFSocketRef cs;
	CFRunLoopSourceRef src;
	int fd;

	if (argc == 3 && strcmp(argv[1], "--offer") == 0)
		return offer_main(argv[2]);
	if (argc != 1) {
		fprintf(stderr, "usage: linuxfs-agent\n       linuxfs-agent --offer DISK     (the password on stdin)\n");
		return 2;
	}
	openlog("linuxfs-agent", LOG_PERROR | LOG_PID, LOG_USER);
	cli = env_or("LINUXFS_CLI", PREFIX "/bin/linuxfs");
	use_keychain = strcmp(env_or("LINUXFS_KEYCHAIN", "on"), "off") != 0;
	session = DASessionCreate(NULL);
	if (!session) {
		syslog(LOG_ERR, "no DiskArbitration session");
		return 1;
	}
	if (!paths(dir, sizeof(dir), path, sizeof(path)) || (fd = listen_on(dir, path)) < 0) {
		syslog(LOG_ERR, "cannot listen on the keychain socket under %s", getenv("HOME") ? getenv("HOME") : "(no HOME)");
		return 1;
	}
	cs = CFSocketCreateWithNative(NULL, fd, kCFSocketAcceptCallBack, accepted, NULL);
	src = cs ? CFSocketCreateRunLoopSource(NULL, cs, 0) : NULL;
	if (!src) {
		syslog(LOG_ERR, "cannot watch the keychain socket");
		return 1;
	}
	CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
	delay = geteuid() == 0 ? NULL : getenv("LINUXFS_SWEEP_DELAY");
	CFRunLoopAddTimer(CFRunLoopGetCurrent(),
			  CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + (delay && *delay ? atof(delay) : SWEEP_DELAY),
					       0, 0, 0, sweep, NULL),
			  kCFRunLoopDefaultMode);
	CFRunLoopAddTimer(CFRunLoopGetCurrent(),
			  CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0, reap, NULL),
			  kCFRunLoopDefaultMode);
	syslog(LOG_NOTICE, "keeping the keychain at %s", path);
	CFRunLoopRun();
	return 0;
}
#endif
