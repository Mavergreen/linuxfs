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

int main(void)
{
	enum fsrole r;
	static const char *const six[] = { "ext4", "btrfs", "xfs", "f2fs", "apfs" };
	static const char *const types[] = { "ext4", "btrfs", "xfs", "f2fs", "apfs", "ntfs3", "exfat", "vfat", "hfs" };
	struct fsprefs p;
	struct mountreq m;
	char out[512], label[700];
	int i, j, claimed_ok, others_ok;

	r = FS_FSCK;
	iss(fsrules_fs_from_name("/S/L/F/linuxfs_ext4.fs/Contents/Resources/linuxfs_ext4.util", &r), "ext4", "a util path names ext4");
	is(r == FS_UTIL, 1, "and its role is FS_UTIL");
	iss(fsrules_fs_from_name("mount_linuxfs_ntfs", &r), "ntfs", "mount_linuxfs_ntfs names ntfs");
	is(r == FS_MOUNT, 1, "and its role is FS_MOUNT");
	iss(fsrules_fs_from_name("/sbin/fsck_linuxfs_apfs", &r), "apfs", "fsck_linuxfs_apfs names apfs");
	is(r == FS_FSCK, 1, "and its role is FS_FSCK");
	iss(fsrules_fs_from_name("linuxfs_btrfs.util", &r), "btrfs", "btrfs");
	iss(fsrules_fs_from_name("linuxfs_xfs.util", &r), "xfs", "xfs");
	iss(fsrules_fs_from_name("linuxfs_f2fs.util", &r), "f2fs", "f2fs");
	iss(fsrules_fs_from_name("linuxfs_hfs.util", &r), NULL, "an unknown filesystem is NULL");
	iss(fsrules_fs_from_name("mount_linuxfs", &r), NULL, "mount_linuxfs with no filesystem is NULL");
	iss(fsrules_fs_from_name("mount_linuxfs_", &r), NULL, "an empty filesystem is NULL");
	iss(fsrules_fs_from_name("mount_hfs", &r), NULL, "another program is NULL");
	iss(fsrules_fs_from_name("linuxfs_ext4", &r), NULL, "a util without .util is NULL");
	iss(fsrules_fs_from_name("linuxfs_ext4.util/", &r), NULL, "a trailing slash is NULL");
	iss(fsrules_fs_from_name(NULL, &r), NULL, "no name is NULL");

	iss(fsrules_probe_type("ntfs"), "ntfs3", "ntfs is probed as ntfs3");
	iss(fsrules_probe_type("ext4"), "ext4", "ext4 is probed as ext4");
	iss(fsrules_probe_type("apfs"), "apfs", "apfs is probed as apfs");

	fsrules_default_prefs(&p);
	is(p.automount, 1, "Automount defaults on");
	is(p.readonly, 0, "ReadOnly defaults off");
	is(p.ntfs_takeover, 0, "NTFSTakeover defaults off");
	is(p.apfs_write, 0, "APFSWrite defaults off");

	claimed_ok = others_ok = 1;
	for (i = 0; i < 5; i++)
		for (j = 0; j < 9; j++) {
			int c = fsrules_claims(six[i], types[j], 0, &p);
			if (j == i && !c) claimed_ok = 0;
			if (j != i && c) others_ok = 0;
		}
	is(claimed_ok, 1, "ext4, btrfs, xfs, f2fs and apfs each claim their own type");
	is(others_ok, 1, "and no other (ntfs3, exfat, vfat and hfs among them)");
	is(fsrules_claims("ext4", "vfat", 1, &p), 0, "vfat is never claimed");
	is(fsrules_claims("ntfs", "exfat", 1, &p), 0, "exfat is never claimed");
	is(fsrules_claims("ntfs", "hfs", 1, &p), 0, "hfs is never claimed");
	is(fsrules_claims("ntfs", "ntfs3", 1, &p), 0, "ntfs declines by default");
	p.ntfs_takeover = 1; p.automount = 1;
	is(fsrules_claims("ntfs", "ntfs3", 1, &p), 1, "ntfs claims ntfs3 with takeover, automount and removable");
	is(fsrules_claims("ntfs", "ntfs3", 0, &p), 0, "ntfs declines on internal media");
	p.automount = 0;
	is(fsrules_claims("ntfs", "ntfs3", 1, &p), 0, "ntfs declines with Automount off");
	p.automount = 1; p.ntfs_takeover = 0;
	is(fsrules_claims("ntfs", "ntfs3", 1, &p), 0, "ntfs declines with takeover off");
	is(fsrules_claims("ntfs", "ext4", 1, &p), 0, "ntfs claims nothing else");

	{
		char *a[] = { "-o", "nodev", "-o", "noowners", "-o", "nosuid", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 8, a), 0, "repeated -o and DEV MNT parse");
		is(m.asked, 0, "owners not asked");
		is(m.ro, 0, "not read-only");
		iss(m.dev, "/dev/disk2", "dev");
		iss(m.mnt, "/Volumes/X", "mnt");
	}
	{
		char *a[] = { "-o", "nodev", "-o", "owners", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 6, a), 0, "owners parses");
		is(m.asked, 1, "owners asks for ownership");
	}
	{
		char *a[] = { "-o", "rdonly,nodev", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "a comma list parses");
		is(m.ro, 1, "rdonly is read-only");
		is(m.asked, 0, "and not owners");
	}
	{
		char *a[] = { "-o", "nodev,ro,owners", "/dev/disk2", "/Volumes/X" };
		is(parse(&m, 4, a), 0, "ro,owners in one list parses");
		is(m.ro == 1 && m.asked == 1, 1, "both are seen");
	}
	{
		char *a[] = { "-o", "noowners,nordonly", "/dev/disk2", "/Volumes/X" };
		parse(&m, 4, a);
		is(m.asked == 0 && m.ro == 0, 1, "no-prefixed options are not owners or ro");
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
	fsrules_volname("..x", out, sizeof out);
	iss(out, "x", "leading dots are stripped");
	fsrules_volname("...", out, sizeof out);
	iss(out, "Linux", "only dots is Linux");
	fsrules_volname("\xff", out, sizeof out);
	iss(out, "Linux", "invalid UTF-8 is Linux");
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

	printf("1..%d\n", tapno);
	return failures != 0;
}
