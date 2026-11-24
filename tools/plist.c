/* linuxfs's preferences as root-run code reads them (see plist.h). */
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include "plist.h"

#define PREFS_NAME "dev.mavergreen.linuxfs.plist"
#define PREFS_MAX (1024 * 1024)
#define FATAL_EXIT 254	/* never go on as the user: the bundles' util reads this as "not recognised" */

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
		_exit(FATAL_EXIT);
	return -1;
}

/* root again, in reverse order; failing to is fatal: never go on as the user */
static void restore_root(const struct ids *save)
{
	if (seteuid(0) != 0 || setegid(save->egid) != 0 || setgroups(save->ngroups, save->groups) != 0)
		_exit(FATAL_EXIT);
}

/* the plist at path, owned by uid (or by root too when also_root), a regular file that is not a symlink and at most
 * 1 MiB (with locked, also writable by its owner alone); NULL for anything else, including unparseable. With drop, from
 * root, it is opened and read as uid/gid (no other groups), so root's reach never extends into what the user can name;
 * root is back before it is parsed. */
static CFDictionaryRef load_plist(const char *path, uid_t uid, gid_t gid, int also_root, int drop, int locked)
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
		    (st.st_uid == uid || (also_root && st.st_uid == 0)) && !(locked && (st.st_mode & 022)) &&
		    (buf = malloc((size_t)st.st_size + 1)) != NULL) {
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

int pref_bool(CFDictionaryRef d, CFStringRef key)
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

void prefs_load(CFDictionaryRef *user, CFDictionaryRef *machine)
{
	char userpath[1024], machpath[1024];
	const char *up = NULL, *mp = "/Library/Preferences/" PREFS_NAME;
	uid_t uowner = (uid_t)-1, mowner = 0;
	gid_t ugid = 0;
	int also_root = 1;

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

		if (stat("/dev/console", &st) == 0 && st.st_uid != 0 && (pw = getpwuid(st.st_uid)) != NULL &&
		    pw->pw_dir && pw->pw_dir[0] == '/' &&
		    snprintf(userpath, sizeof userpath, "%s/Library/Preferences/" PREFS_NAME, pw->pw_dir) < (int)sizeof userpath) {
			up = userpath;
			uowner = st.st_uid;
			ugid = pw->pw_gid;
		}
	}
	snprintf(machpath, sizeof machpath, "%s", mp);
	*user = up ? load_plist(up, uowner, ugid, 0, 1, 0) : NULL;
	*machine = load_plist(machpath, mowner, 0, also_root, 0, 0);
}

CFDictionaryRef plist_load_owned(const char *path, uid_t owner)
{
	return load_plist(path, owner, 0, 0, 0, 1);
}
