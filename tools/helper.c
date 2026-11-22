/*
 * linuxfs-helper: the one root part of linuxfs. Opens a disk partition that holds a Linux filesystem, for the
 * user at the console, and hands them the descriptor; lklfuse then runs as that user.
 * usage: linuxfs-helper [--socket PATH] [--timeout SECONDS]       (run by launchd as dev.mavergreen.linuxfs.helper)
 * Protocol, one request per connection, one line each way:
 *   "open /dev/rdiskNsM rw|ro"  ->  "ok TYPE<TAB>LABEL" plus the descriptor (SCM_RIGHTS), or "no REASON"
 *   "probe /dev/rdiskNsM"       ->  "ok TYPE<TAB>LABEL", or "no REASON"
 * It refuses a peer other than root or the console user (before reading its request), a path other than a raw
 * disk node, a partition the Mac has mounted, a disk with partitions under it, a system partition by type (EFI,
 * Apple, Windows, from IOKit), FAT, exFAT or NTFS on internal media, and any partition whose superblock is not a
 * filesystem linuxfs knows.
 */
#include "probe.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <strings.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
	char req[256], dev[128], mode[8], where[1024], label[512], msg[1024];
	const char *type, *why;
	struct media_facts facts = { "", 1, 1 };
	ssize_t n;
	int fd, err, rw = 0, items;

	/* the peer first, so nobody else can hold the helper up with a request that never comes */
	if (!helper_peer_ok(peer, console)) {
		reply(c, "no only the user at the console may open disks\n", -1);
		return;
	}
	n = read(c, req, sizeof(req) - 1);
	if (n <= 0)
		return;
	req[n] = '\0';
	req[strcspn(req, "\n")] = '\0';
	mode[0] = '\0';
	items = sscanf(req, "open %127s %7s", dev, mode);
	if (items == 2 && (strcmp(mode, "rw") == 0 || strcmp(mode, "ro") == 0)) {
		rw = strcmp(mode, "rw") == 0;
	} else if (sscanf(req, "probe %127s", dev) == 1 && strncmp(req, "probe ", 6) == 0) {
		mode[0] = '\0';
	} else {
		reply(c, "no request is open DEVICE rw|ro or probe DEVICE\n", -1);
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

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc)
			path = argv[++i];
		else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc && atoi(argv[i + 1]) > 0)
			timeout = atoi(argv[++i]);
		else if (strcmp(argv[i], "--test-files") == 0)
			test_files = 1;	/* tests only: regular files stand in for disks, the caller for the console */
		else {
			fprintf(stderr, "usage: linuxfs-helper [--socket PATH]\n");
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
