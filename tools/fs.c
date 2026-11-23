/*
 * linuxfs-fs: the one program inside each filesystem bundle (/System/Library/Filesystems/linuxfs_<fs>.fs), copied
 * under three names -- linuxfs_<fs>.util (probe), mount_linuxfs_<fs>, fsck_linuxfs_<fs> -- that picks its role and
 * its filesystem from argv[0]. DiskArbitration runs it as root with a bare environment, so everything here is C
 * and nothing is ever executed. Decisions come from fsrules.c; superblocks from probe.c.
 *
 * util -p BSD removable|fixed readonly|writable   recognised: the volume name on stdout, exit 255; else exit 254
 * util -k BSD                                     the filesystem's UUID on stdout, exit 255; else exit 254
 * fsck -q DEV                                     exit 0 (a quick check has nothing to do); -n or -y exit 8
 * mount                                           not yet (Tasks 6 and 7): exit 1
 */
#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <syslog.h>
#include <unistd.h>
#include "fsrules.h"
#include "probe.h"

#define FSUR_RECOGNIZED 255
#define FSUR_UNRECOGNIZED 254
#define PREFS_NAME "dev.mavergreen.linuxfs.plist"
#define PREFS_MAX (1024 * 1024)

/* the plist at path, owned by uid (or by root too when also_root), a regular file that is not a symlink and at most
 * 1 MiB; NULL for anything else, including unparseable */
static CFDictionaryRef load_plist(const char *path, uid_t uid, int also_root)
{
	struct stat st;
	int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
	char *buf = NULL;
	size_t got = 0;
	CFDictionaryRef dict = NULL;

	if (fd < 0)
		return NULL;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > PREFS_MAX ||
	    (st.st_uid != uid && !(also_root && st.st_uid == 0)))
		goto done;
	buf = malloc((size_t)st.st_size + 1);
	if (!buf)
		goto done;
	while (got < (size_t)st.st_size) {
		ssize_t r = read(fd, buf + got, (size_t)st.st_size - got);

		if (r <= 0)
			break;
		got += (size_t)r;
	}
	if (got == (size_t)st.st_size && got > 0) {
		CFDataRef data = CFDataCreate(NULL, (const UInt8 *)buf, (CFIndex)got);
		CFPropertyListRef pl = data ? CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL) : NULL;

		if (pl && CFGetTypeID(pl) == CFDictionaryGetTypeID())
			dict = pl;
		else if (pl)
			CFRelease(pl);
		if (data)
			CFRelease(data);
	}
done:
	free(buf);
	close(fd);
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

static void pref_apply(CFDictionaryRef d, const char *label, struct fsprefs *p, int *have, int *ignored)
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
			if (pref_bool(d, k) == 1)
				*ignored = 1;
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
	int also_root = 1, have[4] = { 0, 0, 0, 0 };
	CFDictionaryRef ud, md;

	fsrules_default_prefs(p);
	*ignored = 0;
	if (getuid() != 0 && (getenv("LINUXFS_PREFS_USER") || getenv("LINUXFS_PREFS_MACHINE"))) {
		const char *u = getenv("LINUXFS_PREFS_USER"), *m = getenv("LINUXFS_PREFS_MACHINE");

		up = u;
		if (m)
			mp = m;
		uowner = mowner = getuid();
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
		}
	}
	snprintf(machpath, sizeof machpath, "%s", mp);
	ud = up ? load_plist(up, uowner, 0) : NULL;
	md = load_plist(machpath, mowner, also_root);
	if (ud)
		pref_apply(ud, label, p, have, ignored);
	if (md)
		pref_apply(md, label, p, have, ignored);
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
		struct fsprefs all = { 1, 0, 1, 1 };

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
	int i, quick = 0, repair = 0;

	for (i = 1; i < argc; i++) {
		if (argv[i][0] != '-')
			continue;
		if (strchr(argv[i], 'n') || strchr(argv[i], 'y'))
			repair = 1;
		if (strchr(argv[i], 'q'))
			quick = 1;
	}
	if (repair) {
		printf("Verify and Repair for %s come with its tools\n", fs);
		syslog(LOG_NOTICE, "fsck_%s: verify/repair refused (phase 1)", fs);
		return 8;
	}
	if (quick)
		return 0;
	syslog(LOG_NOTICE, "fsck_%s: unknown arguments", fs);
	return 8;
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
		syslog(LOG_NOTICE, "mount_linuxfs_%s: not yet", fs);
		return 1;
	}
	return 1;
}
