/*
 * linuxfs-fs: the one program inside each filesystem bundle (/System/Library/Filesystems/macfuse_<fs>.fs), copied
 * under three names -- macfuse_<fs>.util (probe), mount_macfuse_<fs>, fsck_macfuse_<fs> -- that picks its role and
 * its filesystem from argv[0]. DiskArbitration runs it as root with a bare environment, so everything here is C
 * and nothing is ever executed. Decisions come from fsrules.c; superblocks from probe.c.
 *
 * util -p BSD removable|fixed readonly|writable   recognised: the volume name on stdout, exit 255; else exit 254
 * util -k BSD                                     the filesystem's UUID on stdout (no newline), exit 253; else exit 254
 * fsck -q DEV                                     exit 0 (a quick check has nothing to do); -n or -y exit 8
 * mount [-o OPT]... DEV MNT                       as the console user: asks root's mount daemon first (ask_mountd: the socket's
 *                                                  peer must be root; "ok" is exit 0 only with root's mount on MNT, "no RC" is
 *                                                  final, and only no daemon, "user", or no "begin" yet falls back, since
 *                                                  nothing was touched); else runs the CLI's da-mount and, for an encrypted volume,
 *                                                  asks for the password (the keychain keeper first, then Apple's dialog);
 *                                                  as root (never asking the daemon; the daemon's own child is root): takes the whole disk's lock (one mount of a disk at a time) and refuses
 *                                                  when anything is mounted on MNT or from the disk or its partitions already; opens /dev/rDEV as fd 3; then, with a macFUSE that
 *                                                  serves a /dev/fd/N mountpoint, runs the bundled CLI's da-mount as _linuxfs first,
 *                                                  until it is ready (nothing left that can fail before lklfuse starts), then runs
 *                                                  mount_macfuse itself (allow_other) and hands the device it sends to the CLI over
 *                                                  a channel (LINUXFS_FUSE_CHAN=6; fd 4 for lklfuse: LINUXFS_FUSE_FD=4), until
 *                                                  mount_macfuse reports the mount, all through paths that are root's alone
 *                                                  (path_trusted); with an older macFUSE, refuses ("too old to mount before login").
 *                                                  SIGTERM (the daemon's deadline) only sets a flag; every wait sees it, and root
 *                                                  stops the CLI's group (SIGTERM, up to 5 s, then SIGKILL), unmounts its own
 *                                                  mount, stops mount_macfuse (15 s at most) and exits 1. Once "ok" is decided,
 *                                                  SIGTERM is blocked: the mount stays and the exit is 0, never 1 beside a mount.
 *                                                  It says "cli-pgid N" on stderr once the CLI has its group.
 *
 * -DLINUXFS_FS_TEST_DROP (tests only, never in the shipped binary) takes the root path as whatever user runs it, up to the
 * drop: the privileged calls (initgroups, setgid, setuid) are replaced by printing the plan; the macFUSE manifest, the
 * mount helper, the CLI and the waits are the test's (LINUXFS_FS_TEST_*).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>
#include "fsrules.h"
#include "mountd.h"
#include "plist.h"
#include "probe.h"
#include "trust.h"

#define FSUR_RECOGNIZED 255
#define FSUR_IO_SUCCESS 253	/* sys/loadable_fs.h's (-3), as an exit status */
#define FSUR_UNRECOGNIZED 254

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
	int removable;

	if (argc == 5 && strcmp(argv[1], "-p") == 0) {
		if (!fsrules_valid_bsd(argv[2]) || (strcmp(argv[3], "removable") && strcmp(argv[3], "fixed")) ||
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
		prefs_read(&p);
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
		struct fsprefs all = { .readonly = 0, .ntfs_takeover = 1, .apfs_write = 1 };

		if (!fsrules_valid_bsd(argv[2])) {
			syslog(LOG_NOTICE, "%s util: bad -k argument", fs);
			return FSUR_UNRECOGNIZED;
		}
		type = probe_bsd(argv[2], label, sizeof label);
		if (!type || !fsrules_claims(fs, type, 1, &all) || linuxfs_probe_uuid(uuid, sizeof uuid) != 0) {
			syslog(LOG_NOTICE, "%s: no UUID for the %s bundle", argv[2], fs);
			return FSUR_UNRECOGNIZED;
		}
		/* as hfs.util: no newline, and FSUR_IO_SUCCESS, which is the status DiskArbitration takes a -k answer on (any other,
		 * FSUR_RECOGNIZED included, and the volume has no UUID to it, so a UUID= fstab entry never matches) */
		printf("%s", uuid);
		syslog(LOG_NOTICE, "%s: UUID %s for the %s bundle", argv[2], uuid, fs);
		return FSUR_IO_SUCCESS;
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
	fprintf(stderr, "usage: fsck_macfuse_%s -q|-n|-y device\n", fs);
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

/* LINUXFS_CLI, LINUXFS_DIALOG, LINUXFS_KEYCHAIN_SOCK, LINUXFS_MNTTAB and the mount daemon's LINUXFS_MOUNTD_SOCK, LINUXFS_MOUNTD_PEER_UID,
 * LINUXFS_MOUNTD_WAIT and LINUXFS_MOUNTD_PREBEGIN_WAIT are for tests, and never obeyed by root */
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

/* Runs argv (with environment envp, or ours when NULL) with stdin from pw plus a newline (NULL: /dev/null) and stdout and
 * stderr together captured into out (outlen bytes, NUL-ended; the rest is read and dropped). Every descriptor above keep_to
 * (and above 2) is closed in the child; 3 to keep_to (-1: none) it inherits as they are. Returns its exit status, or -1 when
 * it could not run or did not exit. */
static int run_capture(char *const argv[], char *const envp[], const char *pw, int keep_to, char *out, size_t outlen)
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
		if (o < 0 || (pw || nul >= 0 ? in < 0 : 0))
			_exit(127);
		if (in >= 0)
			dup2(in, 0);
		else
			close(0);
		dup2(o, 1);
		dup2(o, 2);
		for (fd = keep_to < 3 ? 3 : keep_to + 1; fd < getdtablesize(); fd++)
			close(fd);
		signal(SIGPIPE, SIG_DFL);
		if (envp)
			execve(argv[0], argv, envp);
		else
			execv(argv[0], argv);
		_exit(127);
	}
	if (nul >= 0)
		close(nul);
	if (pw)
		close(inp[0]);
	close(outp[1]);
	/* 3 to keep_to are the child's now: ours would keep a channel on keep_to from ever reading as closed while it runs */
	for (fd = 3; fd <= keep_to; fd++)
		if (fd != outp[0] && fd != inp[1])	/* (our own pipe ends may have taken numbers there) */
			close(fd);
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
	if (!e || e == p || (size_t)(e - p) >= pwlen)
		syslog(LOG_NOTICE, "%s: the keychain keeper's reply has no usable password line", bsd);
	else {
		memcpy(pw, p, (size_t)(e - p));
		pw[e - p] = '\0';
		rc = 0;
		syslog(LOG_NOTICE, "%s: the keychain keeper offers a password (%s)", bsd, *saved ? "saved" : "offered");
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
 * field empty; 2 when the field's text could not be read (too long); -1 for Cancel, timeout or any failure. */
static int ask_dialog(const char *header, const char *message, char *pw, size_t pwlen, int *remember)
{
	const char *prog = test_env("LINUXFS_DIALOG");

	if (prog) {
		char out[PW_MAX + 32], *nl, *e;
		char *argv[] = { (char *)prog, (char *)header, (char *)message, NULL };
		int rc = run_capture(argv, NULL, NULL, -1, out, sizeof out), ok = 0;

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
					empty = v && CFStringGetLength(v) > 0 ? 2 : 1;
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
		return ok ? 0 : (empty ? empty : -1);
	}
}

/* the CLI, with the password (or none): its exit status, its captured output in out */
static int run_cli(const char *cli, const struct mountreq *req, const char *pw, char *out, size_t outlen)
{
	char *argv[9];	/* cli da-mount --ro --owners --password-stdin DEV MNT NULL */
	int n = 0, rc;

	argv[n++] = (char *)cli;
	argv[n++] = "da-mount";
	if (req->ro)
		argv[n++] = "--ro";
	if (req->owners)
		argv[n++] = "--owners";
	if (pw)
		argv[n++] = "--password-stdin";
	argv[n++] = (char *)req->dev;
	argv[n++] = (char *)req->mnt;
	argv[n] = NULL;
	rc = run_capture(argv, NULL, pw, -1, out, outlen);
	syslog(LOG_NOTICE, "%s: %s exited %d%s", req->dev, "linuxfs da-mount", rc, pw ? " (with a password)" : "");
	log_lines("linuxfs", out);
	return rc;
}


#ifndef OPTS_MAX
#define OPTS_MAX 400	/* mount_macfuse's -o list; the test build shrinks it to force the refusal */
#endif
#define PRIV_DIR "/Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d"
#define RUN_USER "_linuxfs"
#define MOUNT_MACFUSE "/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse"
#define MACFUSE_MANIFEST "/usr/local/mavergreen/macfuse/mavergreen.plist"
#define LIBFUSE "/usr/local/lib/libfuse3.4.dylib"	/* lklfuse, as _linuxfs, loads this */
/* The first Mavergreen macFUSE release that ships the fd-mountpoint patch (its libfuse 3 serves a /dev/fd/N mountpoint
 * another process mounted: macfuse's DETAILS.md, "A mount made for you"): the gate for mounting before login at all. build/package.sh's
 * MACFUSE_MIN is later (5.5.0-mavericks.4), enforced only at install time: .4 is the install floor (the 10.9 job runs
 * components/macfuse/version, 5.5.0-mavericks.5, whose name pass-through lklfuse gates on its own), and it carries the
 * single-threaded-loop fix. lklfuse's ending on SIGTERM on 10.9 was LKL's setjmp saving the signal mask (patches/0011), not
 * macFUSE's; .2 and .3 with that patch are untested, so a macFUSE replaced later by one of them passes this gate. Dev builds
 * labelled 5.5.0-mavericks.2 that predate the patch exist: on those the gate passes, lklfuse cannot serve /dev/fd/N, and
 * root's mount fails, bounded, after STATUS_WAIT_S. */
#define MACFUSE_FD_MOUNTPOINT_SINCE "5.5.0-mavericks.2"
#define FUSE_FD 4		/* the macFUSE device, in lklfuse (placed there by linuxfs-open): beside the disk on 3, and not 5 (the password's) */
#define CHAN_FD 6		/* the CLI's end of its channel to root: "ready" out, the macFUSE device in */
#define READY_WAIT_S 30		/* for the CLI to finish everything it can know before the mount, and say so */
#define DEVICE_WAIT_S 30	/* for mount_macfuse to send the device */
#define STATUS_WAIT_S 60	/* for its mount status: mount(2) ends when lklfuse answers the kernel's INIT */
#define REFUSED_WAIT_S 5	/* for that status after the CLI failed (its descriptors closed, the mount fails) */
#define STOP_WAIT_S 2		/* for a process told to stop, before SIGKILL */
#define LOCK_DIR "/var/db/dev.mavergreen.linuxfs.locks"	/* the disks' locks: LOCK_DIR/dev.mavergreen.linuxfs.mount.<whole disk>.lock */
#define LOCK_FD_MIN 10		/* the locks' descriptors, at or above this: clear of the disk (3), the device (4), 5 and the channel (6) */
#define STR_(x) #x
#define STR(x) STR_(x)
#define ROOT_CLI_ENV "HOME=/private/var/db/linuxfs", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LINUXFS_DA=1", "LINUXFS_ALL_USERS=1", \
	"LINUXFS_OPEN_INHERITED=1", "LINUXFS_LKLFUSE=" PRIV_DIR "/lklfuse", "LINUXFS_PROBE=" PRIV_DIR "/linuxfs-probe", \
	"LINUXFS_OPEN=" PRIV_DIR "/linuxfs-open"

/* A refusal as root: syslog and stderr, with a fixed reason and never the caller's text */
static int refuse(const char *what, const char *reason)
{
	syslog(LOG_NOTICE, "mount_%s: refused: %s", what, reason);
	fprintf(stderr, "linuxfs-mount: refused: %s\n", reason);
	return 1;
}

/* SIGTERM, the daemon's deadline (root-daemon design I4, N3): the handler only sets this flag, and is installed without SA_RESTART, so
 * a poll, read, recv or sleep it lands in returns early (EINTR) and every wait checks the flag before going round. It never unmounts,
 * opens or does anything with a path: lock_disk briefly fchdirs into the locks' directory. */
static volatile sig_atomic_t stopping;
static void on_sigterm(int sig)
{
	(void)sig;
	stopping = 1;
}

/* a fatal early failure: syslog, then exit 1 */
static void die(const char *what)
{
	syslog(LOG_NOTICE, "mount_root: %s", what);
	_exit(1);
}

#ifdef LINUXFS_FS_TEST_DROP
#define ROOT_ONLY_UID geteuid()	/* the tests' stand-in for root: whoever runs the test build owns the mount point */
#define ROOT_ONLY_GID getegid()	/* and its group stands in for root's (the locks' directory) */
static const char *volumes_dir(void) { const char *v = getenv("LINUXFS_FS_TEST_VOLUMES"); return v && *v ? v : "/Volumes"; }
static const char *run_user(void) { const char *u = getenv("LINUXFS_FS_TEST_USER"); return u && *u ? u : RUN_USER; }
/* no manifest unless the test names one, so a macFUSE installed here never changes the plan */
static const char *macfuse_manifest(void) { const char *v = getenv("LINUXFS_FS_TEST_MACFUSE"); return v && *v ? v : "/nonexistent"; }
static const char *mount_helper(void) { const char *v = getenv("LINUXFS_FS_TEST_MOUNT_HELPER"); return v && *v ? v : MOUNT_MACFUSE; }
static int wait_s(int s) { const char *v = getenv("LINUXFS_FS_TEST_WAIT"); return v && atoi(v) > 0 ? atoi(v) : s; }
/* LINUXFS_FS_TEST_NOKILL: SIGKILL becomes a no-op, for a stand-in that outlives it as a process in an uninterruptible wait would */
static int kill_sig(void) { return getenv("LINUXFS_FS_TEST_NOKILL") ? 0 : SIGKILL; }
/* path_trusted checks nothing at or above this directory: the tests' files are under the user's home, not under root's */
static const char *trust_root(void) { const char *v = getenv("LINUXFS_FS_TEST_TRUST_ROOT"); return v && *v ? v : NULL; }
/* lklfuse's libfuse is checked in a test build only when the test names one */
static const char *libfuse_path(void) { const char *v = getenv("LINUXFS_FS_TEST_LIBFUSE"); return v && *v ? v : NULL; }
static const char *lock_dir(void) { const char *v = getenv("LINUXFS_FS_TEST_LOCKDIR"); return v && *v ? v : LOCK_DIR; }
#else
#define ROOT_ONLY_UID 0
#define ROOT_ONLY_GID 0
static const char *volumes_dir(void) { return "/Volumes"; }
static const char *run_user(void) { return RUN_USER; }
static const char *macfuse_manifest(void) { return MACFUSE_MANIFEST; }
static const char *mount_helper(void) { return MOUNT_MACFUSE; }
static int wait_s(int s) { return s; }
static int kill_sig(void) { return SIGKILL; }
static const char *trust_root(void) { return NULL; }
static const char *libfuse_path(void) { return LIBFUSE; }
static const char *lock_dir(void) { return LOCK_DIR; }
#endif

/* Whether root may trust the file at path: trust_path (trust.c) with root's uid (the tests' stand-in for it in a test build) and
 * the test build's trust root. 0 trusted; -1 writable by a user; -2 missing or not a regular file. out gets the resolved path. */
static int path_trusted(const char *path, char *out, size_t outlen)
{
	return trust_path(path, ROOT_ONLY_UID, trust_root(), out, outlen);
}

/* MNT is exactly <volumes>/<name>: one component, not . or .. */
static int valid_mnt_path(const char *mnt)
{
	const char *v = volumes_dir(), *name;
	size_t n = strlen(v);

	if (n > 0 && v[n - 1] == '/')	/* only a test's volumes directory can be "/" */
		n--;
	if (strncmp(mnt, v, n) != 0 || mnt[n] != '/')
		return 0;
	name = mnt + n + 1;
	return *name && strchr(name, '/') == NULL && strcmp(name, ".") != 0 && strcmp(name, "..") != 0;
}

/* descriptors 0-2 open (on /dev/null when closed), so nothing we open lands on them */
static void fill_std_fds(void)
{
	int fd;

	for (fd = 0; fd <= 2; fd++)
		if (fcntl(fd, F_GETFD) < 0 && open("/dev/null", O_RDWR) < 0)
			die("cannot open /dev/null for a closed standard descriptor");
}

/* A Mavergreen macFUSE version, A.B.C-mavericks.N, into v; 0, or -1 when it is not one */
static int macfuse_version(const char *s, unsigned v[4])
{
	static const char *const sep[] = { ".", ".", "-mavericks.", "" };
	int i;

	for (i = 0; i < 4; i++) {
		int digits = 0;

		v[i] = 0;
		while (isdigit((unsigned char)*s) && digits < 9) {
			v[i] = v[i] * 10 + (unsigned)(*s++ - '0');
			digits++;
		}
		if (!digits || strncmp(s, sep[i], strlen(sep[i])) != 0)
			return -1;
		s += strlen(sep[i]);
	}
	return *s ? -1 : 0;
}

/* Whether the installed macFUSE's libfuse serves a /dev/fd/N mountpoint: its manifest names a version at or past
 * MACFUSE_FD_MOUNTPOINT_SINCE. Logged either way. 1 when it does, 0 when it does not or the manifest is missing or unreadable
 * (not root's, a symlink, writable by anyone else), -1 when a directory above the manifest is writable by a user (path_trusted):
 * that tree is where mount_macfuse is run from, so the same trust rule applies. */
static int macfuse_serves_fd(const char *fs)
{
	char resolved[PATH_MAX], ver[64] = "";
	CFDictionaryRef d = NULL;
	CFTypeRef v;
	unsigned have[4], need[4];
	int i, ok = 0, t = path_trusted(macfuse_manifest(), resolved, sizeof resolved);

	if (t == -1) {
		syslog(LOG_NOTICE, "mount_%s: macFUSE's manifest is in a path writable by a user", fs);
		return -1;
	}
	if (t == 0)
		d = plist_load_owned(resolved, ROOT_ONLY_UID);
	v = d ? CFDictionaryGetValue(d, CFSTR("version")) : NULL;

	if (v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString(v, ver, sizeof ver, kCFStringEncodingUTF8) &&
	    macfuse_version(ver, have) == 0 && macfuse_version(MACFUSE_FD_MOUNTPOINT_SINCE, need) == 0) {
		ok = 1;
		for (i = 0; i < 4; i++)
			if (have[i] != need[i]) {
				ok = have[i] > need[i];
				break;
			}
	}
	if (d)
		CFRelease(d);
	if (ok)
		syslog(LOG_NOTICE, "mount_%s: macFUSE %s serves /dev/fd/N: root mounts, _linuxfs serves", fs, ver);
	else
		syslog(LOG_NOTICE, "mount_%s: macFUSE %s is before %s, which serves /dev/fd/N: too old to mount before login", fs,
		       ver[0] ? ver : "(no readable version)", MACFUSE_FD_MOUNTPOINT_SINCE);
	return ok;
}

/* Becomes the run user for good (groups, gids, uids, with no way back), with default signals, umask 022 and / as cwd.
 * 0, or 1 having refused. Test builds stay as they are. */
static int become_run_user(const char *fs, const char *name, uid_t uid, gid_t gid)
{
#ifndef LINUXFS_FS_TEST_DROP
	sigset_t none;

	if (initgroups(name, (int)gid) != 0 || setgid(gid) != 0 || setuid(uid) != 0 || getuid() != uid || geteuid() != uid ||
	    getgid() != gid || getegid() != gid || setuid(0) != -1)
		return refuse(fs, "could not drop to _linuxfs");
	signal(SIGPIPE, SIG_DFL);
	sigemptyset(&none);
	sigprocmask(SIG_SETMASK, &none, NULL);
	umask(022);
	if (chdir("/") != 0)
		die("cannot chdir to /");
#else
	(void)fs, (void)name, (void)uid, (void)gid;
#endif
	return 0;
}

/* The bundled CLI with envp, descriptors 3 to keep_to inherited; its output to syslog (nobody is logged in to read it). Its
 * exit status, or -1. */
static int root_cli(const struct mountreq *req, char **args, const char *const *envp, int keep_to, const char *name)
{
	char *cout = malloc(CAPTURE_MAX);
	int rc;

	if (!cout)
		die("out of memory");
	rc = run_capture(args, (char *const *)envp, NULL, keep_to, cout, CAPTURE_MAX);
	syslog(LOG_NOTICE, "%s: linuxfs da-mount exited %d (as %s)", req->dev, rc, name);
	log_lines("linuxfs", cout);
#ifdef LINUXFS_FS_TEST_DROP
	printf("cli-rc %d\ncli-out %.200s\n", rc, cout);
	fflush(stdout);
#endif
	free(cout);
	return rc;
}

#ifdef LINUXFS_FS_TEST_DROP
static void print_cli_plan(const char *const *envp, char **args)
{
	int i;

	for (i = 0; envp[i]; i++)
		printf("env %s\n", envp[i]);
	for (i = 0; args[i]; i++)
		printf("argv %s\n", args[i]);
	fflush(stdout);
}
#endif

/* The descriptor mount_macfuse sends over sock (SCM_RIGHTS, one byte) within secs; -1 when none; -4 when SIGTERM came; -2 when watch
 * (the CLI's channel, from which nothing more is due) hung up (POLLHUP) first, -3 when it became readable (POLLIN: unexpected data) first: a CLI
 * that has gone, or gone wrong, needs no mount_macfuse waiting for it. A message with anything but one descriptor is refused,
 * and every descriptor it carried is closed. */
static int recv_device(int sock, int secs, int watch)
{
	struct pollfd p[2] = { { sock, POLLIN, 0 }, { watch, POLLIN, 0 } };
	struct msghdr msg;
	struct iovec iov;
	struct cmsghdr *c;
	char b, cc[CMSG_SPACE(8 * sizeof(int))];
	struct timeval t0, now;
	int fd = -1, r, fds = 0, bad = 0;

	gettimeofday(&t0, NULL);
	for (;;) {
		long left;

		if (stopping)
			return -4;
		gettimeofday(&now, NULL);
		left = secs * 1000L - ((long)(now.tv_sec - t0.tv_sec) * 1000 + (long)(now.tv_usec - t0.tv_usec) / 1000);
		if (left <= 0)
			return -1;
		p[0].revents = p[1].revents = 0;
		r = poll(p, 2, left > 200 ? 200 : (int)left);	/* a SIGTERM just before the poll is seen within 200 ms */
		if (r > 0 && p[1].revents)
			return (p[1].revents & POLLHUP) ? -2 : -3;
		if (r > 0)
			break;
		if (r < 0 && errno != EINTR)
			return -1;
	}
	memset(&msg, 0, sizeof msg);
	iov.iov_base = &b;
	iov.iov_len = 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cc;
	msg.msg_controllen = sizeof cc;
	r = (int)recvmsg(sock, &msg, MSG_DONTWAIT);
	if (r != 1 || (msg.msg_flags & MSG_CTRUNC))
		bad = 1;
	for (c = r >= 0 ? CMSG_FIRSTHDR(&msg) : NULL; c; c = CMSG_NXTHDR(&msg, c)) {
		size_t k, nfd;

		if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS || c->cmsg_len < CMSG_LEN(0)) {
			bad = 1;
			continue;
		}
		nfd = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
		for (k = 0; k < nfd; k++) {
			int got;

			memcpy(&got, CMSG_DATA(c) + k * sizeof(int), sizeof got);
			if (fds++ == 0)
				fd = got;
			else
				close(got);
		}
	}
	if (bad || fds != 1) {
		if (fd >= 0)
			close(fd);
		return -1;
	}
#ifndef LINUXFS_FS_TEST_DROP
	{
		struct stat st;

		if (fstat(fd, &st) != 0 || !S_ISCHR(st.st_mode)) {	/* /dev/macfuseN, and nothing else */
			close(fd);
			return -1;
		}
	}
#endif
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	return fd;
}

/* The mount table, as getmntinfo(MNT_NOWAIT) gives it: the number of entries, in *m, or -1 when it cannot be read. MNT_NOWAIT
 * asks no file system (statfs of each would hang on a dead macFUSE mount), so there is no wait to bound. In a test build,
 * LINUXFS_FS_TEST_MNTTAB names a file of TYPE<TAB>FROM<TAB>ON<TAB>OWNER lines instead, the last on top, read at each call. */
static int mnt_table(struct statfs **m)
{
	int n;

#ifdef LINUXFS_FS_TEST_DROP
	const char *tab = getenv("LINUXFS_FS_TEST_MNTTAB");

	if (tab && *tab) {
		static struct statfs t[64];
		char line[3 * MAXPATHLEN + 64];
		FILE *f = fopen(tab, "r");

		if (!f)
			return -1;
		n = 0;
		while (n < (int)(sizeof t / sizeof t[0]) && fgets(line, sizeof line, f)) {
			char *a = line, *b, *c, *d;

			line[strcspn(line, "\n")] = '\0';
			if (!(b = strchr(a, '\t')) || !(c = strchr(b + 1, '\t')) || !(d = strchr(c + 1, '\t')))
				continue;
			*b++ = *c++ = *d++ = '\0';
			memset(&t[n], 0, sizeof t[n]);
			snprintf(t[n].f_fstypename, sizeof t[n].f_fstypename, "%s", a);
			snprintf(t[n].f_mntfromname, sizeof t[n].f_mntfromname, "%s", b);
			snprintf(t[n].f_mntonname, sizeof t[n].f_mntonname, "%s", c);
			t[n].f_owner = (uid_t)strtoul(d, NULL, 10);
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

/* What is mounted on MNT, judged by the topmost mount, the one unmount(MNT) would hit: 0 nothing; 1 root's own mount of FS
 * from /dev/BSD (fsrules_mount_is_roots: FS's macfuse_<fs> type, that source, owned by root); -1 something else, which is never
 * root's to unmount: an HFS+ volume from the same disk, a user's macFUSE mount, another of the six. The mount table is read with
 * MNT_NOWAIT, last entry first (a later mount on the same path is on top), rather than by statfs(MNT), which asks the file
 * system and so could hang on a dead macFUSE mount: no wait to bound. */
static int mounted_on(const char *fs, const char *mnt, const char *bsd)
{
	struct statfs *m;
	int n, i;

	n = mnt_table(&m);
	for (i = n - 1; i >= 0; i--)
		if (strcmp(m[i].f_mntonname, mnt) == 0)
			return fsrules_mount_is_roots(fs, bsd, m[i].f_fstypename, m[i].f_mntfromname, (unsigned)m[i].f_owner) ? 1 : -1;
	return 0;
}

/* Whether anything at all is mounted on MNT, or anything that refuses BSD (fsrules_mount_blocks: from /dev/BSD or its whole disk,
 * and for a whole disk from any of its partitions; any type, on any mount point): 0 nothing; 1 something; -1 when the mount table
 * cannot be read. Root mounts only where nothing is, so that its failure path (mounted_on) can only ever find its own mount:
 * f_owner 0 tells root's mount from a user's, not one root mount from another. A whole disk and its partitions exclude each
 * other: a stale superblock at the start of a partitioned disk must never be mounted over its mounted partitions. Sibling
 * partitions do not (final review r0 C1): each is its own volume, as HFS+'s are, and a disk with an HFS+ and an ext4 partition
 * mounts both. The window this leaves: from this check to mount_macfuse's mount(2), seconds (the CLI's READY_WAIT_S, then
 * DEVICE_WAIT_S), anything that does not take the disk's locks (diskarbitrationd, or a user's own mount of a disk image) can
 * still mount the disk elsewhere or MNT's directory over. The disk is then mounted twice; the failure path still unmounts only
 * the topmost mount on MNT, and only root's of this disk. */
static int mounted_already(const char *mnt, const char *bsd)
{
	struct statfs *m;
	int n, i;

	n = mnt_table(&m);
	if (n < 0)
		return -1;
	for (i = 0; i < n; i++)
		if (strcmp(m[i].f_mntonname, mnt) == 0 || fsrules_mount_blocks(m[i].f_mntfromname, bsd))
			return 1;
	return 0;
}

/* The locks' directory, LOCK_DIR (/var/db/dev.mavergreen.linuxfs.locks), opened. Its parent must be root's alone by trust.c's
 * rule (trust_root_only: /var/db is root:wheel 0755), checked first at each use: in a parent anyone else can write (/var/run is
 * root:daemon 0775), the directory itself could be renamed aside while a lock in it is held, and the next request would make a
 * fresh one. The directory is made on demand, root's (uid and gid 0) and 0700, and checked at each use, by lstat and by fstat of
 * the descriptor opened without following a symlink (the same directory both times): a directory of root's and root's group, mode
 * exactly 0700. Anything else, the parent included, is refused and never repaired. A directory mkdir made now is ours to give
 * root's group and 0700, but only when it is root's already. Its lock files stay (flocks end with their holders, and at reboot):
 * harmless, and the uninstaller removes them. The descriptor, or -1 having refused. */
static int lock_dir_open(const char *fs)
{
	const char *dir = lock_dir(), *slash = strrchr(dir, '/');
	char parent[PATH_MAX];
	struct stat lst, st;
	int dfd;

	if (!slash || (size_t)(slash - dir) >= sizeof parent) {
		refuse(fs, "the disks' lock directory has no parent");
		return -1;
	}
	memcpy(parent, dir, (size_t)(slash - dir));
	parent[slash == dir ? 1 : slash - dir] = '\0';
	if (slash == dir)
		parent[0] = '/';
	if (lstat(parent, &st) != 0 || !S_ISDIR(st.st_mode) || !trust_root_only(&st, ROOT_ONLY_UID)) {
		refuse(fs, "the disks' lock directory's parent is writable by others than root");
		return -1;
	}
	if (mkdir(dir, 0700) == 0) {
		dfd = open(dir, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
		if (dfd < 0 || fstat(dfd, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ROOT_ONLY_UID ||
		    fchown(dfd, ROOT_ONLY_UID, ROOT_ONLY_GID) != 0 || fchmod(dfd, 0700) != 0) {
			if (dfd >= 0)
				close(dfd);
			refuse(fs, "the disks' lock directory cannot be made root's alone");
			return -1;
		}
		close(dfd);
	} else if (errno != EEXIST) {
		refuse(fs, "the disks' lock directory cannot be made");
		return -1;
	}
	dfd = open(dir, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
	if (dfd < 0 || lstat(dir, &lst) != 0 || fstat(dfd, &st) != 0 || lst.st_dev != st.st_dev || lst.st_ino != st.st_ino ||
	    !S_ISDIR(st.st_mode) || st.st_uid != ROOT_ONLY_UID || st.st_gid != ROOT_ONLY_GID || (st.st_mode & 07777) != 0700) {
		if (dfd >= 0)
			close(dfd);
		refuse(fs, "the disks' lock directory is not root's alone (0700, not a symlink)");
		return -1;
	}
	return dfd;
}

/* A disk's lock, LOCK_DIR/dev.mavergreen.linuxfs.mount.<name>.lock, taken without waiting: flock OP (LOCK_EX or LOCK_SH). NAME is
 * a whole disk or a partition; lock_disks takes them in two levels. The file is opened relative to the checked directory's
 * descriptor (fchdir there and back: 10.9 has no openat), so a directory swapped after the check cannot redirect it. Its
 * descriptor, at or above LOCK_FD_MIN, is not close-on-exec: root's mount_macfuse inherits it (mount_by_root keeps it there), so
 * the lock lives as long as anything of root's for this mount does, and the CLI closes it before it becomes _linuxfs, so nothing of
 * _linuxfs's ever holds it. The file is opened without following a symlink, and must be a regular file of root's, 0600, with one
 * link; it is never removed (a removed lock file someone else still holds would let a second lock be taken). The descriptor, or -1
 * having refused. */
static int lock_disk(const char *fs, const char *whole, int op)
{
	char name[96], why[128];
	struct stat st;
	int dfd, cwd, fd, hi;

	if (snprintf(name, sizeof name, "dev.mavergreen.linuxfs.mount.%s.lock", whole) >= (int)sizeof name) {
		refuse(fs, "the disk's lock file's name is too long");
		return -1;
	}
	dfd = lock_dir_open(fs);
	if (dfd < 0)
		return -1;
	cwd = open(".", O_RDONLY | O_NOCTTY);
	if (cwd < 0 || fchdir(dfd) != 0) {
		if (cwd >= 0)
			close(cwd);
		close(dfd);
		refuse(fs, "cannot enter the disks' lock directory");
		return -1;
	}
	fd = open(name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY, 0600);
	if (fchdir(cwd) != 0)
		die("cannot return to the working directory");
	close(cwd);
	close(dfd);
	if (fd < 0) {
		refuse(fs, "the disk's lock file cannot be opened (or is a symlink)");
		return -1;
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != ROOT_ONLY_UID || (st.st_mode & 07777) != 0600 ||
	    st.st_nlink != 1) {
		close(fd);
		refuse(fs, "the disk's lock file is not a regular file of root's alone (0600, one link)");
		return -1;
	}
	hi = fcntl(fd, F_DUPFD, LOCK_FD_MIN);	/* the copy is not close-on-exec */
	close(fd);
	if (hi < 0) {
		refuse(fs, "cannot place the disk's lock");
		return -1;
	}
	if (flock(hi, op | LOCK_NB) != 0) {
		int e = errno;

		close(hi);
		if (e == EWOULDBLOCK) {
			snprintf(why, sizeof why, "another mount of %s is under way", whole);
			refuse(fs, why);
		} else
			refuse(fs, "the disk's lock cannot be taken");
		return -1;
	}
	return hi;
}

/* The locks for a mount of BSD, in two levels (final review r0 C1): a whole disk takes its own lock exclusive; a partition takes
 * its whole disk's lock shared, then its own exclusive. So the whole disk and its partitions exclude each other, one partition
 * mounts once at a time, and sibling partitions mount side by side. *PART is the partition's descriptor, or -1 for a whole disk.
 * The whole disk's descriptor, or -1 having refused (nothing held). */
static int lock_disks(const char *fs, const char *bsd, const char *whole, int *part)
{
	int w;

	*part = -1;
	if (strcmp(bsd, whole) == 0)
		return lock_disk(fs, whole, LOCK_EX);
	w = lock_disk(fs, whole, LOCK_SH);
	if (w < 0)
		return -1;
	*part = lock_disk(fs, bsd, LOCK_EX);
	if (*part < 0) {
		close(w);
		return -1;
	}
	return w;
}

#define CLEANUP_S 15	/* the failure path's waits in all, within the daemon's MOUNTD_GRACE */
static time_t cleanup_end;	/* set when the failure path starts: no wait after a SIGKILL goes past it */

/* Waits up to secs for pid; 1 with *st when it was reaped. A wait that may be cut short (stoppable) stops waiting once SIGTERM has
 * come; one after a SIGKILL never does (the process has to be reaped), but still ends by cleanup_end. */
static int reap_(pid_t pid, int secs, int *st, int stoppable)
{
	int i;

	for (i = 0; i < secs * 10; i++) {
		if (waitpid(pid, st, WNOHANG) == pid)
			return 1;
		if ((stoppable && stopping) || (cleanup_end && time(NULL) >= cleanup_end))
			return 0;
		usleep(100000);
	}
	return waitpid(pid, st, WNOHANG) == pid;
}

static int reap(pid_t pid, int secs, int *st)
{
	return reap_(pid, secs, st, 1);
}

/* the end of a request SIGTERM stopped: said, exit 1 */
static int stopped_by_sigterm(const char *fs)
{
	syslog(LOG_NOTICE, "mount_%s: stopped by SIGTERM", fs);
	fprintf(stderr, "linuxfs-mount: stopped by SIGTERM\n");
	return 1;
}

/* SIGTERM to process pid, then SIGKILL when it has not exited within term_s; reaped. One still there STOP_WAIT_S after the
 * SIGKILL (a mount(2) blocked on INIT may not be interruptible) is said, to syslog and stderr: never left silently. */
static void stop(const char *fs, pid_t pid, int term_s)
{
	int st;

	if (pid <= 0)
		return;
	kill(pid, SIGTERM);
	if (reap(pid, term_s, &st))
		return;
	kill(pid, kill_sig());
	if (reap_(pid, STOP_WAIT_S, &st, 0))
		return;
	syslog(LOG_NOTICE, "mount_%s: mount_macfuse (pid %d) is still running after SIGKILL; left", fs, (int)pid);
	fprintf(stderr, "linuxfs-mount: mount_macfuse (pid %d) is still running after SIGKILL; left\n", (int)pid);
}

/* "Ready" (exactly one byte, R) from the CLI on sock within secs. 1 when it came; 0 when the CLI ended first (its status, once
 * reaped, in *cli_rc and the time in *cli_end); -1 when the channel closed; -3 when it carried anything but that one byte; -2 on timeout;
 * -4 when SIGTERM came. */
static int wait_ready(int sock, pid_t cpid, int *cli_rc, time_t *cli_end, int secs)
{
	struct pollfd p = { sock, POLLIN, 0 };
	time_t end = time(NULL) + secs;
	int w;

	for (;;) {
		char b[16];
		ssize_t r;

		if (stopping)
			return -4;
		p.revents = 0;
		if (poll(&p, 1, 200) < 0) {
			if (errno == EINTR)
				continue;	/* the flag, at the top */
			return -1;
		}
		if (p.revents) {
			r = recv(sock, b, sizeof b, MSG_DONTWAIT);
			if (r == 1 && b[0] == 'R')
				return 1;
			if (r > 0)
				return -3;
			if (r == 0 || (errno != EINTR && errno != EAGAIN))
				return -1;
		}
		if (waitpid(cpid, &w, WNOHANG) == cpid) {
			*cli_rc = WIFEXITED(w) ? WEXITSTATUS(w) : 1;
			*cli_end = time(NULL);
			return 0;
		}
		if (time(NULL) >= end)
			return -2;
	}
}

/* The device to the CLI over sock: one byte and the descriptor, without blocking; 1 when sent */
static int send_device(int sock, int dev)
{
	struct msghdr msg;
	struct iovec iov;
	struct cmsghdr *c;
	char b = 'D', cc[CMSG_SPACE(sizeof(int))];

	memset(&msg, 0, sizeof msg);
	memset(cc, 0, sizeof cc);
	iov.iov_base = &b;
	iov.iov_len = 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cc;
	msg.msg_controllen = sizeof cc;
	c = CMSG_FIRSTHDR(&msg);
	c->cmsg_level = SOL_SOCKET;
	c->cmsg_type = SCM_RIGHTS;
	c->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(c), &dev, sizeof dev);
	return sendmsg(sock, &msg, MSG_DONTWAIT) == 1;
}

#define GROUP_WAIT_S 5	/* for the CLI's group (lklfuse: LKL's umount and sync) to end on its SIGTERM, before SIGKILL */

/* SIGTERM to process group pgid; then, once every process of it has ended (its leader reaped, when it has not been yet: running) or
 * after GROUP_WAIT_S (and never past cleanup_end), SIGKILL to whatever of it is left. Under the daemon's SIGTERM too: lklfuse
 * SIGKILLed before LKL's umount leaves a dirty volume (an NTFS one comes up read-only next time), and the failure path's CLEANUP_S
 * has room for it (task-16j-findings-r0.md I2, the controller's ruling). A leader reaped already (running 0) leaves the group's pgid
 * unusable by anyone else while any member lives, so kill(-pgid) still reaches only what was the CLI's (its lklfuse, its sleepers) */
static void stop_group(pid_t pgid, int running)
{
	int st, i;

	kill(-pgid, SIGTERM);
	for (i = 0; i < GROUP_WAIT_S * 10; i++) {
		if (running && waitpid(pgid, &st, WNOHANG) == pgid)
			running = 0;
		if (!running && kill(-pgid, 0) != 0 && errno == ESRCH)
			return;	/* all of it ended on SIGTERM */
		if (cleanup_end && time(NULL) >= cleanup_end)
			break;
		usleep(100000);
	}
	kill(-pgid, SIGKILL);
	if (running)
		reap_(pgid, STOP_WAIT_S, &st, 0);
}

/* Root's mount, for a macFUSE that serves /dev/fd/N (macfuse's DETAILS.md), in this order. (1) The CLI, as _linuxfs, runs with
 * its end of a channel on CHAN_FD (and the disk on 3, nothing else): it does everything it can know before the mount (the lock,
 * the probe, the access rule, the Fusion and ignore checks), and linuxfs-open writes "ready" on the channel just before lklfuse
 * would start. (2) Only then does root run mount_macfuse, which mounts MNT with allow_other (root's to give) and sends the
 * device; root passes it on over the channel (SCM_RIGHTS), and the CLI's linuxfs-open puts it on FUSE_FD for lklfuse, which
 * serves it through /dev/fd/FUSE_FD. A CLI that ends, or is not ready within READY_WAIT_S, never has a mount_macfuse run for
 * it. Root then waits, bounded, for mount_macfuse's status: 0 (and the CLI's 0) is exit 0; anything else stops what _linuxfs
 * started, unmounts MNT if it got mounted, stops mount_macfuse, and is the CLI's failure (or 1). Root never reads the file
 * system and never runs lklfuse. Every descriptor but 0-2 is closed in mount_macfuse but its socket and the disk's locks (lockfd,
 * and partfd for a partition: lock_disks; it holds them as long as it lives), and in the CLI all but 3 and CHAN_FD.
 * Unmounting (DiskArbitration, diskutil) ends lklfuse, which sees its device close. If lklfuse dies first the mount stays,
 * with nobody serving it: macFUSE fails its calls (a dead file system, ENXIO) rather than hang, and it still unmounts
 * (tests/smoke-mavericks.sh checks both). The one failure left after "ready" is lklfuse dying at startup, before it answers
 * INIT: mount_macfuse may then still hold its own copy of the device, blocked in mount(2): root's closing its copy cannot end
 * that wait, and macFUSE offers no ioctl that does (FUSEDEVIOCINTERRUPTREADERS wakes the device's readers, not the mount);
 * the kernel gives up by itself, EAGAIN after about 50 s (macfuse's smoke). So root stops it (stop()) and says so if even
 * SIGKILL leaves it running. */
static int mount_by_root(const char *fs, const struct mountreq *req, const char *bsd, int ro, const char *name, uid_t uid,
			 gid_t gid, char **args, int lockfd, int partfd)
{
	static const char *const vars[] = { ROOT_CLI_ENV, "LINUXFS_FUSE_FD=" STR(FUSE_FD), "LINUXFS_FUSE_CHAN=" STR(CHAN_FD), NULL };
	const struct fsname *nm;
	char opts[OPTS_MAX], vol[256], commenv[32], hout_buf[4096], rhelper[PATH_MAX];
	char daemon_env[] = "_FUSE_DAEMON_PATH=" PRIV_DIR "/lklfuse";
	char *hargv[5], *henv[5];
	const char *helper = mount_helper();
	int cs[2], ch[2], hout[2], devfd, fd, w, got = 0, cli_rc = -2, ok = 0, hstarted = 0;
	int32_t status = -1;
	size_t hgot = 0, sgot = 0;
	pid_t hpid = -1, cpid = -1;
	time_t deadline, cli_end = 0;

	fsrules_volname(strrchr(req->mnt, '/') + 1, vol, sizeof vol);
	nm = fsrules_name(fs);
	if (!nm)
		return refuse(fs, "no such filesystem");
	/* fsname=/dev/BSD, as HFS+'s mount is named: DiskArbitration ties the volume to its disk only through f_mntfromname (with
	 * linuxfs@BSD it lost the tie at the next mount or unmount of any volume, and its ejects failed 0x10: item 4), and so do
	 * diskutil info and Finder's external-disk presentation (item 6) */
	/* nosuid and nodev always: DiskArbitration asks both for every external disk, and only mount_macfuse running as a user
	 * gets them by itself (XNU adds them to a user's mount); root's had nodev only by macFUSE's own doing, unasked. With
	 * owners (item 6, "Ignore ownership"), every user sees Linux's own ids through allow_other, so the kernel
	 * checks them (default_permissions): lklfuse, LKL's root, checks nothing itself. */
	if (snprintf(opts, sizeof opts, "allow_other,nosuid,nodev%s,local,volname=%s,fsname=/dev/%s,noappledouble,fstypename=%s,fssubtype=%d%s",
		     req->owners ? ",default_permissions" : "", vol, bsd, nm->fstypename, nm->subtype, ro ? ",rdonly" : "") >= (int)sizeof opts)
		return refuse(fs, "the mount options do not fit");
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, cs) != 0)
		return refuse(fs, "cannot make mount_macfuse's socket");
	if (pipe(hout) != 0 || socketpair(AF_UNIX, SOCK_STREAM, 0, ch) != 0) {
		close(cs[0]);
		close(cs[1]);
		return refuse(fs, "cannot make mount_macfuse's pipe, or the CLI's channel");
	}
	for (fd = 0; fd < 2; fd++) {
		fcntl(cs[fd], F_SETFD, FD_CLOEXEC);
		fcntl(hout[fd], F_SETFD, FD_CLOEXEC);
		fcntl(ch[fd], F_SETFD, FD_CLOEXEC);
	}
	snprintf(commenv, sizeof commenv, "_FUSE_COMMFD=%d", cs[0]);
	henv[0] = "_FUSE_CALL_BY_LIB=1";
	henv[1] = "_FUSE_COMMVERS=2";
	henv[2] = daemon_env;
	henv[3] = commenv;
	henv[4] = NULL;
	hargv[0] = (char *)helper;
	hargv[1] = "-o";
	hargv[2] = opts;
	hargv[3] = (char *)req->mnt;
	hargv[4] = NULL;
#ifdef LINUXFS_FS_TEST_DROP
	printf("helper %s\n", helper);
	for (fd = 1; hargv[fd]; fd++)
		printf("helper-argv %s\n", hargv[fd]);
	for (fd = 0; henv[fd]; fd++)
		printf("helper-env %s\n", henv[fd]);
	printf("fd%d the CLI's channel to root\n", CHAN_FD);
	print_cli_plan(vars, args);
	if (getenv("LINUXFS_FS_TEST_ROOT_CLI"))
		args[0] = getenv("LINUXFS_FS_TEST_ROOT_CLI");
	if (!getenv("LINUXFS_FS_TEST_MOUNT_HELPER")) {
		close(cs[0]);
		close(cs[1]);
		close(hout[0]);
		close(hout[1]);
		close(ch[0]);
		close(ch[1]);
		return 0;
	}
#endif
	/* What root runs and what lklfuse loads: resolved, and every part of each path root's alone (path_trusted). The resolved
	 * helper path is what runs, so a swap after this check has nothing to land on. */
	for (fd = 0; fd < 2; fd++) {
		const char *what = fd ? libfuse_path() : helper;
		char resolved[PATH_MAX];
		int t = what ? path_trusted(what, resolved, sizeof resolved) : 0;

		if (t != 0) {
			close(cs[0]);
			close(cs[1]);
			close(hout[0]);
			close(hout[1]);
			close(ch[0]);
			close(ch[1]);
			return refuse(fs, t == -1 ? "macFUSE's install path is writable by a user" : "a macFUSE file is missing or not a regular file");
		}
		if (!fd)
			snprintf(rhelper, sizeof rhelper, "%s", resolved);
	}
	hargv[0] = rhelper;
	/* The CLI first, with its end of a channel on CHAN_FD: it does everything it can know before the mount (the lock, the
	 * probe, the access rule, the Fusion and ignore checks), says "ready", and waits for the device. A CLI that exits or
	 * fails before that never has a mount_macfuse run for it: nothing is left in mount(2) waiting for lklfuse's INIT. */
	cpid = fork();
	if (cpid == 0) {
		signal(SIGTERM, SIG_DFL);	/* root's flag-only handler is the mount program's: the CLI ends on SIGTERM */
		setpgid(0, 0);	/* the CLI, its lklfuse and all: one group, for root to stop if the mount fails */
		close(cs[0]);
		close(cs[1]);
		close(hout[0]);
		close(hout[1]);
		close(ch[0]);
		if (ch[1] != CHAN_FD) {
			dup2(ch[1], CHAN_FD);
			close(ch[1]);
		}
		fcntl(CHAN_FD, F_SETFD, 0);
		close(FUSE_FD);	/* fd 4 is lklfuse's, put there by linuxfs-open from the device root sends: nothing of root's may sit on it */
		close(5);
		close(lockfd);	/* root's: nothing of _linuxfs's may hold a disk root believes free */
		if (partfd >= 0)
			close(partfd);
		if (become_run_user(fs, name, uid, gid) != 0)
			_exit(1);
		syslog(LOG_NOTICE, "mount_%s: %s on %s: da-mount as %s, the device to come on channel fd %d%s", fs, bsd, req->mnt, RUN_USER,
		       CHAN_FD, ro ? " (read-only)" : "");
		fd = root_cli(req, args, vars, CHAN_FD, name);
		_exit(fd < 0 ? 1 : fd);
	}
	if (cpid > 0) {
		setpgid(cpid, cpid);
		/* the daemon reads this from the drained output: at its deadline's SIGKILL it also kills what is left of this group
		 * that runs as _linuxfs (N5). Before login it goes to DiskArbitration's log, harmlessly */
		fprintf(stderr, "cli-pgid %d\n", (int)cpid);
	}
	close(ch[1]);
	close(3);	/* the disk is the CLI's now */
	if (cpid < 0) {
		syslog(LOG_NOTICE, "mount_%s: %s: cannot run the CLI", fs, bsd);
		goto failed;
	}
	w = wait_ready(ch[0], cpid, &cli_rc, &cli_end, wait_s(READY_WAIT_S));
	if (w != 1) {
		syslog(LOG_NOTICE, "mount_%s: %s: the CLI did not get ready (%s); mount_macfuse is not run", fs, bsd,
		       w == 0 ? "it ended first" : w == -2 ? "timed out" : w == -3 ? "garbled: more than \"ready\"" :
		       w == -4 ? "stopped by SIGTERM" : "its channel closed");
		goto failed;
	}
	hpid = fork();
	hstarted = 1;
	if (hpid == 0) {
		int in = open("/dev/null", O_RDONLY);

		if (in < 0 || dup2(in, 0) < 0 || dup2(hout[1], 1) < 0 || dup2(hout[1], 2) < 0)
			_exit(127);
		for (fd = 3; fd < getdtablesize(); fd++)
			if (fd != cs[0] && fd != lockfd && fd != partfd)	/* the locks stay: they live while mount_macfuse does (not close-on-exec) */
				close(fd);
		fcntl(cs[0], F_SETFD, 0);
		execve(rhelper, hargv, henv);
		_exit(127);
	}
	close(cs[0]);
	close(hout[1]);
	if (hpid < 0) {
		syslog(LOG_NOTICE, "mount_%s: %s: cannot run mount_macfuse", fs, bsd);
		goto failed;
	}
	syslog(LOG_NOTICE, "mount_%s: %s on %s: mount_macfuse -o %s (pid %d)", fs, bsd, req->mnt, opts, (int)hpid);
	devfd = recv_device(cs[1], wait_s(DEVICE_WAIT_S), ch[0]);
	if (devfd < 0 || !send_device(ch[0], devfd)) {
		if (devfd >= 0)
			close(devfd);
		if (devfd == -4) {
			syslog(LOG_NOTICE, "mount_%s: %s: SIGTERM while waiting for the device; stopping mount_macfuse", fs, bsd);
		} else if (devfd == -2 || devfd == -3) {
			syslog(LOG_NOTICE, "mount_%s: %s: the CLI's channel %s while waiting for the device; stopping mount_macfuse", fs, bsd,
			       devfd == -2 ? "closed" : "sent unexpected data");
			fprintf(stderr, "linuxfs-mount: the CLI's channel %s while waiting for the device\n",
				devfd == -2 ? "closed" : "sent unexpected data");
		} else {
			syslog(LOG_NOTICE, "mount_%s: %s: no macFUSE device from mount_macfuse within %d s, or none to hand the CLI", fs, bsd,
			       wait_s(DEVICE_WAIT_S));
			fprintf(stderr, "linuxfs-mount: mount_macfuse sent no macFUSE device\n");
		}
		goto failed;
	}
	close(devfd);	/* the CLI's lklfuse and mount_macfuse hold it; root's copy would only keep it open */
	close(ch[0]);
	ch[0] = -1;

	deadline = time(NULL) + wait_s(STATUS_WAIT_S);
	for (;;) {
		struct pollfd p[2];
		time_t now = time(NULL);
		ssize_t r;

		if (stopping)
			break;
		if (got < 0 || (got > 0 && (status != 0 || cli_rc != -2)))
			break;	/* no status coming, a failed one, or the status and the CLI's end */
		if (!got && cli_rc != -2 && cli_rc != 0 && now >= cli_end + REFUSED_WAIT_S)
			break;
		if (now >= deadline)
			break;
		p[0].fd = got ? -1 : cs[1];
		p[1].fd = hout[0];
		p[0].events = p[1].events = POLLIN;
		p[0].revents = p[1].revents = 0;
		if (poll(p, 2, 200) < 0) {
			if (errno == EINTR)
				continue;	/* the flag, at the top */
			break;
		}
		if (p[1].revents) {
			char tmp[512];

			r = read(hout[0], tmp, sizeof tmp);
			if (r > 0 && hgot < sizeof hout_buf - 1) {
				size_t k = (size_t)r < sizeof hout_buf - 1 - hgot ? (size_t)r : sizeof hout_buf - 1 - hgot;

				memcpy(hout_buf + hgot, tmp, k);
				hgot += k;
			} else if (r == 0 || (r < 0 && errno != EINTR && errno != EAGAIN)) {
				close(hout[0]);
				hout[0] = -1;
			}
		}
		if (!got && p[0].revents) {
			/* without blocking, a piece at a time: the deadline bounds a status cut short too */
			r = recv(cs[1], (char *)&status + sgot, sizeof status - sgot, MSG_DONTWAIT);
			if (r > 0 && (sgot += (size_t)r) == sizeof status)
				got = 1;
			else if (r == 0 || (r < 0 && errno != EINTR && errno != EAGAIN))
				got = -1;
		}
		if (cli_rc == -2 && waitpid(cpid, &w, WNOHANG) == cpid) {
			cli_rc = WIFEXITED(w) ? WEXITSTATUS(w) : 1;
			cli_end = time(NULL);
		}
		if (hpid > 0 && waitpid(hpid, &w, WNOHANG) == hpid)
			hpid = -1;
	}
	/* SIGTERM from here on is held (blocked) to the end: once ok is decided the program exits 0 with its mount, never 1 beside it
	 * (task-16j-findings-r0.md I1); a SIGTERM before this line is the flag, and the failure path undoes everything. The daemon
	 * judges an exit 0 after its SIGTERM by the mount table, as any other */
	{
		sigset_t term;

		sigemptyset(&term);
		sigaddset(&term, SIGTERM);
		sigprocmask(SIG_BLOCK, &term, NULL);
	}
	ok = !stopping && got > 0 && status == 0 && (cli_rc == 0 || cli_rc == -2);
	if (ok) {
		syslog(LOG_NOTICE, "mount_%s: %s mounted on %s by root, served by %s%s", fs, bsd, req->mnt, RUN_USER,
		       cli_rc == -2 ? " (the CLI had not finished)" : "");
		close(cs[1]);
		cs[1] = -1;
		/* mount_macfuse has said all it has to: one still running STOP_WAIT_S later gets SIGTERM, then after 1 s SIGKILL,
		 * and is reaped; no root helper outlives the mount program (SIGTERM is held now, so none of this is cut short) */
		if (hpid > 0 && !reap(hpid, STOP_WAIT_S, &w)) {
			syslog(LOG_NOTICE, "mount_%s: %s: mount_macfuse (pid %d) is still running after the mount; stopped", fs, bsd, (int)hpid);
			stop(fs, hpid, 1);
		}
		hpid = -1;
	} else {
		if (got > 0)
			syslog(LOG_NOTICE, "mount_%s: %s: mount_macfuse reported %d", fs, bsd, (int)status);
		else
			syslog(LOG_NOTICE, "mount_%s: %s: no mount status from mount_macfuse (%s)", fs, bsd,
			       got < 0 ? "it closed its socket" : "timed out or the CLI failed first");
	}
failed:
	if (!ok || cpid < 0) {
		ok = 0;
		/* bounded in all (CLEANUP_S), so it ends within the daemon's grace after its SIGTERM: once SIGTERM has come, no wait for a
		 * process to end on SIGTERM is made (reap), and the waits after SIGKILL end by cleanup_end; every signal is still sent */
		cleanup_end = time(NULL) + CLEANUP_S;
		/* the CLI may be ending on its own (the status can arrive first): a moment for its exit status, the failure's reason */
		if (cpid > 0 && cli_rc == -2 && reap(cpid, 1, &w))
			cli_rc = WIFEXITED(w) ? WEXITSTATUS(w) : 1;
		if (cpid > 0)	/* the CLI and its lklfuse, if any: without the mount there is nothing for them to serve */
			stop_group(cpid, cli_rc == -2);
		fd = mounted_on(fs, req->mnt, bsd);
		if (fd < 0)
			syslog(LOG_NOTICE, "mount_%s: %s: %s holds another volume than root's mount; left mounted", fs, bsd, req->mnt);
		if (fd > 0) {
#ifdef LINUXFS_FS_TEST_DROP
			printf("unmount-attempt %s\n", req->mnt);
			fflush(stdout);
#endif
			if (unmount(req->mnt, MNT_FORCE) == 0)
				syslog(LOG_NOTICE, "mount_%s: %s: unmounted %s", fs, bsd, req->mnt);
			else
				syslog(LOG_NOTICE, "mount_%s: %s: cannot unmount %s: %s", fs, bsd, req->mnt, strerror(errno));
		}
		stop(fs, hpid, STOP_WAIT_S);
		if (cs[1] >= 0)
			close(cs[1]);
		if (!hstarted) {
			close(cs[0]);
			close(hout[1]);
		}
		if (ch[0] >= 0)
			close(ch[0]);
		fprintf(stderr, "linuxfs-mount: root's mount of %s failed\n", bsd);
	}
#ifdef LINUXFS_FS_TEST_DROP
	if (ok && getenv("LINUXFS_FS_TEST_OK_PAUSE")) {	/* past the last check, before log_lines (which may block): a test's SIGTERM lands here, held */
		printf("ok-pause\n");
		fflush(stdout);
		sleep((unsigned)atoi(getenv("LINUXFS_FS_TEST_OK_PAUSE")));
	}
#endif
	if (hout[0] >= 0) {
		ssize_t r;

		fcntl(hout[0], F_SETFL, fcntl(hout[0], F_GETFL) | O_NONBLOCK);
		while (hgot < sizeof hout_buf - 1 && (r = read(hout[0], hout_buf + hgot, sizeof hout_buf - 1 - hgot)) > 0)
			hgot += (size_t)r;
		close(hout[0]);
	}
	hout_buf[hgot] = '\0';
	log_lines("mount_macfuse", hout_buf);
	if (stopping)
		return stopped_by_sigterm(fs);
	if (ok)
		return 0;
	return cli_rc > 0 ? cli_rc : 1;
}

/* Everything the mount program does as root, before login: _linuxfs's lookup, the device on fd 3, then root's mount
 * (mount_by_root) or, with an older macFUSE, MNT handed to _linuxfs, the drop and the bundled CLI. Returns only to refuse (1),
 * or with root's mount's outcome. Test builds print the plan and return 0 instead of the privileged calls. */
static int mount_as_root(const char *fs, const struct mountreq *req)
{
	struct passwd *pw;
	struct stat st;
	char node[64], devarg[64], name[64];
	char *args[8], whole[40];
	const char *bsd;
	int fd, mfd, n = 0, ro_fallback = 0, ro, by_root, lockfd, partfd, m;
	uid_t uid;
	gid_t gid;
	struct sigaction sa;
	sigset_t term;

	/* SIGTERM (the daemon's deadline) only sets the flag, without SA_RESTART: every blocking call below then returns early, and
	 * root undoes what it started (mount_by_root's failure path) and exits 1. Unblocked, whatever mask we were given. */
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_sigterm;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = 0;
	sigaction(SIGTERM, &sa, NULL);
	sigemptyset(&term);
	sigaddset(&term, SIGTERM);
	sigprocmask(SIG_UNBLOCK, &term, NULL);
	linuxfs_probe_stop = &stopping;	/* the probe's read of /dev/rBSD gives up on EINTR once it is set */

	fill_std_fds();
	bsd = strncmp(req->dev, "/dev/", 5) == 0 ? req->dev + 5 : req->dev;
	if (!fsrules_valid_bsd(bsd) || !fsrules_whole_disk(bsd, whole, sizeof whole))
		return refuse(fs, "the device is not diskN or diskNsM");
	if (!valid_mnt_path(req->mnt))
		return refuse(fs, "the mount point is not directly under /Volumes");
	pw = getpwnam(run_user());
	if (!pw || pw->pw_uid == 0 || pw->pw_gid == 0)
		return refuse(fs, "no usable _linuxfs user");
	uid = pw->pw_uid;
	gid = pw->pw_gid;
	snprintf(name, sizeof name, "%s", pw->pw_name);
	snprintf(node, sizeof node, "/dev/r%s", bsd);
	snprintf(devarg, sizeof devarg, "/dev/%s", bsd);

	/* One mount of a partition at a time, never beside a mount of its whole disk, and siblings side by side (lock_disks' two levels,
	 * held to the end by this program and by root's mount_macfuse), and only where nothing is mounted already that refuses it, on
	 * MNT, from it or its whole disk, or for a whole disk from any of its partitions: so a failure here can only ever unmount this
	 * request's own mount (mounted_already states the window left to what takes no lock). */
	lockfd = lock_disks(fs, bsd, whole, &partfd);
	if (lockfd < 0)
		return 1;
	m = mounted_already(req->mnt, bsd);
	if (m != 0) {
		char why[112];

		close(lockfd);
		if (partfd >= 0)
			close(partfd);
		if (m < 0)
			return refuse(fs, "the mount table cannot be read");
		snprintf(why, sizeof why, "something is mounted on the mount point or from %s or its disk already", bsd);
		return refuse(fs, why);
	}

	/* read-only when asked; else read-write, falling back to read-only (and --ro) */
	fd = req->ro ? -1 : open(node, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
	if (fd < 0) {
		fd = open(node, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
		ro_fallback = 1;
	}
	if (fd < 0)
		return refuse(fs, "the device cannot be opened");
	if (fstat(fd, &st) != 0 || !S_ISCHR(st.st_mode)) {
		close(fd);
		return refuse(fs, "the device node is not a character device");
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
	if (fd != 3) {
		if (dup2(fd, 3) < 0) {
			close(fd);
			return refuse(fs, "cannot place the device on fd 3");
		}
		close(fd);
	}
	fcntl(3, F_SETFD, 0);

	/* how it mounts, by the rule the CLI follows too (fsrules_access, the probe's type and flags): decided here, before
	 * macFUSE mounts it, so the kernel's mount is read-only whenever what lklfuse serves will be. An encrypted volume is
	 * refused: before login there is no keychain, and no one to ask for its password. */
	{
		char label[256];
		struct fsprefs p;
		const char *type, *why = "";
		int err = 0;

		type = linuxfs_probe_fd(3, label, sizeof label, &err);
		if (stopping)
			return stopped_by_sigterm(fs);
		if (!type)
			return refuse(fs, "no filesystem linuxfs knows on the device");
		prefs_read(&p);
		switch (fsrules_access(type, fsrules_probe_flags(linuxfs_probe_extra(), linuxfs_probe_flags()), req->ro || ro_fallback,
				       1, &p, &why)) {
		case FSA_REFUSE:
			return refuse(fs, "an encrypted volume before login: no keychain, and no one to ask for its password");
		case FSA_RO:
			ro = 1;
			break;
		default:
			ro = 0;
			break;
		}
#ifndef LINUXFS_FS_TEST_DROP
		syslog(LOG_NOTICE, "mount_%s: %s: %s is %s%s%s", fs, bsd, type, ro ? "read-only (" : "read-write", why, ro ? ")" : "");
#endif
	}

	/* the mount point: the directory we open is the one we chown, so a swapped path cannot redirect it */
	mfd = open(req->mnt, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
	if (mfd < 0)
		return refuse(fs, "the mount point cannot be opened (missing, or a symlink)");
	if (fstat(mfd, &st) != 0 || !S_ISDIR(st.st_mode)) {
		close(mfd);
		return refuse(fs, "the mount point is not a directory");
	}
	{
		struct stat vst;
		int vfd = open(volumes_dir(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);

		if (vfd < 0 || fstat(vfd, &vst) != 0 || vst.st_dev != st.st_dev) {
			if (vfd >= 0)
				close(vfd);
			close(mfd);
			return refuse(fs, "the mount point is on another volume than /Volumes");
		}
		close(vfd);
	}
	if (st.st_uid != ROOT_ONLY_UID) {
		close(mfd);
		return refuse(fs, "the mount point is not owned by root");
	}
	by_root = macfuse_serves_fd(fs);
	if (by_root < 0) {
		close(mfd);
		return refuse(fs, "macFUSE's install path is writable by a user");
	}
	if (!by_root) {
		close(mfd);
		return refuse(fs, "macFUSE is too old to mount before login; update macFUSE");
	}
#ifdef LINUXFS_FS_TEST_DROP
	printf("user %s\nuid %d\ngid %d\nfd3 %s %s\nmnt %s\n", name, (int)uid, (int)gid, node, ro_fallback ? "ro" : "rw", req->mnt);
#endif
	close(mfd);

	args[n++] = PRIV_DIR "/linuxfs";
	args[n++] = "da-mount";
	if (ro)
		args[n++] = "--ro";
	if (req->owners)
		args[n++] = "--owners";
	args[n++] = devarg;
	args[n++] = (char *)req->mnt;
	args[n] = NULL;

	if (stopping)	/* nothing started yet: nothing to undo */
		return stopped_by_sigterm(fs);
	return mount_by_root(fs, req, bsd, ro, name, uid, gid, args, lockfd, partfd);
}

/* What DiskArbitration passed: the arguments after the program name, joined by spaces and cut at 200 bytes. They hold the device,
 * the mount point and the -o options, and never a password. */
static void log_request(const char *fs, int argc, char **argv)
{
	char line[208];
	size_t n = 0;
	int i;

	line[0] = '\0';
	for (i = 1; i < argc && n < 200; i++) {
		int w = snprintf(line + n, 201 - n, "%s%s", i > 1 ? " " : "", argv[i]);

		if (w < 0)
			break;
		n += (size_t)w;
	}
	if (n > 200)
		n = 200;
	line[n] = '\0';
	syslog(LOG_NOTICE, "mount_%s: arguments: %s", fs, line);
}

/* The topmost mount on MNT, the one unmount(MNT) would hit: 1 with its type, source and owner, or 0 when nothing is on MNT. The mount
 * table with MNT_NOWAIT, last entry first, as mounted_on reads it; for tests (as the console user only, as LINUXFS_CLI) LINUXFS_MNTTAB
 * names a file of TYPE<TAB>FROM<TAB>ON<TAB>OWNER lines, the last on top (unreadable: nothing on MNT). */
static int top_mount(const char *mnt, char type[MFSTYPENAMELEN], char from[MAXPATHLEN], unsigned *owner)
{
	const char *tab = test_env("LINUXFS_MNTTAB");
	char line[3 * MAXPATHLEN];
	struct statfs *m;
	int n, i, found = 0;
	FILE *f;

	if (tab && *tab) {
		if (!(f = fopen(tab, "r")))
			return 0;
		while (fgets(line, sizeof line, f)) {
			char *a = line, *b, *c, *d;

			line[strcspn(line, "\n")] = '\0';
			if (!(b = strchr(a, '\t')) || !(c = strchr(b + 1, '\t')) || !(d = strchr(c + 1, '\t')))
				continue;
			*b++ = *c++ = *d++ = '\0';
			if (strcmp(c, mnt) != 0)
				continue;
			found = snprintf(type, MFSTYPENAMELEN, "%s", a) < MFSTYPENAMELEN && snprintf(from, MAXPATHLEN, "%s", b) < MAXPATHLEN;
			*owner = (unsigned)strtoul(d, NULL, 10);
		}
		fclose(f);
		return found;
	}
	n = getmntinfo(&m, MNT_NOWAIT);
	for (i = n - 1; i >= 0; i--)
		if (strcmp(m[i].f_mntonname, mnt) == 0) {
			snprintf(type, MFSTYPENAMELEN, "%s", m[i].f_fstypename);
			snprintf(from, MAXPATHLEN, "%s", m[i].f_mntfromname);
			*owner = (unsigned)m[i].f_owner;
			return 1;
		}
	return 0;
}

/* Whether the topmost mount on MNT is one of FS's (its macfuse_<fs> type) from /dev/BSD, whoever owns it: the user path's exit gate,
 * so that DiskArbitration never records a mount that is not there (push D: an lklfuse ended by macFUSE's refusal of an asynchronous
 * mount could still say 0). */
static int user_mounted(const char *fs, const char *mnt, const char *bsd)
{
	char type[MFSTYPENAMELEN], from[MAXPATHLEN];
	unsigned owner;
	const char *t;

	if (!top_mount(mnt, type, from, &owner))
		return 0;
	t = fsrules_fs_of_type(type);
	return t && strcmp(t, fs) == 0 && strncmp(from, "/dev/", 5) == 0 && strcmp(from + 5, bsd) == 0;
}

/* Whether the topmost mount on MNT is root's own mount of FS from /dev/BSD (mounted_on's rule, fsrules_mount_is_roots): the daemon's
 * "ok" is exit 0 only then, so DiskArbitration never records a mount that is not there */
static int roots_mounted(const char *fs, const char *mnt, const char *bsd)
{
	char type[MFSTYPENAMELEN], from[MAXPATHLEN];
	unsigned owner;

	return top_mount(mnt, type, from, &owner) && fsrules_mount_is_roots(fs, bsd, type, from, owner);
}

/* ---- asking root's mount daemon (tools/mountd.c; root-daemon design §1) --------------------------------------------------------- */

#define MOUNTD_SOCK "/var/run/dev.mavergreen.linuxfs.mountd.sock"
#define MOUNTD_HI_S 5	/* for hi (or user), which the daemon writes before it takes a slot */
enum { MA_OK, MA_NO, MA_USER, MA_UNREACHABLE, MA_LOST };

/* both to syslog and to stderr (DiskArbitration's log): which way the mount went, and why */
static void ask_say(const char *fs, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void ask_say(const char *fs, const char *fmt, ...)
{
	char msg[300];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);
	syslog(LOG_NOTICE, "mount_%s: %s", fs, msg);
	fprintf(stderr, "linuxfs-mount: %s\n", msg);
}

/* the daemon's no<TAB>RC<TAB>WHY, said with the status it gives (RC through 1..255) */
static void ask_why(const char *fs, const char *line, int rc)
{
	const char *why = strchr(line + 3, '\t');

	ask_say(fs, "the mount daemon said no (%d: %s)", rc, why ? why + 1 : "no reason");
}

/* A test's bound in whole seconds (test_env NAME, 1 to MOUNTD_CLIENT_WAIT), or DFLT */
static int ask_secs(const char *name, int dflt)
{
	const char *v = test_env(name);
	char *e;
	long n;

	if (!v || !*v)
		return dflt;
	n = strtol(v, &e, 10);
	return *e || n < 1 || n > MOUNTD_CLIENT_WAIT ? dflt : (int)n;
}

static long long ask_now_ms(void)
{
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* the daemon's replies, read a line at a time from what has come so far */
struct askbuf { char b[1100]; size_t have; };

/* One line (without its LF) into line (LEN bytes) by END (ms): 1; 0 on EOF or an error; -1 on timeout; -2 for a line too long or
 * holding a NUL */
static int ask_line(int fd, struct askbuf *a, char *line, size_t len, long long end)
{
	for (;;) {
		char *nl = memchr(a->b, '\n', a->have);
		struct pollfd p = { fd, POLLIN, 0 };
		long long left;
		ssize_t r;

		if (nl) {
			size_t n = (size_t)(nl - a->b);

			if (n >= len || memchr(a->b, '\0', n))
				return -2;
			memcpy(line, a->b, n);
			line[n] = '\0';
			memmove(a->b, nl + 1, a->have - n - 1);
			a->have -= n + 1;
			return 1;
		}
		if (a->have >= sizeof a->b)
			return -2;
		left = end - ask_now_ms();
		if (left <= 0)
			return -1;
		r = poll(&p, 1, left > INT_MAX ? INT_MAX : (int)left);
		if (r < 0 && errno != EINTR)
			return 0;
		if (r <= 0)
			continue;
		r = read(fd, a->b + a->have, sizeof a->b - a->have);
		if (r > 0)
			a->have += (size_t)r;
		else if (r == 0 || (errno != EINTR && errno != EAGAIN))
			return 0;
	}
}

/* A reply line's kind: 'h' hi, 'b' begin, 'k' ok, 'u' user (with or without a reason), 'n' no (*rc its status through 1..255:
 * anything else, 0 included, is 1, M2), or 0: anything else */
static int ask_kind(const char *l, int *rc)
{
	char *e;
	long v;

	if (strcmp(l, "hi") == 0)
		return 'h';
	if (strcmp(l, "begin") == 0)
		return 'b';
	if (strcmp(l, "ok") == 0)
		return 'k';
	if (strcmp(l, "user") == 0 || strncmp(l, "user\t", 5) == 0)
		return 'u';
	if (strncmp(l, "no\t", 3) == 0) {
		errno = 0;
		v = strtol(l + 3, &e, 10);
		*rc = e != l + 3 && (*e == '\0' || *e == '\t') && errno == 0 && v >= 1 && v <= 255 ? (int)v : 1;
		return 'n';
	}
	return 0;
}

/* Asks root's mount daemon to mount FS's DEV on MNT, as req asks: MA_OK ("ok"), MA_NO ("no RC": *rc), MA_USER ("user": the user's own
 * mount), MA_UNREACHABLE (no daemon, or one that went before "begin": nothing was touched, so the user's own path is safe), MA_LOST
 * (after "begin", no answer: root may have changed something, so no fallback).
 * - The socket is MOUNTD_SOCK (LINUXFS_MOUNTD_SOCK for tests). A refused connect (ECONNREFUSED: nothing listens, or a full backlog)
 *   or none there is no daemon.
 * - Its peer must be root (getpeereid; LINUXFS_MOUNTD_PEER_UID names a test's stand-in instead), checked before anything is sent or
 *   read: /var/run is root:daemon 0775, so a process in group daemon could put its own listener at the path. Any other peer is no
 *   daemon, and gets nothing of the request.
 * - Before "begin": "hi" within MOUNTD_HI_S, then the request line; "user" or "no" is the answer; EOF, a garbled line, or nothing from
 *   hi to begin for MOUNTD_CLIENT_PREBEGIN (LINUXFS_MOUNTD_PREBEGIN_WAIT) is no daemon (R2, I5).
 * - After "begin": "ok" or "no"; anything else, EOF, or nothing by MOUNTD_CLIENT_WAIT in all (LINUXFS_MOUNTD_WAIT) is lost (N6). */
static int ask_mountd(const char *fs, const struct mountreq *req, const char *bsd, int *rc)
{
	const char *path = test_env("LINUXFS_MOUNTD_SOCK"), *pu = test_env("LINUXFS_MOUNTD_PEER_UID"), *p;
	char reqline[1100], line[1100];
	struct sockaddr_un sa;
	struct stat pst;
	struct askbuf a;
	long long t0, end, phase_end;
	int fd, one = 1, n, k, phase = 0, out = MA_UNREACHABLE;
	size_t sent = 0;
	uid_t want = 0, peer;
	gid_t pgid;

	*rc = 1;
	if (!path || !*path)
		path = MOUNTD_SOCK;
	if (pu && *pu) {
		char *e;
		unsigned long v = strtoul(pu, &e, 10);

		if (!*e)
			want = (uid_t)v;
	}
	/* the request line: nothing the daemon would read as another field or line */
	n = snprintf(reqline, sizeof reqline, "mount\t%s\t%s\t%s\t%s\n", fs, bsd,
		     req->ro && req->owners ? "ro,owners" : req->ro ? "ro" : req->owners ? "owners" : "-", req->mnt);
	if (n < 0 || n > 1024) {
		ask_say(fs, "the request is too long for the mount daemon: not asked");
		return MA_UNREACHABLE;
	}
	for (p = reqline; p < reqline + n - 1; p++)
		if ((unsigned char)*p == 0x7f || ((unsigned char)*p < 0x20 && *p != '\t')) {
			ask_say(fs, "the request has a control character: the mount daemon is not asked");
			return MA_UNREACHABLE;
		}
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof sa.sun_path)
		return MA_UNREACHABLE;
	strcpy(sa.sun_path, path);
	/* connect follows a symlink, which a process in group daemon could put at the path, to another root service's socket: the path
	 * itself must be a socket, not a symlink. Best effort (the path can change before connect); whose it is, the peer check below
	 * decides */
	if (lstat(path, &pst) != 0) {
		ask_say(fs, errno == ENOENT ? "no mount daemon (no socket): your own mount" : "the mount daemon's socket cannot be read: your own mount");
		return MA_UNREACHABLE;
	}
	if (!S_ISSOCK(pst.st_mode)) {
		ask_say(fs, "the mount daemon's socket path is not a socket (a symlink?): not asked");
		return MA_UNREACHABLE;
	}
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return MA_UNREACHABLE;
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
		int e = errno;

		close(fd);
		if (e == ENOENT)
			ask_say(fs, "no mount daemon (no socket): your own mount");
		else
			ask_say(fs, "the mount daemon cannot be reached (%s): your own mount", strerror(e));
		return MA_UNREACHABLE;
	}
	/* root's, or no daemon at all: checked before a byte is sent or read */
	if (getpeereid(fd, &peer, &pgid) != 0) {
		close(fd);
		ask_say(fs, "the mount daemon's peer cannot be read: not asked; your own mount");
		return MA_UNREACHABLE;
	}
	if (peer != want) {
		close(fd);
		ask_say(fs, "the mount daemon's socket is held by uid %u, not root: not asked", (unsigned)peer);
		return MA_UNREACHABLE;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	a.have = 0;
	t0 = ask_now_ms();
	end = t0 + 1000LL * ask_secs("LINUXFS_MOUNTD_WAIT", MOUNTD_CLIENT_WAIT);
	phase_end = t0 + 1000LL * MOUNTD_HI_S;
	for (;;) {
		int got = ask_line(fd, &a, line, sizeof line, phase_end < end ? phase_end : end);

		k = got == 1 ? ask_kind(line, rc) : 0;
		if (phase == 2) {	/* after begin: root may have changed something; never the user's own path */
			if (k == 'k')
				out = MA_OK;
			else if (k == 'n') {
				out = MA_NO;
				ask_why(fs, line, *rc);
			} else {
				out = MA_LOST;
				ask_say(fs, "the mount daemon said begin, then %s: failed", got == -1 ? "nothing in time" :
					got == 1 || got == -2 ? "something garbled" : "closed the connection");
			}
			break;
		}
		if (k == 'u') {
			out = MA_USER;
			ask_say(fs, "the mount daemon answered user (%s): your own mount", line[4] ? line + 5 : "no reason");
			break;
		}
		if (k == 'n') {
			out = MA_NO;
			ask_why(fs, line, *rc);
			break;
		}
		if (phase == 0 && k == 'h') {
			phase = 1;
			phase_end = ask_now_ms() + 1000LL * ask_secs("LINUXFS_MOUNTD_PREBEGIN_WAIT", MOUNTD_CLIENT_PREBEGIN);
			while (sent < (size_t)n) {	/* the request, by the same bounds */
				struct pollfd pw = { fd, POLLOUT, 0 };
				long long left = (phase_end < end ? phase_end : end) - ask_now_ms();
				ssize_t w;

				if (left <= 0 || (poll(&pw, 1, (int)left) < 0 && errno != EINTR))
					break;
				w = write(fd, reqline + sent, (size_t)n - sent);
				if (w > 0)
					sent += (size_t)w;
				else if (w < 0 && errno != EAGAIN && errno != EINTR)
					break;
			}
			if (sent < (size_t)n) {
				ask_say(fs, "the request did not reach the mount daemon: your own mount");
				break;
			}
			continue;
		}
		if (k == 'k') {	/* ok before begin claims a mount: never the user's own path over it (findings m1) */
			out = MA_LOST;
			ask_say(fs, "the mount daemon said ok before begin: failed");
			break;
		}
		if (phase == 1 && k == 'b') {
			phase = 2;
			phase_end = end;
			continue;
		}
		/* before begin: nothing was touched, so the user's own path is safe */
		if (got == -1)
			ask_say(fs, phase ? "the mount daemon said nothing before begin: your own mount" :
				"the mount daemon did not say hi in time: your own mount");
		else
			ask_say(fs, "the mount daemon %s before begin: your own mount", got == 1 || got == -2 ? "said something garbled" :
				"closed the connection");
		break;
	}
	close(fd);
	return out;
}

static int mount_role(const char *fs, int argc, char **argv)
{
	struct mountreq req;
	struct passwd *pw;
	const char *cli, *bsd, *base, *hintp;
	char *out, hint[256], header[400], message[400], pass[PW_MAX], saved_pw[PW_MAX];
	int rc, wrong = 0, tries, saved = 0, remember;

	/* whoever started us may have left SIGCHLD ignored, and then no child's exit status would ever be seen */
	signal(SIGCHLD, SIG_DFL);
	openlog("linuxfs-mount", LOG_PID, LOG_DAEMON);
	log_request(fs, argc, argv);
	if (fsrules_parse_mount(argc - 1, argv + 1, &req) != 0) {
		fprintf(stderr, "usage: mount_macfuse_%s [-o options] device mountpoint\n", fs);
		syslog(LOG_NOTICE, "mount_%s: bad arguments", fs);
		return 1;
	}
	syslog(LOG_NOTICE, "mount_%s: parsed ro=%d owners=%d", fs, req.ro, req.owners);
	/* mount -u: vsdbutil's, to change ownership in place (diskutil enableOwnership). macFUSE's kernel refuses MNT_UPDATE
	 * (ENOTSUP), and this is no second mount on the same mount point */
	if (req.update) {
		fprintf(stderr, "mount_macfuse_%s: update (mount -u) is not supported: macFUSE cannot change a mount; unmount and mount again\n", fs);
		syslog(LOG_NOTICE, "mount_%s: refused: update (mount -u)", fs);
		return 1;
	}
#ifdef LINUXFS_FS_TEST_DROP
	if (1)
#else
	if (getuid() == 0)
#endif
		return mount_as_root(fs, &req);
	bsd = strncmp(req.dev, "/dev/", 5) == 0 ? req.dev + 5 : req.dev;
	/* root's daemon first (root-daemon design §1): a mount made by root, as before login, has fsevents and Spotlight. Only "user", or
	 * no daemon (nothing reached it, or nothing was touched before begin), takes the user's own path below */
	switch (ask_mountd(fs, &req, bsd, &rc)) {
	case MA_OK:
		if (roots_mounted(fs, req.mnt, bsd)) {
			syslog(LOG_NOTICE, "mount_%s: %s: mounted on %s by root's mount daemon: exit 0", fs, req.dev, req.mnt);
			return 0;
		}
		fprintf(stderr, "mount_macfuse_%s: the mount daemon said ok but root's mount is not on %s\n", fs, req.mnt);
		syslog(LOG_NOTICE, "mount_%s: %s: the mount daemon said ok but root's mount is not on %s: exit 1", fs, req.dev, req.mnt);
		return 1;
	case MA_NO:
		syslog(LOG_NOTICE, "mount_%s: %s: the mount daemon said no: exit %d", fs, req.dev, rc);
		return rc;
	case MA_LOST:
		syslog(LOG_NOTICE, "mount_%s: %s: the mount daemon's answer was lost after begin: exit 1", fs, req.dev);
		return 1;
	default:	/* MA_USER, MA_UNREACHABLE: said, with why, by ask_mountd */
		break;
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
	base = strrchr(req.mnt, '/');
	base = base && base[1] ? base + 1 : req.mnt;
	out = malloc(CAPTURE_MAX);
	if (!out)
		return 1;
	syslog(LOG_NOTICE, "mount_%s: %s on %s%s", fs, req.dev, req.mnt, req.ro ? " (read-only)" : "");

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
			syslog(LOG_NOTICE, "mount_%s: %s: %s: asking again", fs, req.dev,
			       rc == 2 ? "a password too long or unreadable" : "an empty password");
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
	/* one gate for every run of the CLI that said 0: the first try, the keeper's password's or the dialog's */
	if (rc == 0 && !user_mounted(fs, req.mnt, bsd)) {
		fprintf(stderr, "mount_macfuse_%s: the CLI exited 0 but nothing is mounted on %s\n", fs, req.mnt);
		syslog(LOG_NOTICE, "mount_%s: %s: the CLI exited 0 but nothing is mounted on %s", fs, req.dev, req.mnt);
		rc = 1;
	}
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
