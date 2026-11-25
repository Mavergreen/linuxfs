/*
 * The bundles' portable rules, called directly: which filesystem a program's name stands for, which probe
 * answers a bundle claims, how mount's arguments read, and what a volume is named. usage: fsrules-test
 */
#include <stdio.h>
#include <string.h>
#include "../tools/fsrules.h"

static int tapno, failures;

static void is(int got, int want, const char *what)
{
	tapno++;
	printf("%sok %d - %s\n", got == want ? "" : "not ", tapno, what);
	failures += got != want;
}

static void iss(const char *got, const char *want, const char *what)
{
	tapno++;
	int ok = got == want || (got && want && strcmp(got, want) == 0);
	printf("%sok %d - %s\n", ok ? "" : "not ", tapno, what);
	if (!ok)
		printf("# got '%s', want '%s'\n", got ? got : "(null)", want ? want : "(null)");
	failures += !ok;
}

static int parse(struct mountreq *m, int argc, char **argv)
{
	memset(m, 0, sizeof *m);
	return fsrules_parse_mount(argc, argv, m);
}

/* The six names, exactly as the Global Constraints table has them. */
static const struct { const char *fs, *probe_type, *bundle, *fstypename, *personality, *fsname; int subtype; } want_names[] = {
	{ "ext4", "ext4", "macfuse_ext4", "ext4", "ext4", "Linux ext4 (linuxfs)", 7 },
	{ "ntfs", "ntfs3", "macfuse_ntfs", "ntfs", "NTFS-linuxfs", "Windows NTFS (linuxfs)", 8 },
	{ "btrfs", "btrfs", "macfuse_btrfs", "btrfs", "btrfs", "Linux btrfs (linuxfs)", 9 },
	{ "xfs", "xfs", "macfuse_xfs", "xfs", "XFS", "Linux XFS (linuxfs)", 10 },
	{ "f2fs", "f2fs", "macfuse_f2fs", "f2fs", "F2FS", "Linux F2FS (linuxfs)", 11 },
	{ "apfs", "apfs", "macfuse_apfs", "apfs", "APFS", "APFS (linuxfs)", 12 },
};

/* --names: one TSV row per entry, for the scripts that must agree with the table */
static int print_names(void)
{
	const struct fsname *n;
	size_t i;

	for (i = 0; (n = fsrules_name_at(i)) != NULL; i++)
		printf("%s\t%s\t%s\t%s\t%s\t%s\t%d\n", n->fs, n->probe_type, n->bundle, n->fstypename, n->personality, n->fsname, n->subtype);
	return 0;
}

int main(int argc, char **argv)
{
	int names_mode = argc > 1 && strcmp(argv[1], "--names") == 0;
	size_t k;
	enum fsrole r;
	static const char *const linux_fs[] = { "ext4", "btrfs", "xfs", "f2fs", "apfs" };
	static const char *const types[] = { "ext4", "btrfs", "xfs", "f2fs", "apfs", "ntfs3", "exfat", "vfat", "hfs" };
	struct fsprefs p;
	struct mountreq m;
	char out[512], label[700];
	int i, j, claimed_ok, others_ok;

	if (names_mode)
		return print_names();
	r = FS_FSCK;
	iss(fsrules_fs_from_name("/S/L/F/macfuse_ext4.fs/Contents/Resources/macfuse_ext4.util", &r), "ext4", "a util path names ext4");
	is(r == FS_UTIL, 1, "and its role is FS_UTIL");
	iss(fsrules_fs_from_name("mount_macfuse_ntfs", &r), "ntfs", "mount_macfuse_ntfs names ntfs");
	is(r == FS_MOUNT, 1, "and its role is FS_MOUNT");
	iss(fsrules_fs_from_name("/sbin/fsck_macfuse_apfs", &r), "apfs", "fsck_macfuse_apfs names apfs");
	is(r == FS_FSCK, 1, "and its role is FS_FSCK");
	iss(fsrules_fs_from_name("macfuse_btrfs.util", &r), "btrfs", "btrfs");
	iss(fsrules_fs_from_name("macfuse_xfs.util", &r), "xfs", "xfs");
	iss(fsrules_fs_from_name("macfuse_f2fs.util", &r), "f2fs", "f2fs");
	iss(fsrules_fs_from_name("macfuse_hfs.util", &r), NULL, "an unknown filesystem is NULL");
	iss(fsrules_fs_from_name("mount_linuxfs", &r), NULL, "mount_linuxfs with no filesystem is NULL");
	iss(fsrules_fs_from_name("mount_linuxfs_", &r), NULL, "an empty filesystem is NULL");
	iss(fsrules_fs_from_name("mount_macfuse_hfs", &r), NULL, "mount_macfuse_hfs is NULL");
	iss(fsrules_fs_from_name("fsck_macfuse_hfs", &r), NULL, "fsck_macfuse_hfs is NULL");
	iss(fsrules_fs_from_name("mount_hfs", &r), NULL, "another program is NULL");
	iss(fsrules_fs_from_name("mount_macfuse_ext4", NULL), "ext4", "a NULL role is tolerated");
	r = FS_UTIL;
	iss(fsrules_fs_from_name("mount_macfuse_hfs", &r), NULL, "a failed lookup");
	is(r == FS_UTIL, 1, "leaves the role alone");
	iss(fsrules_fs_from_name("macfuse_ext4", &r), NULL, "a util without .util is NULL");
	iss(fsrules_fs_from_name("macfuse_ext4.util/", &r), NULL, "a trailing slash is NULL");
	iss(fsrules_fs_from_name(NULL, &r), NULL, "no name is NULL");

	for (k = 0; k < 6; k++) {
		const struct fsname *n = fsrules_name_at(k);
		int same = n && strcmp(n->fs, want_names[k].fs) == 0 && strcmp(n->probe_type, want_names[k].probe_type) == 0 &&
			   strcmp(n->bundle, want_names[k].bundle) == 0 && strcmp(n->fstypename, want_names[k].fstypename) == 0 &&
			   strcmp(n->personality, want_names[k].personality) == 0 && strcmp(n->fsname, want_names[k].fsname) == 0 &&
			   n->subtype == want_names[k].subtype;

		is(same, 1, want_names[k].fs);
		is(n && strlen(n->fstypename) <= 6, 1, "its fstypename is at most 6 bytes");
		is(fsrules_name(want_names[k].fs) == n, 1, "fsrules_name finds it by fs");
		iss(fsrules_fs_of_type(want_names[k].bundle), want_names[k].fs, "fsrules_fs_of_type maps its macfuse_ name back");
	}
	is(fsrules_name_at(6) == NULL, 1, "there are six entries");
	is(fsrules_name("zfs") == NULL, 1, "fsrules_name of another is NULL");
	is(fsrules_name(NULL) == NULL, 1, "fsrules_name of NULL is NULL");
	iss(fsrules_fs_of_type("macfuse_ntfs"), "ntfs", "macfuse_ntfs is ntfs");
	iss(fsrules_fs_of_type("macfuse"), NULL, "plain macfuse is no type of ours");
	iss(fsrules_fs_of_type("macfuse_zfs"), NULL, "macfuse_zfs is not");
	iss(fsrules_fs_of_type("macfuse_ext4x"), NULL, "macfuse_ext4x is not");
	iss(fsrules_fs_of_type("linuxfs_ext4"), NULL, "the old name is not");
	iss(fsrules_fs_of_type("osxfuse"), NULL, "osxfuse is not");
	iss(fsrules_fs_of_type(NULL), NULL, "NULL is not");
	/* spec: Task 16f -- a BSD name is disk[0-9]+(s[0-9]+)?, at most 32 characters: what root opens as /dev/r<bsd>, and what
	 * the mount daemon (16g) takes from a request; moved from fs.c unchanged */
	{
		static const char *const good[] = { "disk2", "disk2s1" };
		static const char *const bad[] = { "diskX", "disk", "disk2s", "../disk2", "disk2s1x", "rdisk2",
						    "disk12345678901234567890123456789" };
		char what[96];

		for (k = 0; k < sizeof good / sizeof good[0]; k++) {
			snprintf(what, sizeof what, "valid_bsd: %s is a BSD name", good[k]);
			is(fsrules_valid_bsd(good[k]), 1, what);
		}
		for (k = 0; k < sizeof bad / sizeof bad[0]; k++) {
			snprintf(what, sizeof what, "valid_bsd: %s (%d characters) is not", bad[k], (int)strlen(bad[k]));
			is(fsrules_valid_bsd(bad[k]), 0, what);
		}
	}
	/* spec: Task 16f fix round 1 (m4) -- root locks and checks a disk whole: disk2 for disk2sN, and a mount from /dev/disk2 or
	 * any /dev/disk2s<N> (digits after the s, nothing more) is from that disk; disk22 is another disk */
	{
		char w[40];

		is(fsrules_whole_disk("disk2s1", w, sizeof w), 1, "whole_disk: disk2s1 is valid");
		iss(w, "disk2", "whole_disk: disk2s1's whole disk is disk2");
		is(fsrules_whole_disk("disk22", w, sizeof w), 1, "whole_disk: disk22 is valid");
		iss(w, "disk22", "whole_disk: disk22 is its own whole disk");
		is(fsrules_whole_disk("disk2s", w, sizeof w), 0, "whole_disk: disk2s is not a BSD name");
		is(fsrules_whole_disk("disk2s1", w, 5), 0, "whole_disk: no room for the name is 0");
		is(fsrules_from_disk("/dev/disk2", "disk2"), 1, "from_disk: /dev/disk2 is disk2's");
		is(fsrules_from_disk("/dev/disk2s1", "disk2"), 1, "from_disk: /dev/disk2s1 is disk2's");
		is(fsrules_from_disk("/dev/disk2s15", "disk2"), 1, "from_disk: /dev/disk2s15 is disk2's");
		is(fsrules_from_disk("/dev/disk22", "disk2"), 0, "from_disk: /dev/disk22 is not disk2's");
		is(fsrules_from_disk("/dev/disk22s1", "disk2"), 0, "from_disk: /dev/disk22s1 is not disk2's");
		is(fsrules_from_disk("/dev/disk2s", "disk2"), 0, "from_disk: /dev/disk2s is not");
		is(fsrules_from_disk("/dev/disk2s1x", "disk2"), 0, "from_disk: /dev/disk2s1x is not");
		is(fsrules_from_disk("/dev/disk2sa", "disk2"), 0, "from_disk: /dev/disk2sa is not");
		is(fsrules_from_disk("/dev/rdisk2s1", "disk2"), 0, "from_disk: /dev/rdisk2s1 is not (a raw node is never a mount's source)");
		is(fsrules_from_disk("disk2s1", "disk2"), 0, "from_disk: a name without /dev/ is not");
		is(fsrules_from_disk("linuxfs@disk2s1", "disk2"), 0, "from_disk: linuxfs@disk2s1 is not");
		is(fsrules_from_disk(NULL, "disk2"), 0, "from_disk: NULL is not");
		is(fsrules_from_disk("/dev/disk2", NULL), 0, "from_disk: no disk is never matched");
	}
	/* spec: item 6 (fsname=/dev/<bsd>) -- root's force-unmount takes only a mount root made itself: one of our six, of
	 * the bundle's own fs, from /dev/<bsd>, owned by root; anything else on that mount point is someone else's */
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse_ext4", "/dev/disk2s1", 0), 1, "roots: ext4 mounted by root from /dev/disk2s1");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "hfs", "/dev/disk2s1", 0), 0, "roots: not hfs from the same disk (a foreign mount on the point)");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse_ext4", "/dev/disk2s1", 501), 0, "roots: not macfuse_ext4 a user (501) made");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse_btrfs", "/dev/disk2s1", 0), 0, "roots: not macfuse_btrfs, for fs ext4");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse_ext4", "linuxfs@disk2s1", 0), 0, "roots: not linuxfs@disk2s1");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse_ext4", "/dev/disk2s10", 0), 0, "roots: not /dev/disk2s10 (a longer name)");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse_ext4", "/dev/disk2", 0), 0, "roots: not /dev/disk2 (a shorter one)");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse_ext4", "/dev/rdisk2s1", 0), 0, "roots: not /dev/rdisk2s1");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse", "/dev/disk2s1", 0), 0, "roots: not plain macfuse");
	is(fsrules_mount_is_roots("ntfs", "disk3", "macfuse_ntfs", "/dev/disk3", 0), 1, "roots: ntfs from a whole disk, /dev/disk3");
	is(fsrules_mount_is_roots(NULL, "disk2s1", "macfuse_ext4", "/dev/disk2s1", 0), 0, "roots: no fs is never root's");
	is(fsrules_mount_is_roots("ext4", NULL, "macfuse_ext4", "/dev/disk2s1", 0), 0, "roots: no bsd is never root's");
	is(fsrules_mount_is_roots("ext4", "disk2s1", NULL, "/dev/disk2s1", 0), 0, "roots: no type is never root's");
	is(fsrules_mount_is_roots("ext4", "disk2s1", "macfuse_ext4", NULL, 0), 0, "roots: no source is never root's");
	iss(fsrules_fs_from_name("mount_linuxfs_ext4", &r), NULL, "mount_linuxfs_ext4 names nothing now");
	iss(fsrules_fs_from_name("linuxfs_ext4.util", &r), NULL, "linuxfs_ext4.util names nothing now");
	iss(fsrules_fs_from_name("fsck_linuxfs_ext4", &r), NULL, "fsck_linuxfs_ext4 names nothing now");
	iss(fsrules_probe_type("ntfs"), "ntfs3", "ntfs is probed as ntfs3");
	iss(fsrules_probe_type("ext4"), "ext4", "ext4 is probed as ext4");
	iss(fsrules_probe_type("apfs"), "apfs", "apfs is probed as apfs");

	fsrules_default_prefs(&p);
	is(p.readonly, 0, "ReadOnly defaults off");
	is(p.ntfs_takeover, 0, "NTFSTakeover defaults off");
	is(p.apfs_write, 0, "APFSWrite defaults off");

	claimed_ok = others_ok = 1;
	for (i = 0; i < 5; i++)
		for (j = 0; j < 9; j++) {
			int c = fsrules_claims(linux_fs[i], types[j], 0, &p);
			if (j == i && !c) claimed_ok = 0;
			if (j != i && c) others_ok = 0;
		}
	is(claimed_ok, 1, "ext4, btrfs, xfs, f2fs and apfs each claim their own type");
	is(others_ok, 1, "and no other (ntfs3, exfat, vfat and hfs among them)");
	is(fsrules_claims("ext4", "vfat", 1, &p), 0, "vfat is never claimed");
	is(fsrules_claims("ntfs", "exfat", 1, &p), 0, "exfat is never claimed");
	is(fsrules_claims("ntfs", "hfs", 1, &p), 0, "hfs is never claimed");
	is(fsrules_claims("ntfs", "ntfs3", 1, &p), 0, "ntfs declines by default");
	p.ntfs_takeover = 1;
	is(fsrules_claims("ntfs", "ntfs3", 1, &p), 1, "ntfs claims ntfs3 with takeover and removable (no Automount: /etc/fstab's noauto is per volume)");
	is(fsrules_claims("ntfs", "ntfs3", 0, &p), 0, "ntfs declines on internal media");
	p.ntfs_takeover = 0;
	is(fsrules_claims("ntfs", "ntfs3", 1, &p), 0, "ntfs declines with takeover off");
	is(fsrules_claims("ntfs", "ext4", 1, &p), 0, "ntfs claims nothing else");
	is(fsrules_claims("ext4", "ext4", 1, NULL), 0, "no prefs declines");

	{
		char *a[] = { "-o", "nodev", "-o", "noowners", "-o", "nosuid", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 8, a), 0, "repeated -o and DEV MNT parse");
		is(m.ro, 0, "not read-only");
		is(m.owners, 0, "noowners (what 10.9's DiskArbitration passes an external disk with no vsdb or fstab say) is owners 0");
		is(m.update, 0, "and not an update");
		iss(m.dev, "/dev/disk2", "dev");
		iss(m.mnt, "/Volumes/X", "mnt");
	}
	{
		char *a[] = { "-o", "nodev", "-o", "owners", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 6, a), 0, "owners parses");
		is(m.ro, 0, "and is not read-only");
		is(m.owners, 1, "-o owners is owners 1");
	}
	{
		/* DiskArbitration puts an fstab or vsdb entry's options after its own nodev,noowners,nosuid: the last one wins, as
		 * mount(8)'s getmntopts has it */
		char *a[] = { "-o", "nodev", "-o", "noowners", "-o", "nosuid", "-o", "owners", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 10, a), 0, "noowners then owners parses");
		is(m.owners, 1, "the later owners wins");
	}
	{
		char *a[] = { "-o", "owners,nodev,noowners", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "owners then noowners in one list parses");
		is(m.owners, 0, "the later noowners wins");
	}
	{
		char *a[] = { "-o", "perm", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "perm parses");
		is(m.owners, 1, "perm is owners (mount(8)'s other name for it)");
	}
	{
		char *a[] = { "-o", "owners,noperm", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "owners,noperm parses");
		is(m.owners, 0, "noperm is noowners");
	}
	{
		char *a[] = { "-o", "ownersx,xowners,owner", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "near-misses parse");
		is(m.owners, 0, "and none of them is owners");
	}
	{
		char *a[] = { "/dev/disk2", "/Volumes/X" };
		m.owners = 1;
		is(fsrules_parse_mount(2, a, &m), 0, "no -o parses");
		is(m.owners, 0, "with no owners asked for, owners is 0 (today's mapping)");
	}
	{
		/* vsdbutil (diskutil enableOwnership) runs mount -u -o perm,...: mount(8) passes it as -o ...,update */
		char *a[] = { "-o", "perm,nosuid,nodev,update", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "an update parses");
		is(m.update, 1, "and says so");
	}
	{
		char *a[] = { "-o", "noupdate", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "noupdate parses");
		is(m.update, 0, "and is not an update");
	}
	{
		char *a[] = { "-o", "rdonly,nodev", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "a comma list parses");
		is(m.ro, 1, "rdonly is read-only");
	}
	{
		char *a[] = { "-o", "nodev,ro,owners", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "ro,owners in one list parses");
		is(m.ro, 1, "ro is seen beside it");
	}
	{
		char *a[] = { "-o", "noowners,nordonly", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "no-prefixed options parse");
		is(m.ro, 0, "no-prefixed options are not ro");
	}
	{
		char *a[] = { "-oowners,rdonly", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 3, a), 0, "the attached form -oowners,rdonly parses");
		is(m.ro, 1, "and is read");
		iss(m.mnt, "/Volumes/X", "with MNT after it");
	}
	{
		char *a[] = { "-o", "nodev", "/dev/disk2" };
		is(parse(&m, 3, a), -1, "a missing MNT is misuse");
	}
	{
		char *a[] = { "/dev/disk2", "/Volumes/X", "extra" };
		is(parse(&m, 3, a), -1, "a third positional argument is misuse");
	}
	{
		char *a[] = { "-o" };
		is(parse(&m, 1, a), -1, "-o with no value is misuse");
	}
	{
		char *a[] = { "-x", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 3, a), -1, "an unknown flag is misuse");
	}

	fsrules_volname("", out, sizeof out);
	iss(out, "Linux", "an empty label is Linux");
	fsrules_volname(NULL, out, sizeof out);
	iss(out, "Linux", "no label is Linux");
	fsrules_volname("my data", out, sizeof out);
	iss(out, "my data", "an ordinary label is kept");
	fsrules_volname("a/b:c", out, sizeof out);
	iss(out, "a-b-c", "/ and : become -");
	fsrules_volname("a,b=c\\d", out, sizeof out);
	iss(out, "a-b-c-d", ", = and backslash become -");
	fsrules_volname("a\nb", out, sizeof out);
	iss(out, "a-b", "a newline becomes -");
	fsrules_volname("a\rb", out, sizeof out);
	iss(out, "a-b", "a carriage return becomes -");
	fsrules_volname("a\tb", out, sizeof out);
	iss(out, "a-b", "a tab becomes -");
	fsrules_volname("a\x1b" "b", out, sizeof out);
	iss(out, "a-b", "an escape becomes -");
	fsrules_volname("a\x7f" "b", out, sizeof out);
	iss(out, "a-b", "DEL becomes -");
	fsrules_volname("..x", out, sizeof out);
	iss(out, "x", "leading dots are stripped");
	fsrules_volname("...", out, sizeof out);
	iss(out, "Linux", "only dots is Linux");
	fsrules_volname("\xff", out, sizeof out);
	iss(out, "Linux", "invalid UTF-8 is Linux");
	fsrules_volname("\xc3", out, sizeof out);
	iss(out, "Linux", "a truncated 2-byte sequence is Linux");
	fsrules_volname("\xe2\x82", out, sizeof out);
	iss(out, "Linux", "a truncated 3-byte sequence is Linux");
	fsrules_volname("\xc0\x80", out, sizeof out);
	iss(out, "Linux", "an overlong 2-byte form is Linux");
	fsrules_volname("\xe0\x80\x80", out, sizeof out);
	iss(out, "Linux", "an overlong 3-byte form is Linux");
	fsrules_volname("\xed\xa0\x80", out, sizeof out);
	iss(out, "Linux", "a surrogate is Linux");
	fsrules_volname("\xf4\x90\x80\x80", out, sizeof out);
	iss(out, "Linux", "a value above U+10FFFF is Linux");
	memset(label, 'a', 199); strcpy(label + 199, "\xf0\x9f\x98\x80\xf0\x9f\x98\x80");
	fsrules_volname(label, out, sizeof out);
	is((int)strlen(out), 203, "a 4-byte character that is the 200th is kept whole, the next cut");
	memset(label, 'a', 198); strcpy(label + 198, "\xf0\x9f\x98\x80\xf0\x9f\x98\x80\xf0\x9f\x98\x80");
	fsrules_volname(label, out, sizeof out);
	is((int)strlen(out), 198 + 8, "the 199th and 200th are kept, the 201st cut");
	fsrules_volname("aaa\xf0\x9f\x98\x80", out, 7);
	iss(out, "aaa", "a 4-byte character that does not fit the buffer is dropped whole");
	fsrules_volname("Donn\xc3\xa9" "es \xf0\x9f\x98\x80", out, sizeof out);
	iss(out, "Donn\xc3\xa9" "es \xf0\x9f\x98\x80", "UTF-8 is kept");
	memset(label, 'a', 300); label[300] = 0;
	fsrules_volname(label, out, sizeof out);
	is((int)strlen(out), 200, "a 300-character label is cut to 200");
	for (i = 0; i < 300; i++) { label[2 * i] = '\xc3'; label[2 * i + 1] = '\xa9'; }
	label[600] = 0;
	fsrules_volname(label, out, sizeof out);
	is((int)strlen(out), 400, "300 two-byte characters are cut to 200 characters (400 bytes)");
	memset(label, 'a', 399); label[399] = 0;
	fsrules_volname(label, out, 6);
	is((int)strlen(out), 5, "a small buffer is respected");
	fsrules_volname("\xc3\xa9\xc3\xa9", out, 4);
	iss(out, "\xc3\xa9", "a small buffer is cut on a character boundary");

	{
		char hint[64];

		is(fsrules_hint("linuxfs: wrong password for /dev/disk4s1 (hint: test)\n", hint, sizeof hint) &&
		   strcmp(hint, "test") == 0, 1, "the CLI's wrong-password message gives the volume's hint");
		is(fsrules_hint("linuxfs: /dev/disk4s1 is an encrypted volume; give its password\n", hint, sizeof hint), 0,
		   "and no hint when it names none");
		is(fsrules_hint("a (hint: one)\nb (hint: two)\n", hint, sizeof hint) && strcmp(hint, "two") == 0, 1,
		   "the last hint wins");
		is(fsrules_hint("x (hint: long long long)", hint, 5) && strcmp(hint, "long") == 0, 1, "a small buffer cuts the hint");
		is(fsrules_hint("x (hint: a\xc3\xa9)", hint, 3) && strcmp(hint, "a") == 0, 1, "a small buffer cuts the hint on a character boundary");
		is(fsrules_hint("x (hint: a\xc3\xa9)", hint, 4) && strcmp(hint, "a\xc3\xa9") == 0, 1, "a hint in UTF-8 is kept");
		is(fsrules_hint("x (hint: a\xff)", hint, sizeof hint), 0, "a hint that is not UTF-8 is dropped");
		is(fsrules_hint("x (hint: a\xc3)", hint, sizeof hint), 0, "a truncated UTF-8 sequence in a hint is dropped");
	}

	{
		struct fsprefs d, aw, ro;
		const char *why;

		fsrules_default_prefs(&d);
		aw = d;
		aw.apfs_write = 1;
		ro = d;
		ro.readonly = 1;
		is((int)fsrules_probe_flags("", ""), 0, "no probe words: no flags");
		is((int)fsrules_probe_flags(NULL, NULL), 0, "absent probe fields: no flags");
		is((int)fsrules_probe_flags("fusion-main 0123", ""), FSF_FUSION, "a Fusion role is FSF_FUSION");
		is((int)fsrules_probe_flags("", "encrypted"), FSF_ENCRYPTED, "encrypted is FSF_ENCRYPTED");
		is((int)fsrules_probe_flags("", "dirty"), FSF_DIRTY, "dirty is FSF_DIRTY");
		is((int)fsrules_probe_flags("fusion-tier2 ab", "dirty  encrypted"), FSF_FUSION | FSF_DIRTY | FSF_ENCRYPTED,
		   "words are separated by spaces, in any order");
		is((int)fsrules_probe_flags("", "encryptedx xdirty other"), 0, "only whole known words count");
#define ACC(type, flags, asked, login, prefs, want, wwhy, what) \
		do { why = "unset"; is(fsrules_access(type, flags, asked, login, prefs, &why), want, what); iss(why, wwhy, what ": why"); } while (0)
		ACC("ext4", 0, 0, 0, &d, FSA_RW, "", "ext4 mounts read-write");
		ACC("ext4", 0, 1, 0, &d, FSA_RO, "asked", "asked for read-only: read-only");
		ACC("ext4", 0, 0, 1, &ro, FSA_RO, "ReadOnly", "the ReadOnly preference: read-only");
		ACC("apfs", 0, 0, 0, &d, FSA_RO, "apfs", "APFS: read-only by default");
		ACC("apfs", 0, 0, 0, &aw, FSA_RW, "", "APFS with APFSWrite: read-write");
		ACC("apfs", FSF_FUSION, 0, 0, &aw, FSA_RO, "fusion", "an APFS Fusion container: read-only whatever APFSWrite says");
		ACC("apfs", FSF_ENCRYPTED, 0, 0, &aw, FSA_RO, "encrypted", "an encrypted APFS volume: read-only whatever APFSWrite says");
		ACC("apfs", FSF_ENCRYPTED, 0, 1, &aw, FSA_REFUSE, "encrypted", "an encrypted volume before login: refused (no keychain, no one to ask)");
		ACC("apfs", FSF_ENCRYPTED, 1, 1, &ro, FSA_REFUSE, "encrypted", "refused before login even when read-only was asked");
		ACC("ntfs3", FSF_DIRTY, 0, 0, &d, FSA_RO, "dirty", "a dirty NTFS volume: read-only");
		ACC("ntfs3", 0, 0, 0, &d, FSA_RW, "", "a clean NTFS volume: read-write");
		ACC("ext4", FSF_DIRTY, 0, 0, &d, FSA_RW, "", "dirty means nothing but on NTFS");
		ACC("apfs", FSF_ENCRYPTED, 1, 0, &aw, FSA_RO, "asked", "asked comes first among the reasons for read-only");
		ACC("apfs", 0, 0, 0, &ro, FSA_RO, "ReadOnly", "then the ReadOnly preference");
		is(fsrules_access(NULL, 0, 0, 0, &d, &why), FSA_REFUSE, "no type: refused");
		is(fsrules_access("ext4", 0, 0, 0, NULL, NULL), FSA_REFUSE, "no preferences: refused");
#undef ACC
	}

	printf("1..%d\n", tapno);
	return failures != 0;
}
