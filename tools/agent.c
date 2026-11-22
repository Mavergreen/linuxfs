/*
 * linuxfs-agent: the per-user automounter (LaunchAgent dev.mavergreen.linuxfs.agent, in the console session).
 * usage: linuxfs-agent
 *        linuxfs-agent --ask DISK [HINT [wrong]]
 * Watches DiskArbitration. A leaf medium the Mac finds no filesystem on is probed through linuxfs-open
 * (the root helper reads it); if it holds a Linux filesystem the agent claims it, which keeps the Mac's
 * "disk not readable" dialog away, and runs `linuxfs automount DISK` once it appears. An NTFS volume the
 * Mac would mount read-only is refused to the Mac and handed to `linuxfs automount` instead, only when the
 * NTFSTakeover preference is on. A disk that disappears is unmounted with `linuxfs unmount --force`.
 * Never HFS+, FAT or exFAT; APFS only where the Mac cannot read it (10.9 cannot).
 * An encrypted APFS volume (automount exits 4): the agent asks for its password, then runs
 * `linuxfs mount DISK --password-stdin`; a wrong one is asked for again, with the volume's hint, three tries in all.
 * A password the user asks to remember goes in the login keychain (service dev.mavergreen.linuxfs, account the
 * partition's UUID), and is tried first next time. The asking is `linuxfs-agent --ask DISK [HINT [wrong]]`: a
 * dialog, which prints "remember" or "once", a newline and the password.
 * LINUXFS_CLI, LINUXFS_OPEN and LINUXFS_ASKPASS name other programs, and LINUXFS_KEYCHAIN=off keeps the keychain
 * out of it (tests).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <Security/Security.h>
#include <mach-o/dyld.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

extern char **environ;

#define PREFIX "/usr/local/mavergreen/linuxfs"
#define PREFS_DOMAIN CFSTR("dev.mavergreen.linuxfs")

enum { ACT_NONE, ACT_PROBE, ACT_TAKEOVER };

/*
 * What to do with a disk, from what DiskArbitration says of it: LEAF (no partitions under it), KIND (the
 * Mac's filesystem name for it, NULL when it found none), MOUNTED (it has a volume path) and the
 * NTFSTakeover and Automount preferences. Automount off means nothing is taken (review I4: dissenting from the
 * Mac's mount with nothing to mount it instead left NTFS unmountable). EJECTABLE: NTFS is taken over only on
 * ejectable media, as the helper serves it; internal NTFS is Windows's own (Boot Camp: review M8).
 */
int agent_action(int leaf, const char *kind, int mounted, int takeover, int automount, int ejectable)
{
	if (!leaf || mounted || !automount)
		return ACT_NONE;
	if (!kind)
		return ACT_PROBE;
	if (strcmp(kind, "ntfs") == 0 && takeover && ejectable)
		return ACT_TAKEOVER;
	return ACT_NONE;
}

/* Whether a probe's "TYPE<TAB>LABEL" line names a filesystem the agent should claim the disk for. */
int agent_claims(const char *probed)
{
	static const char *ours[] = { "ext4\t", "btrfs\t", "xfs\t", "f2fs\t", "apfs\t", NULL };

	for (int i = 0; ours[i]; i++)
		if (strncmp(probed, ours[i], strlen(ours[i])) == 0)
			return 1;
	return 0;
}

/*
 * Whether linuxfs has disk BSD mounted: its lklfuse holds an exclusive flock on DIR/linuxfs-rBSD.lock for as long
 * as it runs (the CLI's lock= for a device). Review M6: the Mac must not mount a disk under lklfuse.
 */
int agent_holds(const char *dir, const char *bsd)
{
	char path[1024];
	int fd, held;

	snprintf(path, sizeof(path), "%s/linuxfs-r%s.lock", dir, bsd);
	fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0)
		return 0;
	held = flock(fd, LOCK_SH | LOCK_NB) < 0 && errno == EWOULDBLOCK;
	close(fd);
	return held;
}

/* The hint in the CLI's "wrong password for DEVICE (hint: HINT)", into HINT (LEN bytes); 0 when it names none. */
int agent_hint(const char *err, char *hint, size_t len)
{
	const char *p = NULL, *s = err, *q, *e;

	while ((q = strstr(s, "(hint: "))) {
		p = q + 7;
		s = p;
	}
	if (!p || !len)
		return 0;
	e = strchr(p, '\n');
	if (!e)
		e = p + strlen(p);
	if (e > p && e[-1] == ')')
		e--;
	snprintf(hint, len, "%.*s", (int)(e - p), p);
	return 1;
}

/*
 * The asking's answer, BUF (N bytes, with room for a NUL after them): "remember" or "once", a newline, then the
 * password, whose one trailing newline is dropped. Sets *REMEMBER and *PW (into BUF); -1 when it is neither.
 */
int agent_parse_answer(char *buf, size_t n, int *remember, const char **pw)
{
	char *nl = memchr(buf, '\n', n);
	size_t pl;

	if (!nl)
		return -1;
	*nl = '\0';
	if (strcmp(buf, "remember") == 0)
		*remember = 1;
	else if (strcmp(buf, "once") == 0)
		*remember = 0;
	else
		return -1;
	pl = n - (size_t)(nl + 1 - buf);
	if (pl && nl[pl] == '\n')
		pl--;
	nl[1 + pl] = '\0';
	*pw = nl + 1;
	return 0;
}

#ifndef LINUXFS_AGENT_NO_MAIN
static const char *cli, *opener;
static CFMutableSetRef claimed;		/* BSD names claimed at peek, mounted when they appear */
static CFMutableSetRef mac_gets;		/* NTFS whose takeover failed: the Mac may mount it after all */
static CFMutableDictionaryRef takeovers;	/* pid of a takeover's `linuxfs automount` -> its BSD name */
static DASessionRef session;
static const char *askpass;		/* LINUXFS_ASKPASS, or NULL: this program, as --ask */
static int use_keychain;

/* What the agent is waiting on for an encrypted volume: automount, the asking, the mount with the password */
enum { JOB_AUTOMOUNT = 1, JOB_ASK, JOB_UNLOCK };
#define MAX_TRIES 3
struct job {
	pid_t pid;
	int kind;
	char bsd[64];
	int fd;			/* JOB_ASK: its answer */
	int tries;		/* passwords asked for so far, before this one */
	int remember;		/* JOB_UNLOCK: keep the password in the keychain if it works */
	int saved;		/* JOB_UNLOCK: the password came from the keychain */
	char errpath[64];	/* JOB_UNLOCK: the CLI's stderr (its hint) */
	char pw[1024];		/* JOB_UNLOCK */
};
static struct job jobs[16];

static const char *env_or(const char *name, const char *dflt)
{
	const char *v = getenv(name);

	return v && *v ? v : dflt;
}

/* the CLI's lock directory (cli/linuxfs: LOCKS) */
static const char *locks_dir(void)
{
	static char dir[1024];
	const char *home = getenv("HOME");

	if (!dir[0])
		snprintf(dir, sizeof(dir), "%s", env_or("LINUXFS_LOCKS", ""));
	if (!dir[0])
		snprintf(dir, sizeof(dir), "%s/Library/Caches/dev.mavergreen.linuxfs/locks", home ? home : "");
	return dir;
}

static int pref_on(CFStringRef key, int dflt)
{
	Boolean valid = false, on;

	CFPreferencesAppSynchronize(PREFS_DOMAIN);
	on = CFPreferencesGetAppBooleanValue(key, PREFS_DOMAIN, &valid);
	return valid ? on : dflt;
}

static pid_t run_cli(const char *verb, const char *flag, const char *bsd)
{
	const char *argv[] = { cli, verb, flag ? flag : bsd, flag ? bsd : NULL, NULL };
	pid_t pid;

	syslog(LOG_NOTICE, "%s %s %s", cli, verb, bsd);
	if (posix_spawn(&pid, cli, NULL, NULL, (char **)argv, environ) != 0) {
		syslog(LOG_ERR, "cannot run %s: %s", cli, strerror(errno));
		return -1;
	}
	return pid;
}

static struct job *job_add(pid_t pid, int kind, const char *bsd)
{
	for (size_t i = 0; i < sizeof(jobs) / sizeof(jobs[0]); i++)
		if (!jobs[i].pid) {
			memset(&jobs[i], 0, sizeof(jobs[i]));
			jobs[i].pid = pid;
			jobs[i].kind = kind;
			jobs[i].fd = -1;
			snprintf(jobs[i].bsd, sizeof(jobs[i].bsd), "%s", bsd);
			return &jobs[i];
		}
	syslog(LOG_ERR, "too many disks waiting at once; not following %s", bsd);
	return NULL;
}

static void automount(const char *bsd)
{
	pid_t pid = run_cli("automount", NULL, bsd);

	if (pid > 0)
		job_add(pid, JOB_AUTOMOUNT, bsd);
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

#define KC_SERVICE "dev.mavergreen.linuxfs"

static int keychain_find(const char *bsd, char *pw, size_t len)
{
	char acct[64];
	UInt32 n = 0;
	void *data = NULL;
	int ok;

	if (!use_keychain || !keychain_account(bsd, acct, sizeof(acct)) ||
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

	if (!use_keychain)
		return;
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

/* Asks for disk BSD's password: runs the asking with its stdout on a pipe, read when it exits. */
static void ask(const char *bsd, int tries, const char *hint, int wrong)
{
	static char self[1024];
	uint32_t sz = sizeof(self);
	const char *argv[7];
	int a = 0, p[2];
	posix_spawn_file_actions_t fa;
	pid_t pid;
	struct job *j;

	if (!askpass && !self[0] && _NSGetExecutablePath(self, &sz) != 0)
		return;
	argv[a++] = askpass ? askpass : self;
	if (!askpass)
		argv[a++] = "--ask";
	argv[a++] = bsd;
	if (*hint || wrong)
		argv[a++] = hint;
	if (wrong)
		argv[a++] = "wrong";
	argv[a] = NULL;
	if (pipe(p) < 0)
		return;
	fcntl(p[0], F_SETFD, FD_CLOEXEC);
	fcntl(p[1], F_SETFD, FD_CLOEXEC);
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, p[1], 1);
	if (posix_spawn(&pid, argv[0], &fa, NULL, (char **)argv, environ) != 0) {
		syslog(LOG_ERR, "cannot run %s: %s", argv[0], strerror(errno));
		close(p[0]);
		pid = -1;
	}
	posix_spawn_file_actions_destroy(&fa);
	close(p[1]);
	if (pid > 0 && (j = job_add(pid, JOB_ASK, bsd))) {
		j->fd = p[0];
		j->tries = tries;
	} else if (pid > 0) {
		close(p[0]);
	}
}

/* `linuxfs mount BSD --password-stdin`, the password written to its stdin; its stderr kept for the hint. */
static void unlock(const char *bsd, const char *pw, int tries, int remember, int saved)
{
	const char *argv[] = { cli, "mount", bsd, "--password-stdin", NULL };
	char errpath[64];
	posix_spawn_file_actions_t fa;
	int in[2], efd;
	pid_t pid;
	struct job *j;

	snprintf(errpath, sizeof(errpath), "%s/linuxfs-agent.XXXXXX", env_or("TMPDIR", "/tmp"));
	if (strlen(errpath) >= sizeof(errpath) - 1)
		snprintf(errpath, sizeof(errpath), "/tmp/linuxfs-agent.XXXXXX");
	efd = mkstemp(errpath);
	if (efd < 0 || pipe(in) < 0) {
		if (efd >= 0) {
			close(efd);
			unlink(errpath);
		}
		return;
	}
	fcntl(in[0], F_SETFD, FD_CLOEXEC);
	fcntl(in[1], F_SETFD, FD_CLOEXEC);
	fcntl(efd, F_SETFD, FD_CLOEXEC);
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, in[0], 0);
	posix_spawn_file_actions_adddup2(&fa, efd, 2);
	syslog(LOG_NOTICE, "%s mount %s --password-stdin", cli, bsd);
	if (posix_spawn(&pid, cli, &fa, NULL, (char **)argv, environ) != 0) {
		syslog(LOG_ERR, "cannot run %s: %s", cli, strerror(errno));
		pid = -1;
	}
	posix_spawn_file_actions_destroy(&fa);
	close(in[0]);
	close(efd);
	if (pid > 0) {
		/* a password fits in the pipe's buffer, so this never waits on the CLI */
		if (write(in[1], pw, strlen(pw)) < 0 || write(in[1], "\n", 1) < 0)
			syslog(LOG_ERR, "cannot give %s its password", bsd);
	}
	close(in[1]);
	if (pid > 0 && (j = job_add(pid, JOB_UNLOCK, bsd))) {
		j->tries = tries;
		j->remember = remember;
		j->saved = saved;
		snprintf(j->errpath, sizeof(j->errpath), "%s", errpath);
		snprintf(j->pw, sizeof(j->pw), "%s", pw);
	} else {
		unlink(errpath);
	}
}

/* An encrypted volume wants its password: the keychain's first, else ask. */
static void need_password(const char *bsd)
{
	char pw[1024];

	if (keychain_find(bsd, pw, sizeof(pw))) {
		syslog(LOG_NOTICE, "%s: trying the password from the keychain", bsd);
		unlock(bsd, pw, 0, 0, 1);
		memset(pw, 0, sizeof(pw));
		return;
	}
	ask(bsd, 0, "", 0);
}

static void job_done(pid_t pid, int status)
{
	int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
	struct job *j = NULL;
	char buf[2048], hint[256] = "";
	ssize_t n = 0, r;

	for (size_t i = 0; i < sizeof(jobs) / sizeof(jobs[0]); i++)
		if (jobs[i].pid == pid)
			j = &jobs[i];
	if (!j)
		return;
	switch (j->kind) {
	case JOB_AUTOMOUNT:
		if (code == 4)
			need_password(j->bsd);
		break;
	case JOB_ASK:
		while (code == 0 && (size_t)n < sizeof(buf) - 1 && (r = read(j->fd, buf + n, sizeof(buf) - 1 - n)) != 0) {
			if (r < 0 && errno == EINTR)
				continue;
			if (r < 0)
				break;
			n += r;
		}
		close(j->fd);
		if (code == 0) {
			int remember;
			const char *pw;

			buf[n] = '\0';
			if (agent_parse_answer(buf, (size_t)n, &remember, &pw) == 0)
				unlock(j->bsd, pw, j->tries, remember, 0);
			else
				syslog(LOG_ERR, "the password dialog for %s answered nonsense", j->bsd);
		}
		memset(buf, 0, sizeof(buf));
		break;
	case JOB_UNLOCK: {
		int fd = open(j->errpath, O_RDONLY | O_CLOEXEC);

		if (fd >= 0) {
			n = read(fd, buf, sizeof(buf) - 1);
			buf[n > 0 ? n : 0] = '\0';
			close(fd);
			agent_hint(buf, hint, sizeof(hint));
		}
		unlink(j->errpath);
		if (code == 0 && j->remember)
			keychain_save(j->bsd, j->pw);
		else if (code == 4 && j->saved)
			ask(j->bsd, 0, hint, 1);	/* the keychain's password no longer works */
		else if (code == 4 && j->tries + 1 < MAX_TRIES)
			ask(j->bsd, j->tries + 1, hint, 1);
		else if (code == 4)
			syslog(LOG_NOTICE, "%s: wrong password %d times; not asking again", j->bsd, MAX_TRIES);
		break;
	}
	}
	memset(j, 0, sizeof(*j));
}

/* --ask DISK [HINT [wrong]]: the password dialog; prints "remember" or "once", a newline, the password. */
static int ask_main(int argc, char **argv)
{
	const char *bsd = argv[2], *hint = argc > 3 ? argv[3] : "";
	int wrong = argc > 4;
	char msg[1024], pw[1024];
	CFStringRef field = CFSTR("Password"), box = CFSTR("Remember this password in my keychain"), m, answer;
	CFArrayRef fields = CFArrayCreate(NULL, (const void **)&field, 1, &kCFTypeArrayCallBacks);
	CFArrayRef boxes = CFArrayCreate(NULL, (const void **)&box, 1, &kCFTypeArrayCallBacks);
	CFUserNotificationRef note;
	CFDictionaryRef d;
	CFOptionFlags resp = 0;
	SInt32 err = 0;
	int ok;

	snprintf(msg, sizeof(msg), "%sEnter the password of the encrypted APFS volume on %s. linuxfs mounts it read-only.%s%s",
		 wrong ? "That password was not right. " : "", bsd, *hint ? "\n\nHint: " : "", hint);
	m = CFStringCreateWithCString(NULL, msg, kCFStringEncodingUTF8);
	{
		const void *keys[] = { kCFUserNotificationAlertHeaderKey, kCFUserNotificationAlertMessageKey,
				       kCFUserNotificationTextFieldTitlesKey, kCFUserNotificationCheckBoxTitlesKey,
				       kCFUserNotificationDefaultButtonTitleKey, kCFUserNotificationAlternateButtonTitleKey };
		const void *vals[] = { CFSTR("Unlock an encrypted volume"), m, fields, boxes, CFSTR("Mount"), CFSTR("Cancel") };

		d = CFDictionaryCreate(NULL, keys, vals, 6, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	}
	note = CFUserNotificationCreate(NULL, 0, kCFUserNotificationPlainAlertLevel | CFUserNotificationSecureTextField(0), &err, d);
	ok = note && CFUserNotificationReceiveResponse(note, 0, &resp) == 0 &&
	     (resp & 0x3) == kCFUserNotificationDefaultResponse &&
	     (answer = CFUserNotificationGetResponseValue(note, kCFUserNotificationTextFieldValuesKey, 0)) &&
	     CFStringGetCString(answer, pw, sizeof(pw), kCFStringEncodingUTF8);
	if (ok)
		printf("%s\n%s\n", resp & CFUserNotificationCheckBoxChecked(0) ? "remember" : "once", pw);
	memset(pw, 0, sizeof(pw));
	return ok ? 0 : 1;
}

static CFStringRef cfname(const char *bsd)
{
	return CFStringCreateWithCString(NULL, bsd, kCFStringEncodingUTF8);
}

/* linuxfs-open --probe /dev/BSD, its first line in OUT; returns its exit status (-1 when it cannot run). */
static int probe(const char *bsd, char *out, size_t len)
{
	char dev[64];
	const char *argv[] = { opener, "--probe", dev, NULL };
	posix_spawn_file_actions_t fa;
	int p[2], status;
	ssize_t n;
	pid_t pid;

	snprintf(dev, sizeof(dev), "/dev/%s", bsd);
	out[0] = '\0';
	if (pipe(p) < 0)
		return -1;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, p[1], 1);
	posix_spawn_file_actions_addclose(&fa, p[0]);
	if (posix_spawn(&pid, opener, &fa, NULL, (char **)argv, environ) != 0) {
		posix_spawn_file_actions_destroy(&fa);
		close(p[0]);
		close(p[1]);
		return -1;
	}
	posix_spawn_file_actions_destroy(&fa);
	close(p[1]);
	n = read(p[0], out, len - 1);
	close(p[0]);
	out[n > 0 ? n : 0] = '\0';
	out[strcspn(out, "\n")] = '\0';
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* The facts agent_action needs; BSD filled with the disk's BSD name. Returns 0 when the disk has none. */
static int describe(DADiskRef disk, char *bsd, size_t len, int *leaf, char *kind, size_t kindlen, int *mounted,
		    int *ejectable)
{
	CFDictionaryRef d;
	CFStringRef k;
	CFBooleanRef l, e, r;
	const char *name = DADiskGetBSDName(disk);

	if (!name)
		return 0;
	snprintf(bsd, len, "%s", name);
	d = DADiskCopyDescription(disk);
	if (!d)
		return 0;
	l = CFDictionaryGetValue(d, kDADiskDescriptionMediaLeafKey);
	*leaf = l && CFBooleanGetValue(l);
	k = CFDictionaryGetValue(d, kDADiskDescriptionVolumeKindKey);
	kind[0] = '\0';
	if (k)
		CFStringGetCString(k, kind, kindlen, kCFStringEncodingUTF8);
	*mounted = CFDictionaryGetValue(d, kDADiskDescriptionVolumePathKey) != NULL;
	e = CFDictionaryGetValue(d, kDADiskDescriptionMediaEjectableKey);
	r = CFDictionaryGetValue(d, kDADiskDescriptionMediaRemovableKey);
	*ejectable = (e && CFBooleanGetValue(e)) || (r && CFBooleanGetValue(r));
	CFRelease(d);
	return 1;
}

static int action_for(DADiskRef disk, char *bsd, size_t len)
{
	char kind[64];
	int leaf, mounted, ejectable;

	bsd[0] = '\0';
	if (!describe(disk, bsd, len, &leaf, kind, sizeof(kind), &mounted, &ejectable))
		return ACT_NONE;
	return agent_action(leaf, kind[0] ? kind : NULL, mounted, pref_on(CFSTR("NTFSTakeover"), 0), pref_on(CFSTR("Automount"), 1),
			    ejectable);
}

static DADissenterRef released(DADiskRef disk, void *ctx)
{
	(void)disk;
	(void)ctx;
	return NULL;	/* let whoever asks have it */
}

static void peeked(DADiskRef disk, void *ctx)
{
	char bsd[64], probed[512];
	CFStringRef name;
	int rc;

	(void)ctx;
	if (action_for(disk, bsd, sizeof(bsd)) != ACT_PROBE)
		return;
	rc = probe(bsd, probed, sizeof(probed));
	if (rc != 0 || !agent_claims(probed))
		return;
	syslog(LOG_NOTICE, "%s holds %s; claiming it", bsd, probed);
	DADiskClaim(disk, kDADiskClaimOptionDefault, released, NULL, NULL, NULL);
	name = CFStringCreateWithCString(NULL, bsd, kCFStringEncodingUTF8);
	CFSetAddValue(claimed, name);
	CFRelease(name);
}

static void appeared(DADiskRef disk, void *ctx)
{
	char bsd[64];
	CFStringRef name;
	int act;

	(void)ctx;
	act = action_for(disk, bsd, sizeof(bsd));
	if (!bsd[0])
		return;
	name = CFStringCreateWithCString(NULL, bsd, kCFStringEncodingUTF8);
	if (CFSetContainsValue(claimed, name)) {
		CFSetRemoveValue(claimed, name);
		automount(bsd);
	} else if (act == ACT_PROBE) {
		/* present before the agent started (login): no peek was seen */
		char probed[512];

		if (probe(bsd, probed, sizeof(probed)) == 0 && agent_claims(probed))
			automount(bsd);
	}
	CFRelease(name);
}

/*
 * A disk being ejected (Finder, diskutil, hdiutil detach, even -force): lklfuse holds it open, so it would not go,
 * nor ever disappear, while linuxfs has it mounted (P3-2). Unmount linuxfs's volumes on it first, waiting for that
 * (at most EJECT_WAIT seconds), then let the eject go on. The run loop is held meanwhile, as DiskArbitration expects;
 * but it waits only 10 s for an answer, then finds the agent "not responding" and ejects without it, so the
 * disk still open fails busy (P3-3). So the agent answers sooner, and an unmount still running is reaped later.
 */
#define EJECT_WAIT 7
static DADissenterRef approve_eject(DADiskRef disk, void *ctx)
{
	const char *bsd = DADiskGetBSDName(disk);
	pid_t pid;
	int status, i;

	(void)ctx;
	if (!bsd || (pid = run_cli("unmount", "--force", bsd)) <= 0)
		return NULL;
	for (i = 0; i < EJECT_WAIT * 10; i++) {
		if (waitpid(pid, &status, WNOHANG) != 0)
			return NULL;
		usleep(100000);
	}
	syslog(LOG_ERR, "unmounting %s for its eject is taking over %d s; letting the eject go on", bsd, EJECT_WAIT);
	return NULL;
}

static DADissenterRef approve_mount(DADiskRef disk, void *ctx)
{
	char bsd[64];
	CFStringRef name;
	CFNumberRef key;
	pid_t pid;
	int gets;

	(void)ctx;
	if (action_for(disk, bsd, sizeof(bsd)) != ACT_TAKEOVER) {
		if (bsd[0] && agent_holds(locks_dir(), bsd))
			return DADissenterCreate(NULL, kDAReturnExclusiveAccess, CFSTR("linuxfs has this volume mounted"));
		return NULL;
	}
	name = cfname(bsd);
	gets = CFSetContainsValue(mac_gets, name);
	if (!gets && (pid = run_cli("automount", NULL, bsd)) > 0) {
		key = CFNumberCreate(NULL, kCFNumberIntType, &pid);
		CFDictionarySetValue(takeovers, key, name);
		CFRelease(key);
	}
	CFRelease(name);
	if (gets)
		return NULL;
	return DADissenterCreate(NULL, kDAReturnExclusiveAccess, CFSTR("linuxfs mounts this NTFS volume (NTFSTakeover)"));
}

/* A takeover's `linuxfs automount` failed (or declined): hand the volume back to the Mac's own driver. */
static void takeover_done(pid_t pid, int status)
{
	CFNumberRef key = CFNumberCreate(NULL, kCFNumberIntType, &pid);
	CFStringRef name = CFDictionaryGetValue(takeovers, key);
	char bsd[64];
	DADiskRef disk;

	if (name) {
		CFStringGetCString(name, bsd, sizeof(bsd), kCFStringEncodingUTF8);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
			syslog(LOG_NOTICE, "linuxfs did not mount %s; the Mac may", bsd);
			CFSetAddValue(mac_gets, name);
			if ((disk = DADiskCreateFromBSDName(NULL, session, bsd))) {
				DADiskMount(disk, NULL, kDADiskMountOptionDefault, NULL, NULL);
				CFRelease(disk);
			}
		}
		CFDictionaryRemoveValue(takeovers, key);
	}
	CFRelease(key);
}

static void disappeared(DADiskRef disk, void *ctx)
{
	const char *bsd = DADiskGetBSDName(disk);
	CFStringRef name;

	(void)ctx;
	if (!bsd)
		return;
	name = cfname(bsd);
	CFSetRemoveValue(mac_gets, name);
	CFSetRemoveValue(claimed, name);	/* review M9: a claim for a disk that never appeared */
	CFRelease(name);
	run_cli("unmount", "--force", bsd);
}

static void reap(CFRunLoopTimerRef t, void *ctx)
{
	(void)t;
	(void)ctx;
	pid_t pid;
	int status;

	while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
		takeover_done(pid, status);
		job_done(pid, status);
	}
}

int main(int argc, char **argv)
{
	DASessionRef s;

	if (argc >= 3 && argc <= 5 && strcmp(argv[1], "--ask") == 0)
		return ask_main(argc, argv);
	if (argc != 1) {
		fprintf(stderr, "usage: linuxfs-agent\n       linuxfs-agent --ask DISK [HINT [wrong]]\n");
		return 2;
	}
	openlog("linuxfs-agent", LOG_PERROR | LOG_PID, LOG_USER);
	cli = env_or("LINUXFS_CLI", PREFIX "/bin/linuxfs");
	opener = env_or("LINUXFS_OPEN", PREFIX "/libexec/linuxfs-open");
	askpass = getenv("LINUXFS_ASKPASS") && *getenv("LINUXFS_ASKPASS") ? getenv("LINUXFS_ASKPASS") : NULL;
	use_keychain = strcmp(env_or("LINUXFS_KEYCHAIN", "on"), "off") != 0;
	claimed = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
	mac_gets = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
	takeovers = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	session = s = DASessionCreate(NULL);
	if (!s) {
		syslog(LOG_ERR, "no DiskArbitration session");
		return 1;
	}
	DARegisterDiskPeekCallback(s, NULL, 0, peeked, NULL);
	DARegisterDiskAppearedCallback(s, NULL, appeared, NULL);
	DARegisterDiskMountApprovalCallback(s, NULL, approve_mount, NULL);
	DARegisterDiskEjectApprovalCallback(s, NULL, approve_eject, NULL);
	DARegisterDiskDisappearedCallback(s, NULL, disappeared, NULL);
	DASessionScheduleWithRunLoop(s, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	CFRunLoopAddTimer(CFRunLoopGetCurrent(),
			  CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0, reap, NULL),
			  kCFRunLoopDefaultMode);
	syslog(LOG_NOTICE, "watching disks");
	CFRunLoopRun();
	return 0;
}
#endif
