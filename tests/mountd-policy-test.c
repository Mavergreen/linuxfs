/*
 * The root mount daemon's judging functions, called directly (tools/mountd.c): the request line, the peer, whose disk it is
 * and the rest of the verdict, the mount point's facts before and after adoption, the status and the reply line.
 * usage: mountd-policy-test
 */
#include "../tools/mountd.h"
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static int tapno, failures;

static void is(long got, long want, const char *what)
{
	tapno++;
	printf("%sok %d - %s", got == want ? "" : "not ", tapno, what);
	if (got != want) {
		printf(" (got %ld, want %ld)", got, want);
		failures++;
	}
	printf("\n");
}

static void iss(const char *got, const char *want, const char *what)
{
	int ok = got && want && strcmp(got, want) == 0;

	tapno++;
	printf("%sok %d - %s\n", ok ? "" : "not ", tapno, what);
	if (!ok) {
		printf("# got '%s', want '%s'\n", got ? got : "(null)", want ? want : "(null)");
		failures++;
	}
}

/* WHY begins with WANT */
static void starts(const char *why, const char *want, const char *what)
{
	int ok = why && strncmp(why, want, strlen(want)) == 0;

	tapno++;
	printf("%sok %d - %s\n", ok ? "" : "not ", tapno, what);
	if (!ok) {
		printf("# got '%s', want '%s...'\n", why ? why : "(null)", want);
		failures++;
	}
}

static struct mountd_req req;

/* mountd_parse of a C string (its length without the NUL) */
static int parse(const char *s)
{
	const char *why = NULL;

	memset(&req, 0x55, sizeof(req));
	return mountd_parse(s, strlen(s), &req, &why);
}

static void refuses(const char *s, const char *what)
{
	const char *why = NULL;
	int r = mountd_parse(s, strlen(s), &req, &why);

	is(r, -1, what);
	if (r == -1 && !why) {
		printf("# no reason given\n");
		failures++;
	}
}

#define LINUX_GUID "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
#define EFI_GUID "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
#define APFS_GUID "7C3457EF-0000-11AA-AA11-00306543ECAC"

/* a physical, ejectable, removable, unmounted leaf of kind macfuse_<fs>, whose node is root's */
static struct mountd_disk disk(const char *fs)
{
	struct mountd_disk d;

	memset(&d, 0, sizeof(d));
	snprintf(d.bsd, sizeof(d.bsd), "disk3s1");
	snprintf(d.kind, sizeof(d.kind), "macfuse_%s", fs);
	snprintf(d.content, sizeof(d.content), "%s", strcmp(fs, "apfs") == 0 ? APFS_GUID : LINUX_GUID);
	d.leaf = d.ejectable = d.removable = 1;
	return d;
}

static struct mountd_req request(const char *fs, const char *flags)
{
	char line[256];
	const char *why;
	struct mountd_req r;

	snprintf(line, sizeof(line), "mount\t%s\tdisk3s1\t%s\t/Volumes/x\n", fs, flags);
	if (mountd_parse(line, strlen(line), &r, &why) != 0) {
		printf("# cannot build the request %s %s: %s\n", fs, flags, why);
		failures++;
	}
	return r;
}

static int rc;
static const char *why;

static enum mountd_verdict judge(const struct mountd_req *r, const struct mountd_disk *d, uid_t peer, const char *type, unsigned flags,
				 const struct fsprefs *p, int mb, int mm)
{
	rc = -99;
	why = NULL;
	return mountd_judge(r, d, peer, type, flags, p, mb, mm, &rc, &why);
}

static struct stat dir(dev_t dev, ino_t ino, uid_t uid, mode_t mode)
{
	struct stat st;

	memset(&st, 0, sizeof(st));
	st.st_dev = dev;
	st.st_ino = ino;
	st.st_uid = uid;
	st.st_mode = mode;
	return st;
}

int main(void)
{
	struct fsprefs p, take;
	struct mountd_req r;
	struct mountd_disk d;
	char buf[256], big[1100];
	size_t n;

	fsrules_default_prefs(&p);
	take = p;
	take.ntfs_takeover = 1;

	/* ---- the request (spec: item 5 amendment, §1 "The request") ---- */
	is(parse("mount\text4\tdisk3s1\t-\t/Volumes/my data\n"), 0, "parse_ok: a request is accepted");
	iss(req.fs, "ext4", "parse_ok: FS");
	iss(req.bsd, "disk3s1", "parse_ok: BSD");
	is(req.ro, 0, "parse_ok: not ro");
	is(req.owners, 0, "parse_ok: not owners");
	iss(req.mnt, "/Volumes/my data", "parse_ok: MNT, with its space");
	is(parse("mount\text4\tdisk3\tro,owners\t/Volumes/x\n") == 0 && req.ro == 1 && req.owners == 1, 1, "parse_flags: ro,owners is 1 1");
	is(parse("mount\text4\tdisk3\towners\t/Volumes/x\n") == 0 && req.ro == 0 && req.owners == 1, 1, "parse_flags: owners is 0 1");
	is(parse("mount\text4\tdisk3\towners,ro\t/Volumes/x\n") == 0 && req.ro == 1 && req.owners == 1, 1, "parse_flags: owners,ro is 1 1");
	is(parse("mount\text4\tdisk3\tro\t/Volumes/x\n") == 0 && req.ro == 1 && req.owners == 0, 1, "parse_flags: ro is 1 0");
	{
		const char two[] = "mount\text4\tdisk3s1\t-\t/Volumes/x\nmount\text4\tdisk3s1\t-\t/Volumes/y\n";
		const char nul[] = "mount\text4\tdisk3s1\t-\t/Volumes/x\0y\n";

		refuses(two, "parse_refuses: two lines");
		is(mountd_parse(nul, sizeof(nul) - 1, &req, &why), -1, "parse_refuses: a NUL");
		memset(big, 'a', sizeof(big));
		memcpy(big, "mount\text4\tdisk3s1\t-\t/Volumes/", 30);
		big[1024] = '\n';
		is(mountd_parse(big, 1025, &req, &why), -1, "parse_refuses: 1025 bytes");
		big[1023] = '\n';
		is(mountd_parse(big, 1024, &req, &why), -1, "parse_refuses: 1024 bytes, whose name is over 255 bytes");
	}
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/x", "parse_refuses: no trailing LF");
	refuses("mount\text4\tdisk3s1\t/Volumes/x\n", "parse_refuses: four fields");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/x\textra\n", "parse_refuses: six fields");
	refuses("mount\tmacfuse_ext4\tdisk3s1\t-\t/Volumes/x\n", "parse_refuses: FS macfuse_ext4");
	refuses("mount\thfs\tdisk3s1\t-\t/Volumes/x\n", "parse_refuses: FS hfs");
	refuses("mount\tvfat\tdisk3s1\t-\t/Volumes/x\n", "parse_refuses: FS vfat");
	refuses("mount\tntfs3\tdisk3s1\t-\t/Volumes/x\n", "parse_refuses: FS ntfs3");
	refuses("mount\t\tdisk3s1\t-\t/Volumes/x\n", "parse_refuses: an empty FS");
	refuses("mount\text4\tdisk3s\t-\t/Volumes/x\n", "parse_refuses: BSD disk3s");
	refuses("mount\text4\trdisk3s1\t-\t/Volumes/x\n", "parse_refuses: BSD rdisk3s1");
	refuses("mount\text4\t/dev/disk3s1\t-\t/Volumes/x\n", "parse_refuses: BSD /dev/disk3s1");
	refuses("mount\text4\tdisk3s1;x\t-\t/Volumes/x\n", "parse_refuses: BSD disk3s1;x");
	refuses("mount\text4\tdisk3s1\trw\t/Volumes/x\n", "parse_refuses: FLAGS rw");
	refuses("mount\text4\tdisk3s1\tro,ro,x\t/Volumes/x\n", "parse_refuses: FLAGS ro,ro,x");
	refuses("mount\text4\tdisk3s1\tro,ro\t/Volumes/x\n", "parse_refuses: FLAGS ro,ro");
	refuses("mount\text4\tdisk3s1\t\t/Volumes/x\n", "parse_refuses: empty FLAGS");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes\n", "parse_refuses: MNT /Volumes");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/\n", "parse_refuses: MNT /Volumes/");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/a/b\n", "parse_refuses: MNT /Volumes/a/b");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/.\n", "parse_refuses: MNT /Volumes/.");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/..\n", "parse_refuses: MNT /Volumes/..");
	refuses("mount\text4\tdisk3s1\t-\t/private/tmp/x\n", "parse_refuses: MNT /private/tmp/x");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/a\001b\n", "parse_refuses: MNT with a control character");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/a\177b\n", "parse_refuses: MNT with DEL");
	refuses("mount\text4\tdisk3s1\t-\t/Volumes/a\rb\n", "parse_refuses: MNT with a CR");
	refuses("umount\text4\tdisk3s1\t-\t/Volumes/x\n", "parse_refuses: a verb other than mount");
	refuses("mountx\text4\tdisk3s1\t-\t/Volumes/x\n", "parse_refuses: a verb that only begins with mount");
	is(parse("mount\text4\tdisk3s1\t-\t/Volumes/caf\xc3\xa9\n"), 0, "parse: a UTF-8 name is accepted");
	is(parse("mount\text4\tdisk3s1\t-\t/Volumes/...\n"), 0, "parse: ... is a name, not . or ..");
	{
		char line[400];

		snprintf(line, sizeof(line), "mount\text4\tdisk3s1\t-\t/Volumes/%0255d\n", 0);
		is(parse(line), 0, "parse: a name of 255 bytes is accepted");
		snprintf(line, sizeof(line), "mount\text4\tdisk3s1\t-\t/Volumes/%0256d\n", 0);
		refuses(line, "parse_refuses: a name of 256 bytes (over NAME_MAX, m1)");
	}

	/* ---- the peer ---- */
	is(mountd_peer(501, 501), MP_SERVE, "peer: the console user is served");
	is(mountd_peer(0, 0), MP_ROOT, "peer: root, at a console nobody holds");
	is(mountd_peer(0, 501), MP_ROOT, "peer: root, with a user at the console");
	is(mountd_peer(502, 501), MP_USER, "peer: another user mounts as itself");
	is(mountd_peer(501, (uid_t)-1), MP_USER, "peer: no console owner known");

	/* ---- the verdict ---- */
	r = request("ext4", "-");
	d = disk("ext4");
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0), MD_MOUNT, "judge_mount: a linuxfs ext4 disk of the Mac's is mounted");

	/* I6, revised by N1: whose disk it is */
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0), MD_MOUNT, "judge_owner: a physical disk whose node is root's");
	d.node_uid = 502;
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0), MD_USER, "judge_owner: node 502 for peer 501 is the user's own mount");
	starts(why, "not your disk", "judge_owner: \"not your disk\"");
	d = disk("ext4");
	d.image = 1;
	d.node_uid = 501;
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0), MD_MOUNT, "judge_owner: an image the peer attached");
	d.node_uid = 0;
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0), MD_USER, "judge_owner: an image root attached (sudo hdiutil attach) is the user's own mount");
	starts(why, "not your disk", "judge_owner: and says so");
	d.node_uid = 502;
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0), MD_USER, "judge_owner: an image another user attached");
	d.node_uid = 0;
	is(judge(&r, &d, 0, "ext4", 0, &p, 0, 0) == MD_REFUSE && rc == 1, 1, "judge_owner: peer 0 (root) is refused, even for root's image (m4)");
	starts(why, "root mounts by itself", "judge_owner: \"root mounts by itself\"");
	d.image = 0;
	is(judge(&r, &d, 0, "ext4", 0, &p, 0, 0), MD_REFUSE, "judge_owner: peer 0 is refused for a physical disk too");
	d.node_uid = 502;
	d.image = 0;
	d.has_path = 1;
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0), MD_REFUSE, "judge_owner: DiskArbitration's own facts come first (a mounted disk)");

	{
		static const char *kinds[] = { "hfs", "macfuse_ext", "macfuse_btrfs", "" };

		for (int i = 0; i < 4; i++) {
			char what[80];

			d = disk("ext4");
			snprintf(d.kind, sizeof(d.kind), "%s", kinds[i]);
			snprintf(what, sizeof(what), "judge_kind: kind '%s' for fs ext4 is refused, rc 1", kinds[i]);
			is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0) == MD_REFUSE && rc == 1 && why, 1, what);
		}
	}
	d = disk("ext4");
	snprintf(d.bsd, sizeof(d.bsd), "disk3s2");
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0), MD_REFUSE, "judge_kind: a description of another BSD name is refused");
	d = disk("ext4");
	d.has_path = 1;
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0) == MD_REFUSE && rc == 1, 1, "judge_mounted: DiskArbitration has a VolumePath");
	d = disk("ext4");
	is(judge(&r, &d, 501, "ext4", 0, &p, 1, 0) == MD_REFUSE && rc == 1, 1, "judge_mounted: something is mounted from the disk");
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 1) == MD_REFUSE && rc == 1, 1, "judge_mounted: something is mounted on MNT");
	d.leaf = 0;
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0) == MD_REFUSE && rc == 1, 1, "judge_not_leaf: a disk with partitions under it");

	d = disk("ext4");
	snprintf(d.content, sizeof(d.content), EFI_GUID);
	is(judge(&r, &d, 501, "ext4", 0, &p, 0, 0) == MD_REFUSE && rc == 1, 1, "judge_media: the EFI System Partition");
	r = request("ntfs", "-");
	d = disk("ntfs");
	d.ejectable = 0;
	is(judge(&r, &d, 501, "ntfs3", 0, &take, 0, 0) == MD_REFUSE && rc == 1, 1, "judge_media: internal NTFS");
	r = request("apfs", "-");
	d = disk("apfs");
	d.ejectable = d.removable = 0;
	is(judge(&r, &d, 501, "apfs", 0, &p, 0, 0) == MD_REFUSE && rc == 1, 1, "judge_media: internal APFS read-write");
	r = request("apfs", "ro");
	is(judge(&r, &d, 501, "apfs", 0, &p, 0, 0), MD_MOUNT, "judge_media: internal APFS read-only is mounted");

	r = request("ext4", "-");
	d = disk("ext4");
	is(judge(&r, &d, 501, "btrfs", 0, &p, 0, 0) == MD_REFUSE && rc == 1, 1, "judge_type: btrfs's superblock for fs ext4");
	is(judge(&r, &d, 501, NULL, 0, &p, 0, 0) == MD_REFUSE && rc == 1, 1, "judge_type: no filesystem the probe knows");

	r = request("ntfs", "-");
	d = disk("ntfs");
	is(judge(&r, &d, 501, "ntfs3", 0, &p, 0, 0) == MD_REFUSE && rc == 3, 1, "judge_claims: removable NTFS without NTFSTakeover: rc 3");
	is(judge(&r, &d, 501, "ntfs3", 0, &take, 0, 0), MD_MOUNT, "judge_claims: with NTFSTakeover it is mounted");
	d.removable = 0;
	is(judge(&r, &d, 501, "ntfs3", 0, &take, 0, 0) == MD_REFUSE && rc == 3, 1,
	   "judge_claims: ejectable but not removable: the util's answer for fixed, rc 3 (M7)");

	r = request("apfs", "-");
	d = disk("apfs");
	is(judge(&r, &d, 501, "apfs", FSF_ENCRYPTED, &p, 0, 0), MD_USER, "judge_encrypted: an encrypted APFS volume is the user's own mount");
	starts(why, "encrypted", "judge_encrypted: and says so");

	/* ---- the mount point ---- */
	{
		struct stat vol = dir(7, 2, 0, S_IFDIR | 01777), entry, opened;
		int adopt = -1;

		opened = entry = dir(7, 100, 0, S_IFDIR | 0755);
		is(mountd_mnt_facts(&opened, &entry, &vol, 1, 501, &adopt, &why) == 0 && adopt == 0, 1, "mnt_facts: root's: kept as it is");
		opened = entry = dir(7, 100, 501, S_IFDIR | 0700);
		adopt = -1;
		is(mountd_mnt_facts(&opened, &entry, &vol, 1, 501, &adopt, &why) == 0 && adopt == 1, 1, "mnt_facts: the peer's: adopted");
		opened = entry = dir(7, 100, 502, S_IFDIR | 0755);
		is(mountd_mnt_facts(&opened, &entry, &vol, 1, 501, &adopt, &why), -1, "mnt_facts: another user's is refused");
		opened = entry = dir(7, 100, 0, S_IFDIR | 0755);
		entry.st_ino = 101;
		is(mountd_mnt_facts(&opened, &entry, &vol, 1, 501, &adopt, &why), -1, "mnt_facts: the entry is not the directory opened");
		opened = entry = dir(8, 100, 0, S_IFDIR | 0755);
		is(mountd_mnt_facts(&opened, &entry, &vol, 1, 501, &adopt, &why), -1, "mnt_facts: not on /Volumes's device");
		opened = entry = dir(7, 100, 0, S_IFDIR | 0755);
		is(mountd_mnt_facts(&opened, &entry, &vol, 0, 501, &adopt, &why), -1, "mnt_facts: not empty");
		opened = entry = dir(7, 100, 0, S_IFREG | 0644);
		is(mountd_mnt_facts(&opened, &entry, &vol, 1, 501, &adopt, &why), -1, "mnt_facts: not a directory");

		opened = entry = dir(7, 100, 0, S_IFDIR | 0755);
		is(mountd_adopted(&opened, &entry, 1, 501, &why), 0, "adopted: root's, 0755, the same entry");
		entry.st_ino = 101;
		is(mountd_adopted(&opened, &entry, 1, 501, &why), -1, "adopted: the entry swapped after fchown");
		opened = entry = dir(7, 100, 0, S_IFDIR | 01777);
		is(mountd_adopted(&opened, &entry, 1, 501, &why), -1, "adopted: mode 01777");
		opened = entry = dir(7, 100, 501, S_IFDIR | 0755);
		is(mountd_adopted(&opened, &entry, 1, 501, &why), -1, "adopted: still the peer's");
		opened = entry = dir(7, 100, 0, S_IFDIR | 0755);
		is(mountd_adopted(&opened, &entry, 0, 501, &why), -1, "adopted: filled before fchown (m3)");
		starts(why, "the mount point is not empty", "adopted: and says it is not empty");
	}

	/* ---- the status and the reply ---- */
	is(mountd_rc(0), 1, "rc: 0 is 1");
	is(mountd_rc(3), 3, "rc: 3 is 3");
	is(mountd_rc(255), 255, "rc: 255 is 255");
	is(mountd_rc(256), 1, "rc: 256 is 1");
	is(mountd_rc(-1), 1, "rc: -1 is 1");
	n = mountd_reply(buf, sizeof(buf), MD_MOUNT, 0, NULL);
	iss(buf, "ok\n", "reply: ok");
	is((long)n, 3, "reply: its length");
	mountd_reply(buf, sizeof(buf), MD_REFUSE, 3, "x");
	iss(buf, "no\t3\tx\n", "reply: no 3 x");
	mountd_reply(buf, sizeof(buf), MD_REFUSE, 0, "x");
	iss(buf, "no\t1\tx\n", "reply: no with rc 0 is no 1");
	mountd_reply(buf, sizeof(buf), MD_USER, 0, "encrypted");
	iss(buf, "user\tencrypted\n", "reply: user encrypted");
	mountd_reply(buf, sizeof(buf), MD_USER, 0, "a\tb\nc");
	iss(buf, "user\ta b c\n", "reply: tabs and control characters in WHY become spaces");
	mountd_reply(buf, sizeof(buf), MD_REFUSE, 1, "a\177b\001");
	iss(buf, "no\t1\ta b \n", "reply: DEL too");
	n = mountd_reply(buf, 8, MD_USER, 0, "a long reason");
	is(n < 8 && buf[n - 1] == '\n' && buf[n] == '\0', 1, "reply: cut to fit, still one line");

	/* ---- the bounds (N6, R2): what the daemon may take, against what the mount program waits ---- */
	is(MOUNTD_REQUEST, 5, "limits: the request is read within 5 s");
	is(MOUNTD_QUEUE_WAIT, 60, "limits: a queued request waits at most 60 s");
	is(MOUNTD_PREBEGIN, 30, "limits: 30 s before begin");
	is(MOUNTD_DEADLINE, 170, "limits: the program's deadline is 170 s");
	is(MOUNTD_GRACE, 20, "limits: its grace is 20 s");
	is(MOUNTD_QUEUE_WAIT + MOUNTD_REQUEST + MOUNTD_PREBEGIN + MOUNTD_DEADLINE + MOUNTD_GRACE <= MOUNTD_CLIENT_WAIT - 5, 1,
	   "limits_fit: the five bounds add up to at most the client's wait less 5 s");
	is(MOUNTD_CLIENT_WAIT <= 290, 1, "limits_fit: the client waits at most 290 s, under the smoke's 300 s attach bound");
	is(MOUNTD_CLIENT_PREBEGIN, MOUNTD_QUEUE_WAIT + MOUNTD_REQUEST + MOUNTD_PREBEGIN + 5,
	   "limits_fit: from hi to begin, the client waits the queue, the request and the pre-begin bounds, plus 5 s");
	is(MOUNTD_CLIENT_PREBEGIN < MOUNTD_CLIENT_WAIT, 1, "limits_fit: and less than its whole wait");
	is(MOUNTD_SLOTS_UID, 4, "limits: 4 children per user");
	is(MOUNTD_SLOTS, 8, "limits: 8 children in all");
	is(MOUNTD_QUEUE, 16, "limits: 16 queued per user");
	is(MOUNTD_IDLE, 60, "limits: the daemon leaves after 60 s idle");

	printf("1..%d\n", tapno);
	return failures != 0;
}
