/*
 * linuxfs-helper: the one root part of linuxfs. Opens a disk partition that holds a Linux filesystem, for the
 * user at the console, and hands them the descriptor; lklfuse then runs as that user.
 * usage: linuxfs-helper [--socket PATH] [--timeout SECONDS]       (run by launchd as dev.mavergreen.linuxfs.helper)
 *        linuxfs-helper --migrate-prefs                            (run by the postinstall, as root)
 *        linuxfs-helper --noauto-remove-all                        (run by pre-uninstall, as root: noauto-remove-all)
 * Protocol, one request per connection, one line each way:
 *   "open /dev/rdiskNsM rw|ro"  ->  "ok TYPE<TAB>LABEL" plus the descriptor (SCM_RIGHTS), or "no REASON"
 *   "probe /dev/rdiskNsM"       ->  "ok TYPE<TAB>LABEL", or "no REASON"
 *   "uuid /dev/rdiskNsM"        ->  "ok UUID" (the probe's, as the bundles' util -k gives it), or "no REASON"
 *   "noauto-add SPEC BUNDLE"    ->  "ok", or "no REASON": /etc/fstab gets SPEC's linuxfs noauto entry (fstab.h); SPEC is
 *                                   UUID=... or LABEL=<label>, which may hold spaces: BUNDLE is the line's last word. Only
 *                                   for a volume attached now: the helper probes the disks for one of BUNDLE's type with
 *                                   that UUID or volume name, else the reason "no attached linuxfs
 *                                   volume matches"
 *   "noauto-remove SPEC"        ->  "ok", or "no REASON": SPEC's linuxfs entry goes
 *   "noauto-remove-all"         ->  "ok", or "no REASON": every linuxfs entry goes, and no other line
 * It refuses a peer other than root or the console user (before reading its request), a request of more than one line,
 * a path other than a raw disk node, a partition the Mac has mounted, a disk with partitions under it, a system partition
 * by type (EFI, Apple, Windows, from IOKit), FAT, exFAT or NTFS on internal media, and any partition whose superblock is
 * not a filesystem linuxfs knows. It checks SPEC and BUNDLE itself, never trusting the CLI, and edits only linuxfs's own
 * lines of an /etc/fstab that is a regular root-owned file of at most 64 KiB, writing it whole (a new file beside it,
 * renamed over it); adding an entry that is there, or removing one that is not, is "ok". It never runs a program.
 * --migrate-prefs turns each Ignore:<LABEL> = true preference (the console user's and the machine's: the old way to keep a
 * volume from mounting by itself) into a LABEL= entry, when a disk with a volume of that name is attached to give the
 * bundle; it prints "user|machine<TAB>LABEL" for each it converted, for the postinstall to delete, and logs the others.
 * LINUXFS_FSTAB names another fstab, and LINUXFS_TEST_DISKS (colon-separated files) the attached disks (tests), obeyed only
 * when not root.
 */
#include "fsrules.h"
#include "fstab.h"
#include "plist.h"
#include "probe.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dirent.h>
#include <errno.h>
#include <strings.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#define DEFAULT_SOCKET "/var/run/dev.mavergreen.linuxfs.helper.sock"

/* "/dev/rdiskN" or "/dev/rdiskNsM", nothing else. */
int helper_device_ok(const char *path)
{
	const char *p = path;
	int part = 0, digits = 0;

	if (strncmp(p, "/dev/rdisk", 10) != 0)
		return 0;
	for (p += 10; *p; p++) {
		if (*p >= '0' && *p <= '9') {
			digits++;
		} else if (*p == 's' && digits && !part) {
			part = 1;
			digits = 0;
		} else {
			return 0;
		}
	}
	return digits > 0;
}

int helper_peer_ok(uid_t peer, uid_t console)
{
	return peer == 0 || peer == console;
}

/* The Mac's mount point of /dev/diskNsM (the block node of a raw path), if it has one. */
int helper_mac_mounted(const char *raw, char *where, size_t wherelen)
{
	struct statfs *m;
	char blk[64];
	int i, n;

	if (snprintf(blk, sizeof(blk), "/dev/%s", raw + 6) >= (int)sizeof(blk))
		return 0;
	n = getmntinfo(&m, MNT_NOWAIT);
	for (i = 0; i < n; i++) {
		if (strcmp(m[i].f_mntfromname, blk) == 0) {
			snprintf(where, wherelen, "%s", m[i].f_mntonname);
			return 1;
		}
	}
	return 0;
}

struct media_facts {
	char content[128];	/* the partition type: a GPT GUID, "0x83", "GUID_partition_scheme", ... */
	int leaf;		/* no partitions under it */
	int ejectable;		/* removable or ejectable media: a stick, a card, a USB disk, a disk image */
};

/* What IOKit says of a BSD name (diskNsM, no /dev/r). 0, or -1 when IOKit knows no such medium. */
int helper_media_facts(const char *bsd, struct media_facts *f)
{
	io_service_t m = IOServiceGetMatchingService(kIOMasterPortDefault, IOBSDNameMatching(kIOMasterPortDefault, 0, bsd));
	CFTypeRef v;

	if (!m)
		return -1;
	memset(f, 0, sizeof(*f));
	v = IORegistryEntryCreateCFProperty(m, CFSTR("Content"), NULL, 0);
	if (v && CFGetTypeID(v) == CFStringGetTypeID())
		CFStringGetCString(v, f->content, sizeof(f->content), kCFStringEncodingUTF8);
	if (v)
		CFRelease(v);
#define FLAG(key, field) \
	v = IORegistryEntryCreateCFProperty(m, CFSTR(key), NULL, 0); \
	if (v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(v)) \
		f->field = 1; \
	if (v) \
		CFRelease(v);
	FLAG("Leaf", leaf)
	FLAG("Ejectable", ejectable)
	FLAG("Removable", ejectable)
#undef FLAG
	IOObjectRelease(m);
	return 0;
}

/*
 * Why a partition must not be handed out, from what it is rather than what its bytes say; NULL when it may.
 * Never a disk with partitions under it (its partitions may be mounted), never a system partition (EFI, Apple,
 * Microsoft), and FAT, exFAT or NTFS only on ejectable media: internal ones are the Mac's or Windows's own.
 * APFS (which 10.9 cannot read): an APFS-typed partition must hold APFS; read-write (the user's APFSWrite) only on
 * ejectable media, never an internal one, which a newer macOS on this Mac may own. FSTYPE is NULL before the probe.
 */
const char *helper_media_refusal(const char *content, int leaf, int ejectable, const char *fstype, int rw)
{
	static const char apfs_type[] = "7C3457EF-0000-11AA-AA11-00306543ECAC";

	static const char *system[] = {
		"C12A7328-F81F-11D2-BA4B-00A0C93EC93B",	/* EFI System */
		"0xEF",					/* MBR EFI */
		"48465300-0000-11AA-AA11-00306543ECAC",	/* Apple HFS+ */
		"7C3457EF-0000-11AA-AA11-00306543ECAC",	/* Apple APFS */
		"53746F72-6167-11AA-AA11-00306543ECAC",	/* Apple CoreStorage */
		"426F6F74-0000-11AA-AA11-00306543ECAC",	/* Apple Boot */
		"52414944-0000-11AA-AA11-00306543ECAC",	/* Apple RAID */
		"E3C9E316-0B5C-4DB8-817D-F92DF00215AE",	/* Microsoft Reserved */
		"DE94BBA4-06D1-4D40-A16A-BFD50179D6AC",	/* Windows Recovery */
		"Apple_HFS", "Apple_Boot", "Apple_partition_map", "Apple_Driver43", "Apple_Free", "EFI",
		NULL
	};

	if (!leaf)
		return "a disk with partitions under it; open one of its partitions";
	if (rw && !ejectable && (strcasecmp(content, apfs_type) == 0 || (fstype && strcmp(fstype, "apfs") == 0)))
		return "an internal APFS volume is served read-only";
	if (strcasecmp(content, apfs_type) == 0) {
		if (fstype && strcmp(fstype, "apfs") != 0)
			return "an APFS partition that does not hold APFS";
		return NULL;
	}
	for (int i = 0; system[i]; i++)
		if (strcasecmp(content, system[i]) == 0)
			return "a system partition (EFI, Apple or Windows)";
	if (fstype && !ejectable && (strcmp(fstype, "vfat") == 0 || strcmp(fstype, "exfat") == 0 || strcmp(fstype, "ntfs3") == 0))
		return "an internal FAT, exFAT or NTFS partition belongs to the Mac or Windows";
	return NULL;
}

/* The fstab to edit: /etc/fstab, or LINUXFS_FSTAB when not root (tests). */
const char *helper_fstab_path(void)
{
	const char *t = getuid() != 0 ? getenv("LINUXFS_FSTAB") : NULL;

	return t && *t ? t : "/etc/fstab";
}

static char why_buf[512];

static const char *why_errno(const char *what)
{
	snprintf(why_buf, sizeof(why_buf), "%s: %s", what, strerror(errno));
	return why_buf;
}

/*
 * Adds SPEC's linuxfs noauto entry for BUNDLE to the fstab at PATH, or removes it (BUNDLE NULL), or every linuxfs entry
 * (SPEC and BUNDLE NULL). NULL when done (or there
 * was nothing to do), else why not. PATH must be a regular file owned by root (by the caller, when not root: tests) of at
 * most FSTAB_MAX bytes, or absent; it is read whole, edited in memory (fstab.c: every other line kept byte for byte) and
 * replaced by a new file made beside it (O_EXCL, O_NOFOLLOW, mode 0644, root:wheel), synced, then renamed over it, so a
 * reader sees the old or the new, never part. Edits are one at a time: each holds a lock on the directory.
 */
const char *helper_noauto(const char *path, const char *spec, const char *bundle)
{
	static char in[FSTAB_MAX + 2], out[FSTAB_MAX + 1];
	char dir[1024], tmp[1100], *slash;
	const char *why = NULL;
	struct stat st;
	size_t len = 0, w;
	long n;
	ssize_t r;
	int dfd, fd, tfd = -1, changed, retried = 0;

	if (!spec && bundle)
		return "a bundle needs a volume";
	if ((spec && (why = fstab_spec_refusal(spec))) || (bundle && (why = fstab_bundle_refusal(bundle))))
		return why;
	if (snprintf(dir, sizeof(dir), "%s", path) >= (int)sizeof(dir) || snprintf(tmp, sizeof(tmp), "%s.linuxfs-new", path) >= (int)sizeof(tmp))
		return "the fstab's path is too long";
	if (!(slash = strrchr(dir, '/')))
		return "the fstab's path is not absolute";
	slash[slash == dir ? 1 : 0] = '\0';
	/* /etc is a symlink to /private/etc on the Mac, root's own: followed; the fstab itself never is */
	dfd = open(dir, O_RDONLY | O_NOCTTY);
	if (dfd < 0)
		return why_errno("cannot open the fstab's directory");
	if (fstat(dfd, &st) != 0 || !S_ISDIR(st.st_mode)) {
		close(dfd);
		return "the fstab's directory is not a directory";
	}
	if (flock(dfd, LOCK_EX) != 0) {
		why = why_errno("cannot lock the fstab's directory");
		goto done;
	}
	fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
	if (fd < 0 && errno != ENOENT) {
		why = errno == ELOOP ? "the fstab is a symlink" : why_errno("cannot open the fstab");
		goto done;
	}
	if (fd >= 0) {
		if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))
			why = "the fstab is not a regular file";
		else if (st.st_uid != getuid())
			why = getuid() == 0 ? "the fstab is not owned by root" : "the fstab is not owned by the caller";
		else if (st.st_size > FSTAB_MAX)
			why = "the fstab is over 64 KiB";
		while (!why && len <= FSTAB_MAX) {
			r = read(fd, in + len, sizeof(in) - len);
			if (r < 0 && errno == EINTR)
				continue;
			if (r < 0)
				why = why_errno("cannot read the fstab");
			if (r <= 0)
				break;
			len += (size_t)r;
		}
		if (!why && len > FSTAB_MAX)
			why = "the fstab is over 64 KiB";
		close(fd);
		if (why)
			goto done;
	}
	n = fstab_edit(in, len, spec, bundle, out, sizeof(out), &changed);
	if (n < 0) {
		why = "the fstab would be over 64 KiB";
		goto done;
	}
	if (!changed)
		goto done;
	while ((tfd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NOCTTY, 0644)) < 0 && errno == EEXIST && !retried++)
		unlink(tmp);	/* a crash's leftover: the lock is held, so no other edit's */
	if (tfd < 0) {
		why = why_errno("cannot make the new fstab");
		goto done;
	}
	for (w = 0; w < (size_t)n && !why; ) {
		r = write(tfd, out + w, (size_t)n - w);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			why = why_errno("cannot write the new fstab");
		else
			w += (size_t)r;
	}
	if (!why && (fchmod(tfd, 0644) != 0 || (getuid() == 0 && fchown(tfd, 0, 0) != 0)))
		why = why_errno("cannot set the new fstab's owner and mode");
	if (!why && fsync(tfd) != 0)
		why = why_errno("cannot sync the new fstab");
	if (close(tfd) != 0 && !why)
		why = why_errno("cannot write the new fstab");
	if (!why && rename(tmp, path) != 0)
		why = why_errno("cannot replace the fstab");
	if (why)
		unlink(tmp);
	else
		fsync(dfd);
done:
	close(dfd);	/* and the lock with it */
	return why;
}

/* ---- --migrate-prefs: Ignore:<LABEL> preferences become fstab entries ---- */

#define MIGRATE_DISKS 64

/* an attached disk a bundle would mount: its type, the volume name DiskArbitration gives it (the util's -p; empty when that
 * is only the Linux every unnamed volume gets), and its UUID (the util's -k; empty when none) */
struct seen_disk { const char *type; char vol[256]; char uuid[40]; };

/* PATH's disk, through the same checks as a probe request (helper_media_refusal before and after the probe), when one of
 * linuxfs's bundles would mount it; 0, or -1. A path that is not a raw disk node is a test's stand-in (no IOKit facts). */
static int see_disk(const char *path, struct seen_disk *d)
{
	struct media_facts facts = { "", 1, 1 };
	char label[512];
	const char *type;
	int fd, err, raw = helper_device_ok(path);

	if (raw && (helper_media_facts(path + 6, &facts) < 0 || helper_media_refusal(facts.content, facts.leaf, facts.ejectable, NULL, 0)))
		return -1;
	fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	type = linuxfs_probe_fd(fd, label, sizeof(label), &err);
	if (!type || !fstab_bundle_for(type) || helper_media_refusal(facts.content, facts.leaf, facts.ejectable, type, 0)) {
		close(fd);
		return -1;
	}
	d->type = type;	/* probe.c's names are literals */
	fsrules_volname(label, d->vol, sizeof(d->vol));
	if (strcmp(d->vol, "Linux") == 0 && strcmp(label, "Linux") != 0)
		d->vol[0] = '\0';
	if (linuxfs_probe_uuid(d->uuid, sizeof(d->uuid)) != 0)
		d->uuid[0] = '\0';
	close(fd);
	return 0;
}

/* The attached disks linuxfs's bundles would mount: /dev's raw disk nodes, or (tests, only when not root) the files named
 * in LINUXFS_TEST_DISKS, colon-separated. */
static int scan_disks(struct seen_disk *d, int max)
{
	const char *test = getuid() != 0 ? getenv("LINUXFS_TEST_DISKS") : NULL;
	char path[1024];
	int n = 0;

	if (test) {
		while (*test && n < max) {
			size_t len = strcspn(test, ":");

			if (len < sizeof(path)) {
				memcpy(path, test, len);
				path[len] = '\0';
				if (len && see_disk(path, &d[n]) == 0)
					n++;
			}
			test += len + (test[len] == ':');
		}
		return n;
	}
	DIR *dev = opendir("/dev");
	struct dirent *e;

	while (dev && n < max && (e = readdir(dev))) {
		if (snprintf(path, sizeof(path), "/dev/%s", e->d_name) >= (int)sizeof(path) || !helper_device_ok(path))
			continue;
		if (see_disk(path, &d[n]) == 0)
			n++;
	}
	if (dev)
		closedir(dev);
	return n;
}

/* NULL when an attached disk is SPEC's volume (UUID=, or LABEL= its volume name) of BUNDLE's type; else why not. A console
 * user may keep only a volume attached now from mounting by itself, never name any volume at all. */
const char *helper_noauto_attached(const char *spec, const char *bundle)
{
	static struct seen_disk disks[MIGRATE_DISKS];
	int i, n = scan_disks(disks, MIGRATE_DISKS);

	for (i = 0; i < n; i++) {
		if (strcmp(fstab_bundle_for(disks[i].type), bundle) != 0)
			continue;
		if (strncmp(spec, "UUID=", 5) == 0 ? (disks[i].uuid[0] && strcasecmp(disks[i].uuid, spec + 5) == 0)
						   : (strncmp(spec, "LABEL=", 6) == 0 && disks[i].vol[0] && strcmp(disks[i].vol, spec + 6) == 0))
			return NULL;
	}
	return "no attached linuxfs volume matches";
}

/* One Ignore:<RAW> = true from DOM: converted (printed to OUT) or logged. */
static void migrate_one(FILE *out, const char *dom, const char *raw, struct seen_disk *disks, int *ndisks)
{
	char name[256], spec[300];
	const char *why, *bundle = NULL;
	int i, len = (int)strcspn(raw, "\n");

	if (raw[len]) {
		fprintf(stderr, "linuxfs-helper: Ignore:%.*s... (%s) left as it is: a label with a newline cannot be written to /etc/fstab\n", len, raw, dom);
		return;
	}
	fsrules_volname(raw, name, sizeof(name));
	if (strcmp(name, "Linux") == 0 && strcmp(raw, "Linux") != 0) {
		fprintf(stderr, "linuxfs-helper: Ignore:%s (%s) left as it is: no volume is given that name\n", raw, dom);
		return;
	}
	snprintf(spec, sizeof(spec), "LABEL=%s", name);
	if ((why = fstab_spec_refusal(spec))) {
		fprintf(stderr, "linuxfs-helper: Ignore:%s (%s) left as it is: %s\n", raw, dom, why);
		return;
	}
	if (*ndisks < 0)
		*ndisks = scan_disks(disks, MIGRATE_DISKS);
	for (i = 0; i < *ndisks && !bundle; i++)
		if (strcmp(disks[i].vol, name) == 0)
			bundle = fstab_bundle_for(disks[i].type);
	if (!bundle) {
		fprintf(stderr, "linuxfs-helper: Ignore:%s (%s) left as it is: no disk named %s is attached to give its filesystem; "
			"attach it and run linuxfs ignore /dev/diskNsM\n", raw, dom, name);
		return;
	}
	if ((why = helper_noauto(helper_fstab_path(), spec, bundle))) {
		fprintf(stderr, "linuxfs-helper: Ignore:%s (%s) left as it is: %s\n", raw, dom, why);
		return;
	}
	fprintf(out, "%s\t%s\n", dom, raw);
}

/* Converts each Ignore:<LABEL> = true of the console user's and the machine's preferences (plist.c reads them as root
 * safely); 0. */
int helper_migrate(FILE *out)
{
	static struct seen_disk disks[MIGRATE_DISKS];
	static const char *const dom[2] = { "user", "machine" };
	CFDictionaryRef d[2];
	int ndisks = -1, j;

	prefs_load(&d[0], &d[1]);
	for (j = 0; j < 2; j++) {
		CFIndex count, i;
		const void **keys;

		if (!d[j])
			continue;
		count = CFDictionaryGetCount(d[j]);
		keys = calloc((size_t)count + 1, sizeof(*keys));
		if (keys) {
			CFDictionaryGetKeysAndValues(d[j], keys, NULL);
			for (i = 0; i < count; i++) {
				char key[1100];

				if (CFGetTypeID(keys[i]) != CFStringGetTypeID() || pref_bool(d[j], keys[i]) != 1 ||
				    !CFStringHasPrefix(keys[i], CFSTR("Ignore:")))
					continue;
				if (!CFStringGetCString(keys[i], key, sizeof(key), kCFStringEncodingUTF8)) {
					fprintf(stderr, "linuxfs-helper: an Ignore: preference (%s) left as it is: its label is too long\n", dom[j]);
					continue;
				}
				migrate_one(out, dom[j], key + 7, disks, &ndisks);
			}
			free(keys);
		}
		CFRelease(d[j]);
	}
	return 0;
}

#ifndef LINUXFS_HELPER_NO_MAIN
static uid_t console_uid(void)
{
	struct stat st;

	return stat("/dev/console", &st) == 0 ? st.st_uid : (uid_t)-1;
}
#endif

static void reply(int c, const char *msg, int fd)
{
	struct msghdr mh = { 0 };
	struct iovec iov = { (void *)msg, strlen(msg) };
	union {
		struct cmsghdr h;
		char buf[64];	/* platform: the 10.9 SDK's CMSG_SPACE is not a constant expression; one int needs far less */
	} ctl;

	mh.msg_iov = &iov;
	mh.msg_iovlen = 1;
	if (fd >= 0) {
		memset(&ctl, 0, sizeof(ctl));
		mh.msg_control = ctl.buf;
		mh.msg_controllen = CMSG_SPACE(sizeof(int));
		CMSG_FIRSTHDR(&mh)->cmsg_level = SOL_SOCKET;
		CMSG_FIRSTHDR(&mh)->cmsg_type = SCM_RIGHTS;
		CMSG_FIRSTHDR(&mh)->cmsg_len = CMSG_LEN(sizeof(int));
		memcpy(CMSG_DATA(CMSG_FIRSTHDR(&mh)), &fd, sizeof(int));
	}
	sendmsg(c, &mh, 0);
}

/* Handles one request; returns nothing, always replies. */
void helper_serve(int c, uid_t peer, uid_t console, int test_files)
{
	char req[2048], dev[128], mode[8], where[1024], label[512], msg[1024], uuid[40] = "", *nl;
	const char *type, *why;
	struct media_facts facts = { "", 1, 1 };
	ssize_t n;
	size_t got = 0;
	int fd, err, rw = 0, items, want_uuid = 0;

	/* the peer first, so nobody else can hold the helper up with a request that never comes */
	if (!helper_peer_ok(peer, console)) {
		reply(c, "no only the user at the console may open disks\n", -1);
		return;
	}
	/* one line, read until its newline (the socket's receive timeout bounds a client that dawdles) */
	while (got < sizeof(req) - 1 && !memchr(req, '\n', got)) {
		n = read(c, req + got, sizeof(req) - 1 - got);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		got += (size_t)n;
	}
	if (got == 0)
		return;
	req[got] = '\0';
	nl = memchr(req, '\n', got);
	if (memchr(req, '\0', got) || (nl && nl + 1 < req + got)) {
		reply(c, "no a request is one line\n", -1);
		return;
	}
	if (nl)
		*nl = '\0';
	if (strcmp(req, "noauto-remove-all") == 0) {
		why = helper_noauto(helper_fstab_path(), NULL, NULL);
		if (why)
			snprintf(msg, sizeof(msg), "no %s\n", why);
		reply(c, why ? msg : "ok\n", -1);
		return;
	}
	if (strncmp(req, "noauto-add ", 11) == 0 || strncmp(req, "noauto-remove ", 14) == 0) {
		char *spec = req + (req[7] == 'a' ? 11 : 14), *bundle = NULL;

		if (req[7] == 'a') {
			bundle = strrchr(spec, ' ');
			if (!bundle) {
				reply(c, "no request is noauto-add SPEC BUNDLE\n", -1);
				return;
			}
			*bundle++ = '\0';
		}
		why = bundle && !fstab_spec_refusal(spec) && !fstab_bundle_refusal(bundle) ? helper_noauto_attached(spec, bundle) : NULL;
		if (!why)
			why = helper_noauto(helper_fstab_path(), spec, bundle);
		if (why)
			snprintf(msg, sizeof(msg), "no %s\n", why);
		reply(c, why ? msg : "ok\n", -1);
		return;
	}
	mode[0] = '\0';
	items = sscanf(req, "open %127s %7s", dev, mode);
	if (items == 2 && (strcmp(mode, "rw") == 0 || strcmp(mode, "ro") == 0)) {
		rw = strcmp(mode, "rw") == 0;
	} else if (sscanf(req, "probe %127s", dev) == 1 && strncmp(req, "probe ", 6) == 0) {
		mode[0] = '\0';
	} else if (sscanf(req, "uuid %127s", dev) == 1 && strncmp(req, "uuid ", 5) == 0) {
		mode[0] = '\0';
		want_uuid = 1;
	} else {
		reply(c, "no request is open DEVICE rw|ro, probe DEVICE, uuid DEVICE, noauto-add SPEC BUNDLE, noauto-remove SPEC or noauto-remove-all\n", -1);
		return;
	}
	if (!helper_device_ok(dev) && !test_files) {
		reply(c, "no not a raw disk node (/dev/rdiskN or /dev/rdiskNsM)\n", -1);
		return;
	}
	if (helper_device_ok(dev) && helper_mac_mounted(dev, where, sizeof(where))) {
		snprintf(msg, sizeof(msg), "no mounted by the Mac at %s\n", where);
		reply(c, msg, -1);
		return;
	}
	if (helper_device_ok(dev)) {
		if (helper_media_facts(dev + 6, &facts) < 0) {
			reply(c, "no no such disk\n", -1);
			return;
		}
		if ((why = helper_media_refusal(facts.content, facts.leaf, facts.ejectable, NULL, rw))) {
			snprintf(msg, sizeof(msg), "no %s\n", why);
			reply(c, msg, -1);
			return;
		}
	}
	fd = open(dev, (rw ? O_RDWR : O_RDONLY) | O_CLOEXEC);
	if (fd < 0) {
		snprintf(msg, sizeof(msg), "no %s: %s\n", dev, strerror(errno));
		reply(c, msg, -1);
		return;
	}
	type = linuxfs_probe_fd(fd, label, sizeof(label), &err);
	if (!type) {
		snprintf(msg, sizeof(msg), "no %s\n", err ? strerror(err) : "no filesystem linuxfs knows");
		reply(c, msg, -1);
		close(fd);
		return;
	}
	if ((why = helper_media_refusal(facts.content, facts.leaf, facts.ejectable, type, rw))) {
		snprintf(msg, sizeof(msg), "no %s\n", why);
		reply(c, msg, -1);
		close(fd);
		return;
	}
	if (want_uuid) {
		if (linuxfs_probe_uuid(uuid, sizeof(uuid)) == 0)
			snprintf(msg, sizeof(msg), "ok %s\n", uuid);
		reply(c, uuid[0] ? msg : "no this filesystem has no UUID\n", -1);
		close(fd);
		return;
	}
	snprintf(msg, sizeof(msg), "ok %s\t%s%s%s\n", type, label, *linuxfs_probe_extra() ? "\t" : "", linuxfs_probe_extra());
	reply(c, msg, mode[0] ? fd : -1);
	close(fd);
}

#ifndef LINUXFS_HELPER_NO_MAIN
int main(int argc, char **argv)
{
	const char *path = DEFAULT_SOCKET;
	struct sockaddr_un sa = { 0 };
	int s, c, test_files = 0, timeout = 15;
	uid_t peer;
	gid_t gid;

	if (argc == 2 && strcmp(argv[1], "--migrate-prefs") == 0) {
		setvbuf(stdout, NULL, _IOLBF, 0);
		signal(SIGALRM, SIG_DFL);
		alarm(120);	/* a disk that never answers its probe must not hold up the install */
		return helper_migrate(stdout);
	}
	if (argc == 2 && strcmp(argv[1], "--noauto-remove-all") == 0) {
		const char *why = helper_noauto(helper_fstab_path(), NULL, NULL);

		if (why)
			fprintf(stderr, "linuxfs-helper: %s\n", why);
		return why ? 1 : 0;
	}
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc)
			path = argv[++i];
		else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc && atoi(argv[i + 1]) > 0)
			timeout = atoi(argv[++i]);
		else if (strcmp(argv[i], "--test-files") == 0)
			test_files = 1;	/* tests only: regular files stand in for disks, the caller for the console */
		else {
			fprintf(stderr, "usage: linuxfs-helper [--socket PATH] [--timeout SECONDS]\n       linuxfs-helper --migrate-prefs\n       linuxfs-helper --noauto-remove-all\n");
			return 2;
		}
	}
	signal(SIGPIPE, SIG_IGN);
	signal(SIGCHLD, SIG_IGN);	/* children are reaped by the kernel */
	s = socket(AF_UNIX, SOCK_STREAM, 0);
	sa.sun_family = AF_UNIX;
	if (s < 0 || strlen(path) >= sizeof(sa.sun_path)) {
		perror("linuxfs-helper: socket");
		return 1;
	}
	strcpy(sa.sun_path, path);
	unlink(path);
	if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) < 0 || chmod(path, 0666) < 0 || listen(s, 8) < 0) {
		perror(path);
		return 1;
	}
	for (;;) {
		c = accept(s, NULL, NULL);
		if (c < 0) {
			if (errno == EINTR || errno == ECONNABORTED || errno == EMFILE || errno == ENFILE) {
				if (errno != EINTR && errno != ECONNABORTED)
					sleep(1);
				continue;
			}
			perror("linuxfs-helper: accept");
			return 1;
		}
		/* review M2: each request in a child, which a disk that never answers cannot keep past TIMEOUT,
		 * so one bad disk holds up nobody else */
		switch (fork()) {
		case 0:
			close(s);
			signal(SIGALRM, SIG_DFL);
			alarm(timeout);
			setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &(struct timeval){ 2, 0 }, sizeof(struct timeval));
			if (getpeereid(c, &peer, &gid) == 0)
				helper_serve(c, peer, test_files ? getuid() : console_uid(), test_files);
			_exit(0);
		case -1:
			perror("linuxfs-helper: fork");
			sleep(1);
			break;
		}
		close(c);
	}
}
#endif
