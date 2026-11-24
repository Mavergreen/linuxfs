/*
 * linuxfs-fs: the one program inside each filesystem bundle (/System/Library/Filesystems/linuxfs_<fs>.fs), copied
 * under three names -- linuxfs_<fs>.util (probe), mount_linuxfs_<fs>, fsck_linuxfs_<fs> -- that picks its role and
 * its filesystem from argv[0]. DiskArbitration runs it as root with a bare environment, so everything here is C
 * and nothing is ever executed. Decisions come from fsrules.c; superblocks from probe.c.
 *
 * util -p BSD removable|fixed readonly|writable   recognised: the volume name on stdout, exit 255; else exit 254
 * util -k BSD                                     the filesystem's UUID on stdout (no newline), exit 253; else exit 254
 * fsck -q DEV                                     exit 0 (a quick check has nothing to do); -n or -y exit 8
 * mount [-o OPT]... DEV MNT                       as the console user: runs the CLI's da-mount and, for an encrypted volume,
 *                                                  asks for the password (the keychain keeper first, then Apple's dialog);
 *                                                  as root (nobody logged in): opens /dev/rDEV as fd 3; then, with a macFUSE that
 *                                                  serves a /dev/fd/N mountpoint, runs mount_macfuse itself (allow_other) and hands
 *                                                  the device it sends to the bundled CLI's da-mount as fd 4 (LINUXFS_FUSE_FD=4),
 *                                                  run as _linuxfs, until mount_macfuse reports the mount; with an older macFUSE,
 *                                                  hands MNT to _linuxfs and runs that da-mount, which mounts by itself; both with
 *                                                  LINUXFS_OPEN_INHERITED=1
 *
 * -DLINUXFS_FS_TEST_DROP (tests only, never in the shipped binary) takes the root path as whatever user runs it, up to the
 * drop: the privileged calls (fchown, initgroups, setgid, setuid) are replaced by printing the plan; the macFUSE manifest, the
 * mount helper, the CLI and the waits are the test's (LINUXFS_FS_TEST_*).
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
#include "plist.h"
#include "probe.h"

#define FSUR_RECOGNIZED 255
#define FSUR_IO_SUCCESS 253	/* sys/loadable_fs.h's (-3), as an exit status */
#define FSUR_UNRECOGNIZED 254

/* Fills p from the console user's plist, then the machine's, then the defaults, key by key. A plist that cannot be read
 * or parsed counts as absent (plist.c). Automount and Ignore:<LABEL> are not read: a volume's own "do not mount by
 * itself" is /etc/fstab's noauto, which DiskArbitration applies before it ever runs the util. */
static void fs_read_prefs(struct fsprefs *p)
{
	static const struct { const char *name; size_t off; } keys[] = {
		{ "ReadOnly", offsetof(struct fsprefs, readonly) },
		{ "NTFSTakeover", offsetof(struct fsprefs, ntfs_takeover) },
		{ "APFSWrite", offsetof(struct fsprefs, apfs_write) },
	};
	CFDictionaryRef d[2];
	size_t i, j;

	fsrules_default_prefs(p);
	prefs_load(&d[0], &d[1]);
	for (i = 0; i < sizeof keys / sizeof keys[0]; i++) {
		CFStringRef k = CFStringCreateWithCString(NULL, keys[i].name, kCFStringEncodingUTF8);

		for (j = 0; k && j < 2; j++) {
			int v = pref_bool(d[j], k);

			if (v >= 0) {
				*(int *)((char *)p + keys[i].off) = v;
				break;
			}
		}
		if (k)
			CFRelease(k);
	}
	for (j = 0; j < 2; j++)
		if (d[j])
			CFRelease(d[j]);
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
	int removable;

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
		fs_read_prefs(&p);
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

		if (!valid_bsd(argv[2])) {
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
	rc = run_capture(argv, NULL, pw, -1, out, outlen);
	syslog(LOG_NOTICE, "%s: %s exited %d%s", req->dev, "linuxfs da-mount", rc, pw ? " (with a password)" : "");
	log_lines("linuxfs", out);
	return rc;
}


#define PRIV_DIR "/Library/PrivilegedHelperTools/dev.mavergreen.linuxfs.d"
#define RUN_USER "_linuxfs"
#define MOUNT_MACFUSE "/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse"
#define MACFUSE_MANIFEST "/usr/local/mavergreen/macfuse/mavergreen.plist"
/* The first Mavergreen macFUSE release that ships the fd-mountpoint patch (its libfuse 3 serves a /dev/fd/N mountpoint
 * another process mounted: macfuse's DETAILS.md, "A mount made for you"), as build/package.sh's MACFUSE_MIN. Dev builds
 * labelled 5.5.0-mavericks.2 that predate the patch exist: on those the gate passes, lklfuse cannot serve /dev/fd/N, and
 * root's mount fails, bounded, after STATUS_WAIT_S. */
#define MACFUSE_FD_MOUNTPOINT_SINCE "5.5.0-mavericks.2"
#define FUSE_FD 4		/* the macFUSE device, in the CLI and lklfuse: beside the disk on 3, and not 5 (the password's) */
#define DEVICE_WAIT_S 30	/* for mount_macfuse to send the device */
#define STATUS_WAIT_S 60	/* for its mount status: mount(2) ends when lklfuse answers the kernel's INIT */
#define REFUSED_WAIT_S 5	/* for that status after the CLI failed (its descriptors closed, the mount fails) */
#define STOP_WAIT_S 2		/* for a process told to stop, before SIGKILL */
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

/* a fatal early failure: syslog, then exit 1 */
static void die(const char *what)
{
	syslog(LOG_NOTICE, "mount_root: %s", what);
	_exit(1);
}

#ifdef LINUXFS_FS_TEST_DROP
#define ROOT_ONLY_UID geteuid()	/* the tests' stand-in for root: whoever runs the test build owns the mount point */
static const char *volumes_dir(void) { const char *v = getenv("LINUXFS_FS_TEST_VOLUMES"); return v && *v ? v : "/Volumes"; }
static const char *run_user(void) { const char *u = getenv("LINUXFS_FS_TEST_USER"); return u && *u ? u : RUN_USER; }
/* no manifest unless the test names one, so a macFUSE installed here never changes the plan */
static const char *macfuse_manifest(void) { const char *v = getenv("LINUXFS_FS_TEST_MACFUSE"); return v && *v ? v : "/nonexistent"; }
static const char *mount_helper(void) { const char *v = getenv("LINUXFS_FS_TEST_MOUNT_HELPER"); return v && *v ? v : MOUNT_MACFUSE; }
static int wait_s(int s) { const char *v = getenv("LINUXFS_FS_TEST_WAIT"); return v && atoi(v) > 0 ? atoi(v) : s; }
/* LINUXFS_FS_TEST_NOKILL: SIGKILL becomes a no-op, for a stand-in that outlives it as a process in an uninterruptible wait would */
static int kill_sig(void) { return getenv("LINUXFS_FS_TEST_NOKILL") ? 0 : SIGKILL; }
#else
#define ROOT_ONLY_UID 0
static const char *volumes_dir(void) { return "/Volumes"; }
static const char *run_user(void) { return RUN_USER; }
static const char *macfuse_manifest(void) { return MACFUSE_MANIFEST; }
static const char *mount_helper(void) { return MOUNT_MACFUSE; }
static int wait_s(int s) { return s; }
static int kill_sig(void) { return SIGKILL; }
#endif

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

/* Whether the installed macFUSE's libfuse serves a /dev/fd/N mountpoint: its manifest (root's alone) names a version at or
 * past MACFUSE_FD_MOUNTPOINT_SINCE. Logged either way. Only the file is checked (root's, not a symlink, writable by root
 * alone), not its parent directories: whoever could swap it there could only choose between the two mount paths, each
 * safe (root never runs lklfuse on either), and could at worst make root's mount fail, bounded. */
static int macfuse_serves_fd(const char *fs)
{
	CFDictionaryRef d = plist_load_owned(macfuse_manifest(), ROOT_ONLY_UID);
	CFTypeRef v = d ? CFDictionaryGetValue(d, CFSTR("version")) : NULL;
	char ver[64] = "";
	unsigned have[4], need[4];
	int i, ok = 0;

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
		syslog(LOG_NOTICE, "mount_%s: macFUSE %s is before %s, which serves /dev/fd/N: _linuxfs mounts", fs,
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

/* The descriptor mount_macfuse sends over sock (SCM_RIGHTS, one byte) within secs; -1 when none. A message with anything but
 * one descriptor is refused, and every descriptor it carried is closed. */
static int recv_device(int sock, int secs)
{
	struct pollfd p = { sock, POLLIN, 0 };
	struct msghdr msg;
	struct iovec iov;
	struct cmsghdr *c;
	char b, cc[CMSG_SPACE(8 * sizeof(int))];
	struct timeval t0, now;
	int fd = -1, r, fds = 0, bad = 0;

	gettimeofday(&t0, NULL);
	for (;;) {
		long left;

		gettimeofday(&now, NULL);
		left = secs * 1000L - ((long)(now.tv_sec - t0.tv_sec) * 1000 + (long)(now.tv_usec - t0.tv_usec) / 1000);
		if (left <= 0)
			return -1;
		r = poll(&p, 1, (int)left);
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

/* What is mounted on MNT (MNT_NOWAIT, so no file system is asked): 0 nothing; 1 root's own mount, from linuxfs@BSD, a macfuse
 * (or osxfuse) file system; -1 something else, which is never root's to unmount */
static int mounted_on(const char *mnt, const char *bsd)
{
	struct statfs *m;
	char from[64];
	int n, i, r = 0;

	snprintf(from, sizeof from, "linuxfs@%s", bsd);
	n = getmntinfo(&m, MNT_NOWAIT);
	for (i = 0; i < n; i++)
		if (strcmp(m[i].f_mntonname, mnt) == 0) {
			if (strcmp(m[i].f_mntfromname, from) == 0 &&
			    (strncmp(m[i].f_fstypename, "macfuse", 7) == 0 || strncmp(m[i].f_fstypename, "osxfuse", 7) == 0))
				r = 1;
			else if (r == 0)
				r = -1;
		}
	return r;
}

/* Waits up to secs for pid; 1 with *st when it was reaped */
static int reap(pid_t pid, int secs, int *st)
{
	int i;

	for (i = 0; i < secs * 10; i++) {
		if (waitpid(pid, st, WNOHANG) == pid)
			return 1;
		usleep(100000);
	}
	return 0;
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
	if (reap(pid, STOP_WAIT_S, &st))
		return;
	syslog(LOG_NOTICE, "mount_%s: mount_macfuse (pid %d) is still running after SIGKILL; left", fs, (int)pid);
	fprintf(stderr, "linuxfs-mount: mount_macfuse (pid %d) is still running after SIGKILL; left\n", (int)pid);
}

/* SIGTERM to process group pgid, then, after its leader (reaped, when it has not been yet: running) exits or STOP_WAIT_S, SIGKILL
 * to whatever of it is left */
static void stop_group(pid_t pgid, int running)
{
	int st;

	kill(-pgid, SIGTERM);
	if (running)
		reap(pgid, STOP_WAIT_S, &st);
	usleep(300000);	/* a moment for the rest of it to end on its own */
	kill(-pgid, SIGKILL);
	if (running)
		reap(pgid, STOP_WAIT_S, &st);
}

/* Root's mount, for a macFUSE that serves /dev/fd/N (macfuse's DETAILS.md): mount_macfuse, run as libfuse runs it, mounts MNT
 * with allow_other (root's to give) and sends the device; the CLI, as _linuxfs, gets it as fd FUSE_FD and its lklfuse serves it
 * through /dev/fd/FUSE_FD. Root waits, bounded, for mount_macfuse's status: 0 (and the CLI's 0) is exit 0; anything else
 * stops what _linuxfs started, unmounts MNT if it got mounted, stops mount_macfuse, and is the CLI's failure (or 1). Root
 * never reads the file system and never runs lklfuse. Every descriptor but 0-2 is closed in mount_macfuse, and in the CLI
 * all but 3 (the disk) and FUSE_FD. Unmounting (DiskArbitration, diskutil) ends lklfuse, which sees its device close. If lklfuse
 * dies first the mount stays, with nobody serving it: macFUSE fails its calls (a dead file system, ENXIO) rather than hang,
 * and it still unmounts (tests/smoke-mavericks.sh checks both). If the CLI fails before lklfuse answers INIT, mount_macfuse may
 * still hold its own copy of the device, blocked in mount(2): root's closing its copy cannot end that wait, and macFUSE offers
 * no ioctl that does (FUSEDEVIOCINTERRUPTREADERS wakes the device's readers, not the mount); the kernel gives up by itself,
 * EAGAIN after about 50 s (macfuse's smoke). So root stops it (stop()) and says so if even SIGKILL leaves it running. */
static int mount_by_root(const char *fs, const struct mountreq *req, const char *bsd, int ro, const char *name, uid_t uid,
			 gid_t gid, char **args)
{
	static const char *const vars[] = { ROOT_CLI_ENV, "LINUXFS_FUSE_FD=" STR(FUSE_FD), NULL };
	char opts[400], vol[256], commenv[32], hout_buf[4096];
	char daemon_env[] = "_FUSE_DAEMON_PATH=" PRIV_DIR "/lklfuse";
	char *hargv[5], *henv[5];
	const char *helper = mount_helper();
	int cs[2], hout[2], nul, devfd, fd, w, got = 0, cli_rc = -2, ok = 0;
	int32_t status = -1;
	size_t hgot = 0, sgot = 0;
	pid_t hpid, cpid;
	time_t deadline, cli_end = 0;

	fsrules_volname(strrchr(req->mnt, '/') + 1, vol, sizeof vol);
	snprintf(opts, sizeof opts, "allow_other,local,volname=%s,fsname=linuxfs@%s,noappledouble%s", vol, bsd, ro ? ",rdonly" : "");
	/* hold FUSE_FD (on /dev/null) so nothing opened below lands there; the device replaces it */
	nul = open("/dev/null", O_RDWR | O_CLOEXEC);
	if (nul < 0 || (nul != FUSE_FD && dup2(nul, FUSE_FD) < 0))
		return refuse(fs, "cannot hold a descriptor for the macFUSE device");
	if (nul != FUSE_FD)
		close(nul);
	fcntl(FUSE_FD, F_SETFD, FD_CLOEXEC);
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, cs) != 0)
		return refuse(fs, "cannot make mount_macfuse's socket");
	if (pipe(hout) != 0) {
		close(cs[0]);
		close(cs[1]);
		return refuse(fs, "cannot make mount_macfuse's pipe");
	}
	for (fd = 0; fd < 2; fd++) {
		fcntl(cs[fd], F_SETFD, FD_CLOEXEC);
		fcntl(hout[fd], F_SETFD, FD_CLOEXEC);
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
	printf("fd%d the macFUSE device\n", FUSE_FD);
	print_cli_plan(vars, args);
	if (getenv("LINUXFS_FS_TEST_ROOT_CLI"))
		args[0] = getenv("LINUXFS_FS_TEST_ROOT_CLI");
	if (!getenv("LINUXFS_FS_TEST_MOUNT_HELPER")) {
		close(cs[0]);
		close(cs[1]);
		close(hout[0]);
		close(hout[1]);
		return 0;
	}
#endif
	hpid = fork();
	if (hpid == 0) {
		int in = open("/dev/null", O_RDONLY);

		if (in < 0 || dup2(in, 0) < 0 || dup2(hout[1], 1) < 0 || dup2(hout[1], 2) < 0)
			_exit(127);
		for (fd = 3; fd < getdtablesize(); fd++)
			if (fd != cs[0])
				close(fd);
		fcntl(cs[0], F_SETFD, 0);
		execve(hargv[0], hargv, henv);
		_exit(127);
	}
	close(cs[0]);
	close(hout[1]);
	if (hpid < 0) {
		close(cs[1]);
		close(hout[0]);
		return refuse(fs, "cannot run mount_macfuse");
	}
	syslog(LOG_NOTICE, "mount_%s: %s on %s: mount_macfuse -o %s (pid %d)", fs, bsd, req->mnt, opts, (int)hpid);
	devfd = recv_device(cs[1], wait_s(DEVICE_WAIT_S));
	if (devfd < 0 || dup2(devfd, FUSE_FD) < 0) {
		if (devfd >= 0)
			close(devfd);
		syslog(LOG_NOTICE, "mount_%s: %s: mount_macfuse sent no macFUSE device within %d s", fs, bsd, wait_s(DEVICE_WAIT_S));
		fprintf(stderr, "linuxfs-mount: mount_macfuse sent no macFUSE device\n");
		cpid = -1;
		goto failed;
	}
	close(devfd);
	cpid = fork();
	if (cpid == 0) {
		setpgid(0, 0);	/* the CLI, its lklfuse and all: one group, for root to stop if the mount fails */
		close(cs[1]);
		close(hout[0]);
		if (become_run_user(fs, name, uid, gid) != 0)
			_exit(1);
		syslog(LOG_NOTICE, "mount_%s: %s on %s: da-mount as %s, the device on fd %d%s", fs, bsd, req->mnt, RUN_USER, FUSE_FD,
		       ro ? " (read-only)" : "");
		fd = root_cli(req, args, vars, FUSE_FD, name);
		_exit(fd < 0 ? 1 : fd);
	}
	if (cpid > 0)
		setpgid(cpid, cpid);
	close(3);	/* the disk and the device are the CLI's now: mount_macfuse and lklfuse hold the device */
	close(FUSE_FD);
	if (cpid < 0) {
		syslog(LOG_NOTICE, "mount_%s: %s: cannot run the CLI", fs, bsd);
		goto failed;
	}

	deadline = time(NULL) + wait_s(STATUS_WAIT_S);
	for (;;) {
		struct pollfd p[2];
		time_t now = time(NULL);
		ssize_t r;

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
		if (poll(p, 2, 200) < 0 && errno != EINTR)
			break;
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
	ok = got > 0 && status == 0 && (cli_rc == 0 || cli_rc == -2);
	if (ok) {
		syslog(LOG_NOTICE, "mount_%s: %s mounted on %s by root, served by %s%s", fs, bsd, req->mnt, RUN_USER,
		       cli_rc == -2 ? " (the CLI had not finished)" : "");
		close(cs[1]);
		/* mount_macfuse has said all it has to: one still running STOP_WAIT_S later gets SIGTERM, then after 1 s SIGKILL,
		 * and is reaped; no root helper outlives the mount program */
		if (hpid > 0 && !reap(hpid, STOP_WAIT_S, &w)) {
			syslog(LOG_NOTICE, "mount_%s: %s: mount_macfuse (pid %d) is still running after the mount; stopped", fs, bsd, (int)hpid);
			stop(fs, hpid, 1);
		}
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
		/* the CLI may be ending on its own (the status can arrive first): a moment for its exit status, the failure's reason */
		if (cpid > 0 && cli_rc == -2 && reap(cpid, 1, &w))
			cli_rc = WIFEXITED(w) ? WEXITSTATUS(w) : 1;
		if (cpid > 0)	/* the CLI and its lklfuse, if any: without the mount there is nothing for them to serve */
			stop_group(cpid, cli_rc == -2);
		fd = mounted_on(req->mnt, bsd);
		if (fd < 0)
			syslog(LOG_NOTICE, "mount_%s: %s: %s holds another volume than root's mount; left mounted", fs, bsd, req->mnt);
		if (fd > 0) {
			if (unmount(req->mnt, MNT_FORCE) == 0)
				syslog(LOG_NOTICE, "mount_%s: %s: unmounted %s", fs, bsd, req->mnt);
			else
				syslog(LOG_NOTICE, "mount_%s: %s: cannot unmount %s: %s", fs, bsd, req->mnt, strerror(errno));
		}
		stop(fs, hpid, STOP_WAIT_S);
		if (cs[1] >= 0)
			close(cs[1]);
		fprintf(stderr, "linuxfs-mount: root's mount of %s failed\n", bsd);
	}
	if (hout[0] >= 0) {
		ssize_t r;

		fcntl(hout[0], F_SETFL, fcntl(hout[0], F_GETFL) | O_NONBLOCK);
		while (hgot < sizeof hout_buf - 1 && (r = read(hout[0], hout_buf + hgot, sizeof hout_buf - 1 - hgot)) > 0)
			hgot += (size_t)r;
		close(hout[0]);
	}
	hout_buf[hgot] = '\0';
	log_lines("mount_macfuse", hout_buf);
	if (ok)
		return 0;
	return cli_rc > 0 ? cli_rc : 1;
}

/* Everything the mount program does as root, before login: _linuxfs's lookup, the device on fd 3, then root's mount
 * (mount_by_root) or, with an older macFUSE, MNT handed to _linuxfs, the drop and the bundled CLI. Returns only to refuse (1),
 * or with root's mount's outcome. Test builds print the plan and return 0 instead of the privileged calls. */
static int mount_as_root(const char *fs, const struct mountreq *req)
{
	static const char *const vars[] = { ROOT_CLI_ENV, NULL };
	struct passwd *pw;
	struct stat st;
	char node[64], devarg[64], name[64];
	char *args[8];
	const char *bsd;
	int fd, mfd, n = 0, ro_fallback = 0, ro, rc, by_root;
	uid_t uid;
	gid_t gid;

	fill_std_fds();
	bsd = strncmp(req->dev, "/dev/", 5) == 0 ? req->dev + 5 : req->dev;
	if (!valid_bsd(bsd))
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
		if (!type)
			return refuse(fs, "no filesystem linuxfs knows on the device");
		fs_read_prefs(&p);
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
#ifdef LINUXFS_FS_TEST_DROP
	printf("user %s\nuid %d\ngid %d\nfd3 %s %s\nmnt %s\n", name, (int)uid, (int)gid, node, ro_fallback ? "ro" : "rw", req->mnt);
#else
	/* only the owner changes: DiskArbitration's mode for the directory stays as it made it; root's own mount keeps it root's */
	if (!by_root && fchown(mfd, uid, gid) != 0) {
		close(mfd);
		return refuse(fs, "cannot hand the mount point to _linuxfs");
	}
#endif
	close(mfd);

	args[n++] = PRIV_DIR "/linuxfs";
	args[n++] = "da-mount";
	if (req->asked)
		args[n++] = "--asked";
	if (ro)
		args[n++] = "--ro";
	args[n++] = devarg;
	args[n++] = (char *)req->mnt;
	args[n] = NULL;

	if (by_root)
		return mount_by_root(fs, req, bsd, ro, name, uid, gid, args);
#ifdef LINUXFS_FS_TEST_DROP
	print_cli_plan(vars, args);
	/* a stand-in for the bundled CLI, to see what run_capture hands it and what comes back */
	if (!getenv("LINUXFS_FS_TEST_ROOT_CLI"))
		return 0;
	args[0] = getenv("LINUXFS_FS_TEST_ROOT_CLI");
#endif
	if (become_run_user(fs, name, uid, gid) != 0)
		return 1;
#ifndef LINUXFS_FS_TEST_DROP
	syslog(LOG_NOTICE, "mount_%s: %s on %s as %s%s", fs, bsd, req->mnt, RUN_USER, ro_fallback ? " (read-only device)" : "");
#endif
	/* Only fd 3 (the device) reaches the CLI. */
	rc = root_cli(req, args, vars, 3, name);
	return rc < 0 ? 1 : rc;
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
		fprintf(stderr, "usage: mount_linuxfs_%s [-o options] device mountpoint\n", fs);
		syslog(LOG_NOTICE, "mount_%s: bad arguments", fs);
		return 1;
	}
	syslog(LOG_NOTICE, "mount_%s: parsed asked=%d ro=%d", fs, req.asked, req.ro);
#ifdef LINUXFS_FS_TEST_DROP
	if (1)
#else
	if (getuid() == 0)
#endif
		return mount_as_root(fs, &req);
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
