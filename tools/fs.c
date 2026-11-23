/*
 * linuxfs-fs: the one program inside each filesystem bundle (/System/Library/Filesystems/linuxfs_<fs>.fs), copied
 * under three names -- linuxfs_<fs>.util (probe), mount_linuxfs_<fs>, fsck_linuxfs_<fs> -- that picks its role and
 * its filesystem from argv[0]. DiskArbitration runs it as root with a bare environment, so everything here is C
 * and nothing is ever executed. Decisions come from fsrules.c; superblocks from probe.c.
 *
 * util -p BSD removable|fixed readonly|writable   recognised: the volume name on stdout, exit 255; else exit 254
 * util -k BSD                                     the filesystem's UUID on stdout, exit 255; else exit 254
 * fsck -q DEV                                     exit 0 (a quick check has nothing to do); -n or -y exit 8
 * mount [-o OPT]... DEV MNT                       as the console user: runs the CLI's da-mount and, for an encrypted volume,
 *                                                  asks for the password (the keychain keeper first, then Apple's dialog);
 *                                                  as root: not yet (exit 1)
 */
#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <signal.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>
#include "fsrules.h"
#include "probe.h"

#define FSUR_RECOGNIZED 255
#define FSUR_UNRECOGNIZED 254
#define PREFS_NAME "dev.mavergreen.linuxfs.plist"
#define PREFS_MAX (1024 * 1024)

struct ids { gid_t groups[128], egid; int ngroups; };

/* Becomes uid (egid gid, no supplementary groups) from root, saving root's in *save. 0 when done; -1 when not, with
 * root's ids back. No syslog while dropped. */
static int drop_to(uid_t uid, gid_t gid, struct ids *save)
{
	save->egid = getegid();
	save->ngroups = getgroups(128, save->groups);
	if (save->ngroups < 0)
		return -1;
	if (setgroups(0, NULL) == 0 && setegid(gid) == 0 && seteuid(uid) == 0)
		return 0;
	if (seteuid(0) != 0 || setegid(save->egid) != 0 || setgroups(save->ngroups, save->groups) != 0)
		_exit(FSUR_UNRECOGNIZED);
	return -1;
}

/* root again, in reverse order; failing to is fatal: never go on as the user */
static void restore_root(const struct ids *save)
{
	if (seteuid(0) != 0 || setegid(save->egid) != 0 || setgroups(save->ngroups, save->groups) != 0)
		_exit(FSUR_UNRECOGNIZED);
}

/* the plist at path, owned by uid (or by root too when also_root), a regular file that is not a symlink and at most
 * 1 MiB; NULL for anything else, including unparseable. With drop, from root, it is opened and read as uid/gid (no
 * other groups), so root's reach never extends into what the user can name; root is back before it is parsed. */
static CFDictionaryRef load_plist(const char *path, uid_t uid, gid_t gid, int also_root, int drop)
{
	struct stat st;
	struct ids saved;
	int fd, dropped = 0;
	char *buf = NULL;
	size_t got = 0;
	CFDictionaryRef dict = NULL;

	if (drop && uid != 0 && geteuid() == 0) {
		if (drop_to(uid, gid, &saved) != 0)
			return NULL;
		dropped = 1;
	}
	fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
	if (fd >= 0) {
		if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size <= PREFS_MAX &&
		    (st.st_uid == uid || (also_root && st.st_uid == 0)) && (buf = malloc((size_t)st.st_size + 1)) != NULL) {
			while (got < (size_t)st.st_size) {
				ssize_t r = read(fd, buf + got, (size_t)st.st_size - got);

				if (r <= 0)
					break;
				got += (size_t)r;
			}
			if (got != (size_t)st.st_size)
				got = 0;
		}
		close(fd);
	}
	if (dropped)
		restore_root(&saved);
	if (buf && got > 0) {
		CFDataRef data = CFDataCreate(NULL, (const UInt8 *)buf, (CFIndex)got);
		CFPropertyListRef pl = data ? CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL) : NULL;

		if (pl && CFGetTypeID(pl) == CFDictionaryGetTypeID())
			dict = pl;
		else if (pl)
			CFRelease(pl);
		if (data)
			CFRelease(data);
	}
	free(buf);
	return dict;
}

/* a preference as a boolean (also 1/0 and "YES"/"NO"/"true"/"false"), or -1 when absent or not one */
static int pref_bool(CFDictionaryRef d, CFStringRef key)
{
	CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
	char s[16];

	if (!v)
		return -1;
	if (CFGetTypeID(v) == CFBooleanGetTypeID())
		return CFBooleanGetValue(v) ? 1 : 0;
	if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		int n;

		return CFNumberGetValue(v, kCFNumberIntType, &n) ? (n != 0) : -1;
	}
	if (CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString(v, s, sizeof s, kCFStringEncodingUTF8)) {
		if (!strcasecmp(s, "yes") || !strcasecmp(s, "true") || !strcmp(s, "1"))
			return 1;
		if (!strcasecmp(s, "no") || !strcasecmp(s, "false") || !strcmp(s, "0"))
			return 0;
	}
	return -1;
}

static void pref_apply(CFDictionaryRef d, const char *label, struct fsprefs *p, int *have, int *ignored, int *ign_set)
{
	static const struct { const char *name; size_t off; } keys[] = {
		{ "Automount", offsetof(struct fsprefs, automount) },
		{ "ReadOnly", offsetof(struct fsprefs, readonly) },
		{ "NTFSTakeover", offsetof(struct fsprefs, ntfs_takeover) },
		{ "APFSWrite", offsetof(struct fsprefs, apfs_write) },
	};
	size_t i;

	for (i = 0; i < sizeof keys / sizeof keys[0]; i++) {
		CFStringRef k = CFStringCreateWithCString(NULL, keys[i].name, kCFStringEncodingUTF8);
		int v = k ? pref_bool(d, k) : -1;

		if (k)
			CFRelease(k);
		if (v >= 0 && !have[i]) {
			*(int *)((char *)p + keys[i].off) = v;
			have[i] = 1;
		}
	}
	if (label && *label) {
		char key[512];
		CFStringRef k;

		snprintf(key, sizeof key, "Ignore:%s", label);
		k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
		if (k) {
			int v = *ign_set ? -1 : pref_bool(d, k);

			if (v >= 0) {
				*ignored = v;
				*ign_set = 1;
			}
			CFRelease(k);
		}
	}
}

/* Fills p from the console user's plist, then the machine's, then the defaults, key by key; *ignored says the
 * label is marked Ignore:<LABEL>. A plist that cannot be read or parsed counts as absent. When not root the paths
 * (and who must own them: the caller) come from LINUXFS_PREFS_USER and LINUXFS_PREFS_MACHINE if set. */
int fs_read_prefs(struct fsprefs *p, const char *label, int *ignored)
{
	char userpath[1024], machpath[1024];
	const char *up = NULL, *mp = "/Library/Preferences/" PREFS_NAME;
	uid_t uowner, mowner = 0;
	gid_t ugid = 0;
	int also_root = 1, have[4] = { 0, 0, 0, 0 }, ign_set = 0;
	CFDictionaryRef ud, md;

	fsrules_default_prefs(p);
	*ignored = 0;
	if (getuid() != 0 && (getenv("LINUXFS_PREFS_USER") || getenv("LINUXFS_PREFS_MACHINE"))) {
		const char *u = getenv("LINUXFS_PREFS_USER"), *m = getenv("LINUXFS_PREFS_MACHINE");

		up = u;
		if (m)
			mp = m;
		uowner = mowner = getuid();
		ugid = getgid();
		also_root = 0;
	} else {
		struct stat st;
		struct passwd *pw;

		uowner = (uid_t)-1;
		if (stat("/dev/console", &st) == 0 && st.st_uid != 0 && (pw = getpwuid(st.st_uid)) != NULL &&
		    pw->pw_dir && pw->pw_dir[0] == '/' &&
		    snprintf(userpath, sizeof userpath, "%s/Library/Preferences/" PREFS_NAME, pw->pw_dir) < (int)sizeof userpath) {
			up = userpath;
			uowner = st.st_uid;
			ugid = pw->pw_gid;
		}
	}
	snprintf(machpath, sizeof machpath, "%s", mp);
	ud = up ? load_plist(up, uowner, ugid, 0, 1) : NULL;
	md = load_plist(machpath, mowner, 0, also_root, 0);
	if (ud)
		pref_apply(ud, label, p, have, ignored, &ign_set);
	if (md)
		pref_apply(md, label, p, have, ignored, &ign_set);
	if (ud)
		CFRelease(ud);
	if (md)
		CFRelease(md);
	return 0;
}

/* disk[0-9]+(s[0-9]+)? */
static int valid_bsd(const char *s)
{
	const char *q = s;

	if (strncmp(q, "disk", 4) != 0)
		return 0;
	q += 4;
	if (!isdigit((unsigned char)*q))
		return 0;
	while (isdigit((unsigned char)*q))
		q++;
	if (*q == 's') {
		q++;
		if (!isdigit((unsigned char)*q))
			return 0;
		while (isdigit((unsigned char)*q))
			q++;
	}
	return *q == '\0' && q - s <= 32;
}

/* Probes /dev/r<bsd>; the type or NULL (logged) */
static const char *probe_bsd(const char *bsd, char *label, size_t labellen)
{
	char path[64];
	int fd, err = 0;
	const char *type;

	label[0] = '\0';
	snprintf(path, sizeof path, "/dev/r%s", bsd);
	fd = open(path, O_RDONLY);
	if (fd < 0) {
		syslog(LOG_NOTICE, "%s: cannot open: %s", bsd, strerror(errno));
		return NULL;
	}
	type = linuxfs_probe_fd(fd, label, labellen, &err);
	close(fd);
	if (!type)
		syslog(LOG_NOTICE, "%s: %s", bsd, err ? strerror(err) : "no superblock it knows");
	return type;
}

static int util(const char *fs, int argc, char **argv)
{
	char label[256], name[256], uuid[40];
	const char *type;
	struct fsprefs p;
	int ignored, removable;

	if (argc == 5 && strcmp(argv[1], "-p") == 0) {
		if (!valid_bsd(argv[2]) || (strcmp(argv[3], "removable") && strcmp(argv[3], "fixed")) ||
		    (strcmp(argv[4], "readonly") && strcmp(argv[4], "writable"))) {
			syslog(LOG_NOTICE, "%s util: bad -p arguments", fs);
			return FSUR_UNRECOGNIZED;
		}
		removable = strcmp(argv[3], "removable") == 0;
		type = probe_bsd(argv[2], label, sizeof label);
		if (!type)
			return FSUR_UNRECOGNIZED;
		if (strcmp(type, fsrules_probe_type(fs)) != 0) {
			syslog(LOG_NOTICE, "%s: %s is not for the %s bundle", argv[2], type, fs);
			return FSUR_UNRECOGNIZED;
		}
		fs_read_prefs(&p, label, &ignored);
		if (ignored) {
			syslog(LOG_NOTICE, "%s: %s found, ignored by the user's choice", argv[2], type);
			return FSUR_UNRECOGNIZED;
		}
		if (!fsrules_claims(fs, type, removable, &p)) {
			syslog(LOG_NOTICE, "%s: %s (%s) is not for the %s bundle", argv[2], type, removable ? "removable" : "fixed", fs);
			return FSUR_UNRECOGNIZED;
		}
		fsrules_volname(label, name, sizeof name);
		printf("%s\n", name);
		syslog(LOG_NOTICE, "%s: %s claimed (%s)", argv[2], type, removable ? "removable" : "fixed");
		return FSUR_RECOGNIZED;
	}
	if (argc == 3 && strcmp(argv[1], "-k") == 0) {
		struct fsprefs all = { .automount = 1, .readonly = 0, .ntfs_takeover = 1, .apfs_write = 1 };

		if (!valid_bsd(argv[2])) {
			syslog(LOG_NOTICE, "%s util: bad -k argument", fs);
			return FSUR_UNRECOGNIZED;
		}
		type = probe_bsd(argv[2], label, sizeof label);
		if (!type || !fsrules_claims(fs, type, 1, &all) || linuxfs_probe_uuid(uuid, sizeof uuid) != 0) {
			syslog(LOG_NOTICE, "%s: no UUID for the %s bundle", argv[2], fs);
			return FSUR_UNRECOGNIZED;
		}
		printf("%s\n", uuid);
		return FSUR_RECOGNIZED;
	}
	syslog(LOG_NOTICE, "%s util: unknown arguments", fs);
	return FSUR_UNRECOGNIZED;
}

static int fsck(const char *fs, int argc, char **argv)
{
	if (argc >= 2 && argc <= 3 && strcmp(argv[1], "-q") == 0)
		return 0;
	if (argc >= 2 && argc <= 3 && (strcmp(argv[1], "-n") == 0 || strcmp(argv[1], "-y") == 0)) {
		printf("Verify and Repair for %s come with its tools\n", fs);
		syslog(LOG_NOTICE, "fsck_%s: verify/repair refused (phase 1)", fs);
		return 8;
	}
	fprintf(stderr, "usage: fsck_linuxfs_%s -q|-n|-y device\n", fs);
	syslog(LOG_NOTICE, "fsck_%s: unknown arguments", fs);
	return 8;
}

/* ---- the mount role, as the console user ---------------------------------------------------------------------- */

#define CLI_DEFAULT "/usr/local/mavergreen/linuxfs/bin/linuxfs"
#define CAPTURE_MAX (64 * 1024)
#define LOG_LINES 100
#define PW_MAX 1024
#define KC_DEADLINE_MS 5000
#define DIALOG_SECONDS 120
#define DIALOG_TRIES 3

/* LINUXFS_CLI, LINUXFS_DIALOG and LINUXFS_KEYCHAIN_SOCK are for tests, and never obeyed by root */
static const char *test_env(const char *name)
{
	return getuid() != 0 ? getenv(name) : NULL;
}

/* up to LOG_LINES lines of text to syslog, each prefixed by what */
static void log_lines(const char *what, const char *text)
{
	int n = 0;
	const char *p = text, *e;

	while (*p && n < LOG_LINES) {
		e = strchr(p, '\n');
		if (!e)
			e = p + strlen(p);
		if (e > p) {
			syslog(LOG_NOTICE, "%s: %.*s", what, (int)(e - p > 400 ? 400 : e - p), p);
			n++;
		}
		p = *e ? e + 1 : e;
	}
}

/* Runs argv with stdin from pw plus a newline (NULL: /dev/null) and stdout and stderr together captured into out
 * (outlen bytes, NUL-ended; the rest is read and dropped). Returns its exit status, or -1 when it could not run or
 * did not exit. */
static int run_capture(char *const argv[], const char *pw, char *out, size_t outlen)
{
	int inp[2] = { -1, -1 }, outp[2], st = -1, nul = -1, fd;
	size_t got = 0;
	pid_t pid;
	ssize_t r;

	out[0] = '\0';
	if (pw && pipe(inp) != 0)
		return -1;
	if (pipe(outp) != 0) {
		if (pw) {
			close(inp[0]);
			close(inp[1]);
		}
		return -1;
	}
	/* Every end is close-on-exec, so no descendant of the CLI (its backgrounded lklfuse) holds a pipe open: the read
	 * below must see EOF when the CLI exits, not when the mount ends. dup2 into 0-2 clears the flag on those. */
	if (pw) {
		fcntl(inp[0], F_SETFD, FD_CLOEXEC);
		fcntl(inp[1], F_SETFD, FD_CLOEXEC);
	} else {
		nul = open("/dev/null", O_RDONLY | O_CLOEXEC);
	}
	fcntl(outp[0], F_SETFD, FD_CLOEXEC);
	fcntl(outp[1], F_SETFD, FD_CLOEXEC);
	pid = fork();
	if (pid < 0) {
		if (pw) {
			close(inp[0]);
			close(inp[1]);
		}
		if (nul >= 0)
			close(nul);
		close(outp[0]);
		close(outp[1]);
		return -1;
	}
	if (pid == 0) {
		int in = pw ? inp[0] : nul;
		int o = outp[1];

		/* park the three on high fds first, so dup2 onto 0-2 cannot clobber one still needed */
		if (in >= 0 && in < 10)
			in = fcntl(in, F_DUPFD_CLOEXEC, 10);
		if (o < 10)
			o = fcntl(o, F_DUPFD_CLOEXEC, 10);
		if (in >= 0)
			dup2(in, 0);
		else
			close(0);
		dup2(o, 1);
		dup2(o, 2);
		for (fd = 3; fd < 1024; fd++)
			close(fd);
		signal(SIGPIPE, SIG_DFL);
		execv(argv[0], argv);
		_exit(127);
	}
	if (nul >= 0)
		close(nul);
	if (pw)
		close(inp[0]);
	close(outp[1]);
	if (pw) {
		size_t n = strlen(pw), off = 0;

		while (off < n && (r = write(inp[1], pw + off, n - off)) > 0)
			off += (size_t)r;
		(void)!write(inp[1], "\n", 1);
		close(inp[1]);
	}
	for (;;) {
		char tmp[4096];

		r = read(outp[0], tmp, sizeof tmp);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			break;
		if (got + (size_t)r < outlen) {
			memcpy(out + got, tmp, (size_t)r);
			got += (size_t)r;
		}
	}
	out[got] = '\0';
	close(outp[0]);
	while (waitpid(pid, &st, 0) < 0) {
		if (errno != EINTR)
			return -1;
	}
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* a keeper reply is whole once it has its lines: two after offered/saved, one after anything else */
static int reply_whole(const char *rep)
{
	int nl = 0;
	const char *p;

	for (p = rep; *p; p++)
		nl += *p == '\n';
	return nl >= ((strncmp(rep, "offered\n", 8) == 0 || strncmp(rep, "saved\n", 6) == 0) ? 2 : 1);
}

static char kc_home[1024]; /* the passwd home directory of the user we run as */
static int kc_hung; /* the keeper took its whole deadline without answering: no more requests to it */

/* One request to the keychain keeper (one per connection), its reply into rep (replen bytes, NUL-ended); the whole
 * conversation within KC_DEADLINE_MS. 0 on a reply, -1 on any failure. */
static int kc_ask(const char *req, size_t reqlen, char *rep, size_t replen)
{
	char path[1024];
	struct sockaddr_un sa;
	struct timeval t0, now;
	const char *over = test_env("LINUXFS_KEYCHAIN_SOCK");
	int fd, one = 1, rc = -1;
	size_t got = 0, sent = 0;

	rep[0] = '\0';
	if (kc_hung)
		return -1;
	if (over)
		snprintf(path, sizeof path, "%s", over);
	else if (!kc_home[0] ||
		 snprintf(path, sizeof path, "%s/Library/Caches/dev.mavergreen.linuxfs/keychain.sock", kc_home) >= (int)sizeof path)
		return -1;
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof sa.sun_path)
		return -1;
	strcpy(sa.sun_path, path);
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	gettimeofday(&t0, NULL);
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0 && errno != EINPROGRESS)
		goto done;
	while (rc != 0) {
		struct pollfd pf;
		long left;
		ssize_t r;

		pf.fd = fd;
		pf.events = POLLIN | (sent < reqlen ? POLLOUT : 0);
		pf.revents = 0;
		gettimeofday(&now, NULL);
		left = KC_DEADLINE_MS - ((long)(now.tv_sec - t0.tv_sec) * 1000 + (long)(now.tv_usec - t0.tv_usec) / 1000);
		if (left <= 0) {
			kc_hung = 1;
			goto done;
		}
		if (poll(&pf, 1, (int)left) < 0) {
			if (errno == EINTR)
				continue;
			goto done;
		}
		if (pf.revents == 0)
			continue;
		if ((pf.revents & POLLOUT) && sent < reqlen) {
			r = write(fd, req + sent, reqlen - sent);
			if (r > 0)
				sent += (size_t)r;
			else if (r < 0 && errno != EAGAIN && errno != EINTR)
				goto done;
		}
		if (pf.revents & (POLLIN | POLLHUP | POLLERR)) {
			r = read(fd, rep + got, replen - 1 - got);
			if (r > 0) {
				got += (size_t)r;
				rep[got] = '\0';
				if (reply_whole(rep))
					rc = 0;
				else if (got >= replen - 1)
					goto done;
			} else if (r == 0) {
				rc = reply_whole(rep) ? 0 : -1;
				break;
			} else if (errno != EAGAIN && errno != EINTR)
				goto done;
		}
	}
done:
	close(fd);
	return rc;
}

/* find: 0 with the password in pw and *saved set (offered 0, saved 1); -1 when there is none or no answer */
static int kc_find(const char *bsd, char *pw, size_t pwlen, int *saved)
{
	char req[64], rep[PW_MAX + 32], *p, *e;
	int n = snprintf(req, sizeof req, "find\t%s\n", bsd), rc = -1;

	if (n < 0 || (size_t)n >= sizeof req)
		return -1;
	if (kc_ask(req, (size_t)n, rep, sizeof rep) != 0) {
		syslog(LOG_NOTICE, "%s: the keychain keeper did not answer", bsd);
		goto out;
	}
	if (strncmp(rep, "offered\n", 8) == 0)
		*saved = 0, p = rep + 8;
	else if (strncmp(rep, "saved\n", 6) == 0)
		*saved = 1, p = rep + 6;
	else {
		syslog(LOG_NOTICE, "%s: the keychain keeper has no password", bsd);
		goto out;
	}
	e = strchr(p, '\n');
	if (e && e > p && (size_t)(e - p) < pwlen) {
		memcpy(pw, p, (size_t)(e - p));
		pw[e - p] = '\0';
		rc = 0;
		syslog(LOG_NOTICE, "%s: the keychain keeper offers a %s password", bsd, *saved ? "saved" : "offered");
	}
out:
	memset(rep, 0, sizeof rep);
	return rc;
}

/* save or forget; failures are only logged */
static void kc_tell(const char *verb, const char *bsd, const char *pw)
{
	char req[PW_MAX + 80], rep[64];
	int n = pw ? snprintf(req, sizeof req, "%s\t%s\n%s\n", verb, bsd, pw) : snprintf(req, sizeof req, "%s\t%s\n", verb, bsd);

	if (kc_hung) {
		syslog(LOG_NOTICE, "%s: the keychain keeper did not answer in time: not asking it to %s", bsd, verb);
		memset(req, 0, sizeof req);
		return;
	}
	if (n < 0 || (size_t)n >= sizeof req || kc_ask(req, (size_t)n, rep, sizeof rep) != 0)
		syslog(LOG_NOTICE, "%s: the keychain keeper did not take the %s", bsd, verb);
	else
		syslog(LOG_NOTICE, "%s: told the keychain keeper to %s", bsd, verb);
	memset(req, 0, sizeof req);
}

/* The password dialog. 0 with the password in pw (PW_MAX bytes) and *remember; 1 when Mount was pressed with the
 * field empty; -1 for Cancel, timeout or any failure. */
static int ask_dialog(const char *header, const char *message, char *pw, size_t pwlen, int *remember)
{
	const char *prog = test_env("LINUXFS_DIALOG");

	if (prog) {
		char out[PW_MAX + 32], *nl, *e;
		char *argv[] = { (char *)prog, (char *)header, (char *)message, NULL };
		int rc = run_capture(argv, NULL, out, sizeof out), ok = 0;

		if (rc == 0 && (nl = strchr(out, '\n')) != NULL) {
			*nl = '\0';
			if (strcmp(out, "remember") == 0 || strcmp(out, "once") == 0) {
				*remember = out[0] == 'r';
				e = strchr(nl + 1, '\n');
				if (e && (size_t)(e - (nl + 1)) < pwlen) {
					memcpy(pw, nl + 1, (size_t)(e - (nl + 1)));
					pw[e - (nl + 1)] = '\0';
					ok = 1;
				}
			}
		}
		memset(out, 0, sizeof out);
		return ok ? (pw[0] ? 0 : 1) : -1;
	} else {
		CFStringRef h = CFStringCreateWithCString(NULL, header, kCFStringEncodingUTF8);
		CFStringRef m = CFStringCreateWithCString(NULL, message, kCFStringEncodingUTF8);
		int ok = 0;

		if (!h) {
			syslog(LOG_NOTICE, "the dialog's header is not UTF-8: using a plain one");
			h = CFStringCreateWithCString(NULL, "Enter the password", kCFStringEncodingUTF8);
		}
		if (!m) {	/* the hint is the only free text in it: leave it out, never the dialog */
			char plain[400], *hp;

			syslog(LOG_NOTICE, "the dialog's message is not UTF-8: leaving out the hint");
			snprintf(plain, sizeof plain, "%s", message);
			if ((hp = strstr(plain, "Hint: ")) != NULL)
				*hp = '\0';
			while (*plain && plain[strlen(plain) - 1] == ' ')
				plain[strlen(plain) - 1] = '\0';
			m = CFStringCreateWithCString(NULL, plain, kCFStringEncodingUTF8);
		}
		CFStringRef field = CFSTR("Password"), box = CFSTR("Remember this password in my keychain");
		CFArrayRef fields = CFArrayCreate(NULL, (const void **)&field, 1, &kCFTypeArrayCallBacks);
		CFArrayRef boxes = CFArrayCreate(NULL, (const void **)&box, 1, &kCFTypeArrayCallBacks);
		CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
								     &kCFTypeDictionaryValueCallBacks);
		CFUserNotificationRef n = NULL;
		CFOptionFlags resp = 0;
		SInt32 err = 0, rc = -1;
		int empty = 0;

		if (h && m && fields && boxes && d) {
			CFDictionarySetValue(d, kCFUserNotificationAlertHeaderKey, h);
			CFDictionarySetValue(d, kCFUserNotificationAlertMessageKey, m);
			CFDictionarySetValue(d, kCFUserNotificationTextFieldTitlesKey, fields);
			CFDictionarySetValue(d, kCFUserNotificationCheckBoxTitlesKey, boxes);
			CFDictionarySetValue(d, kCFUserNotificationDefaultButtonTitleKey, CFSTR("Mount"));
			CFDictionarySetValue(d, kCFUserNotificationAlternateButtonTitleKey, CFSTR("Cancel"));
			n = CFUserNotificationCreate(NULL, DIALOG_SECONDS, kCFUserNotificationPlainAlertLevel | CFUserNotificationSecureTextField(0),
						     &err, d);
			if (n)
				rc = CFUserNotificationReceiveResponse(n, DIALOG_SECONDS, &resp);
			else
				syslog(LOG_NOTICE, "no dialog: CFUserNotificationCreate failed (%d)", (int)err);
			if (n && rc == 0 && (resp & 3) == kCFUserNotificationDefaultResponse) {
				CFStringRef v = CFUserNotificationGetResponseValue(n, kCFUserNotificationTextFieldValuesKey, 0);

				/* v is a CFString holding the password; CF gives no way to scrub it, only to release it */
				if (v && CFStringGetCString(v, pw, (CFIndex)pwlen, kCFStringEncodingUTF8) && pw[0]) {
					*remember = (resp & CFUserNotificationCheckBoxChecked(0)) != 0;
					ok = 1;
				} else {
					memset(pw, 0, pwlen);
					empty = 1;
				}
			} else if (n && rc != 0) {
				syslog(LOG_NOTICE, "the dialog timed out or failed (%d)", (int)rc);
				CFUserNotificationCancel(n);
			}
		}
		if (n)
			CFRelease(n);
		if (d)
			CFRelease(d);
		if (fields)
			CFRelease(fields);
		if (boxes)
			CFRelease(boxes);
		if (h)
			CFRelease(h);
		if (m)
			CFRelease(m);
		return ok ? 0 : (empty ? 1 : -1);
	}
}

/* the CLI, with the password (or none): its exit status, its captured output in out */
static int run_cli(const char *cli, const struct mountreq *req, const char *pw, char *out, size_t outlen)
{
	char *argv[8];
	int n = 0, rc;

	argv[n++] = (char *)cli;
	argv[n++] = "da-mount";
	if (req->asked)
		argv[n++] = "--asked";
	if (req->ro)
		argv[n++] = "--ro";
	if (pw)
		argv[n++] = "--password-stdin";
	argv[n++] = (char *)req->dev;
	argv[n++] = (char *)req->mnt;
	argv[n] = NULL;
	rc = run_capture(argv, pw, out, outlen);
	syslog(LOG_NOTICE, "%s: %s exited %d%s", req->dev, "linuxfs da-mount", rc, pw ? " (with a password)" : "");
	log_lines("linuxfs", out);
	return rc;
}

static int mount_role(const char *fs, int argc, char **argv)
{
	struct mountreq req;
	struct passwd *pw;
	const char *cli, *bsd, *base, *hintp;
	char *out, hint[256], header[400], message[400], pass[PW_MAX], saved_pw[PW_MAX];
	int rc, wrong = 0, tries, saved = 0, remember;

	openlog("linuxfs-mount", LOG_PID, LOG_DAEMON);
	if (fsrules_parse_mount(argc - 1, argv + 1, &req) != 0) {
		fprintf(stderr, "usage: mount_linuxfs_%s [-o options] device mountpoint\n", fs);
		syslog(LOG_NOTICE, "mount_%s: bad arguments", fs);
		return 1;
	}
	if (getuid() == 0) {
		syslog(LOG_NOTICE, "mount_%s: %s as root: not yet", fs, req.dev);
		return 1;
	}
	pw = getpwuid(getuid());
	if (!pw || !pw->pw_dir || pw->pw_dir[0] != '/') {
		syslog(LOG_NOTICE, "mount_%s: no home directory for uid %d", fs, (int)getuid());
		return 1;
	}
	snprintf(kc_home, sizeof kc_home, "%s", pw->pw_dir);
	setenv("HOME", pw->pw_dir, 1);
	setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
	setenv("LINUXFS_DA", "1", 1);
	signal(SIGPIPE, SIG_IGN);
	cli = test_env("LINUXFS_CLI");
	if (!cli || !*cli)
		cli = CLI_DEFAULT;
	bsd = strncmp(req.dev, "/dev/", 5) == 0 ? req.dev + 5 : req.dev;
	base = strrchr(req.mnt, '/');
	base = base && base[1] ? base + 1 : req.mnt;
	out = malloc(CAPTURE_MAX);
	if (!out)
		return 1;
	syslog(LOG_NOTICE, "mount_%s: %s on %s%s%s", fs, req.dev, req.mnt, req.asked ? " (asked)" : "", req.ro ? " (read-only)" : "");

	rc = run_cli(cli, &req, NULL, out, CAPTURE_MAX);
	if (rc != 4)
		goto out;
	hint[0] = '\0';
	hintp = fsrules_hint(out, hint, sizeof hint) ? hint : NULL;

	/* the keeper's password first, silently */
	if (kc_find(bsd, saved_pw, sizeof saved_pw, &saved) == 0) {
		rc = run_cli(cli, &req, saved_pw, out, CAPTURE_MAX);
		if (rc != 4) {
			memset(saved_pw, 0, sizeof saved_pw);
			goto out;
		}
		if (saved && strstr(out, "wrong password"))
			kc_tell("forget", bsd, NULL);
		if (fsrules_hint(out, hint, sizeof hint))
			hintp = hint;
		memset(saved_pw, 0, sizeof saved_pw);
	}

	for (tries = 0; tries < DIALOG_TRIES; tries++) {
		snprintf(header, sizeof header, "Enter the password for \xe2\x80\x9c%s\xe2\x80\x9d", base);
		snprintf(message, sizeof message, "%s%s%s", wrong ? "Wrong password." : "", wrong && hintp ? " " : "",
			 hintp ? "Hint: " : "");
		if (hintp)
			snprintf(message + strlen(message), sizeof message - strlen(message), "%s", hintp);
		rc = ask_dialog(header, message, pass, sizeof pass, &remember);
		if (rc > 0) {
			syslog(LOG_NOTICE, "mount_%s: %s: an empty password: asking again", fs, req.dev);
			continue;
		}
		if (rc != 0) {
			syslog(LOG_NOTICE, "mount_%s: %s: no password given", fs, req.dev);
			rc = 4;
			goto out;
		}
		rc = run_cli(cli, &req, pass, out, CAPTURE_MAX);
		if (rc == 0 && remember)
			kc_tell("save", bsd, pass);
		memset(pass, 0, sizeof pass);
		if (rc != 4)
			goto out;
		wrong = strstr(out, "wrong password") != NULL;
		if (fsrules_hint(out, hint, sizeof hint))
			hintp = hint;
	}
	rc = 4;
out:
	syslog(LOG_NOTICE, "mount_%s: %s: exit %d", fs, req.dev, rc);
	free(out);
	return rc < 0 ? 1 : rc;	/* the CLI could not run, or was killed */
}

int main(int argc, char **argv)
{
	enum fsrole role = FS_UTIL;
	const char *fs;

	openlog("linuxfs-fs", LOG_PID, LOG_DAEMON);
	fs = argc > 0 ? fsrules_fs_from_name(argv[0], &role) : NULL;
	if (!fs) {
		syslog(LOG_NOTICE, "run under a name that is no bundle's");
		return FSUR_UNRECOGNIZED;
	}
	switch (role) {
	case FS_UTIL:
		return util(fs, argc, argv);
	case FS_FSCK:
		return fsck(fs, argc, argv);
	case FS_MOUNT:
		return mount_role(fs, argc, argv);
	}
	return 1;
}
