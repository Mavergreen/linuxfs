/*
 * linuxfs-helper's refusals, called directly: which paths it accepts, which peers, and that it never opens a
 * partition the Mac has mounted (the boot volume here). helper_serve is driven through a socketpair. Its /etc/fstab
 * edits (noauto-add, noauto-remove) on files in a temporary directory, named by LINUXFS_FSTAB (the test override,
 * obeyed only when not root).
 * usage: helper-policy-test
 */
#define LINUXFS_HELPER_NO_MAIN
#include "../tools/helper.c"
#include <dirent.h>

static int tapno, failures;

static void is(int got, int want, const char *what)
{
	tapno++;
	printf("%sok %d - %s", got == want ? "" : "not ", tapno, what);
	if (got != want) {
		printf(" (got %d, want %d)", got, want);
		failures++;
	}
	printf("\n");
}

/* PATH's contents as a string ("(none)" when it cannot be read) */
static const char *slurp(const char *path)
{
	static char buf[FSTAB_MAX + 2];
	int fd = open(path, O_RDONLY);
	ssize_t n = fd >= 0 ? read(fd, buf, sizeof(buf) - 1) : -1;

	if (fd >= 0)
		close(fd);
	if (n < 0)
		return "(none)";
	buf[n] = '\0';
	return buf;
}

static void spit(const char *path, const char *text)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	write(fd, text, strlen(text));
	close(fd);
}

static void iss(const char *got, const char *want, const char *what)
{
	int ok = got == want || (got && want && strcmp(got, want) == 0);

	tapno++;
	printf("%sok %d - %s\n", ok ? "" : "not ", tapno, what);
	if (!ok) {
		printf("# got '%s', want '%s'\n", got ? got : "(null)", want ? want : "(null)");
		failures++;
	}
}

/* entries in DIR other than . and .. */
static int entries(const char *dir)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	int n = 0;

	while (d && (e = readdir(d)))
		n += strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0;
	if (d)
		closedir(d);
	return n;
}

static void answers(const char *req, uid_t peer, uid_t console, const char *want, const char *what)
{
	int sv[2];
	char buf[1024] = { 0 };
	ssize_t n;

	socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
	write(sv[1], req, strlen(req));
	helper_serve(sv[0], peer, console, 0);
	n = read(sv[1], buf, sizeof(buf) - 1);
	close(sv[0]);
	close(sv[1]);
	tapno++;
	if (n > 0 && strncmp(buf, want, strlen(want)) == 0) {
		printf("ok %d - %s\n", tapno, what);
	} else {
		printf("not ok %d - %s (got '%s', want '%s...')\n", tapno, what, buf, want);
		failures++;
	}
}

int main(void)
{
	struct statfs root;
	char raw[128], where[1024], req[256];

	is(helper_device_ok("/dev/rdisk2s1"), 1, "a raw partition node is accepted");
	is(helper_device_ok("/dev/rdisk2"), 1, "a raw whole-disk node is accepted");
	is(helper_device_ok("/dev/disk2s1"), 0, "a block node is refused (raw only)");
	is(helper_device_ok("/dev/rdisk2s"), 0, "a partition suffix with no number is refused");
	is(helper_device_ok("/dev/rdisks1"), 0, "no disk number is refused");
	is(helper_device_ok("/dev/rdisk2s1/../../etc/passwd"), 0, "a path that goes on is refused");
	is(helper_device_ok("/etc/passwd"), 0, "a file is refused");
	is(helper_peer_ok(0, 501), 1, "root may ask");
	is(helper_peer_ok(501, 501), 1, "the console user may ask");
	is(helper_peer_ok(502, 501), 0, "another user may not");
	if (statfs("/", &root) == 0 && strncmp(root.f_mntfromname, "/dev/disk", 9) == 0) {
		snprintf(raw, sizeof(raw), "/dev/r%s", root.f_mntfromname + 5);
		is(helper_mac_mounted(raw, where, sizeof(where)) && strcmp(where, "/") == 0, 1,
		   "the boot volume's partition is seen as mounted by the Mac at /");
		snprintf(req, sizeof(req), "open %s rw\n", raw);
		answers(req, getuid(), getuid(), "no mounted by the Mac at /", "open of the boot partition is refused, naming where it is mounted");
		snprintf(req, sizeof(req), "probe %s\n", raw);
		answers(req, getuid(), getuid(), "no mounted by the Mac", "probe of the boot partition is refused too");
	}
	is(helper_mac_mounted("/dev/rdisk99s9", where, sizeof(where)), 0, "a partition nothing mounts is not mounted");
	/* what the partition is, not only what its bytes say */
	is(helper_media_refusal("C12A7328-F81F-11D2-BA4B-00A0C93EC93B", 1, 0, "vfat", 1) != NULL, 1, "the EFI System Partition is refused");
	is(helper_media_refusal("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", 1, 1, "vfat", 1) != NULL, 1, "an ESP is refused on ejectable media too, in any case");
	is(helper_media_refusal("0xEF", 1, 1, "vfat", 1) != NULL, 1, "an MBR EFI partition is refused");
	is(helper_media_refusal("48465300-0000-11AA-AA11-00306543ECAC", 1, 1, "ext4", 1) != NULL, 1, "an Apple HFS+ partition is refused whatever its bytes say");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, "ext4", 1) != NULL, 1, "an APFS partition is refused");
	is(helper_media_refusal("53746F72-6167-11AA-AA11-00306543ECAC", 1, 1, "ext4", 1) != NULL, 1, "a CoreStorage partition is refused");
	is(helper_media_refusal("426F6F74-0000-11AA-AA11-00306543ECAC", 1, 1, "ext4", 1) != NULL, 1, "Apple Boot (Recovery HD) is refused");
	is(helper_media_refusal("E3C9E316-0B5C-4DB8-817D-F92DF00215AE", 1, 1, "ntfs3", 1) != NULL, 1, "Microsoft Reserved is refused");
	is(helper_media_refusal("DE94BBA4-06D1-4D40-A16A-BFD50179D6AC", 1, 1, "ntfs3", 1) != NULL, 1, "Windows Recovery is refused");
	is(helper_media_refusal("GUID_partition_scheme", 0, 1, "ext4", 1) != NULL, 1, "a disk with partitions under it is refused (I3)");
	is(helper_media_refusal("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", 1, 0, "ntfs3", 1) != NULL, 1, "internal NTFS (Boot Camp) is refused");
	is(helper_media_refusal("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", 1, 0, "vfat", 1) != NULL, 1, "internal FAT is refused");
	is(helper_media_refusal("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", 1, 1, "ntfs3", 1) == NULL, 1, "NTFS on ejectable media is served");
	is(helper_media_refusal("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", 1, 1, "exfat", 1) == NULL, 1, "exFAT on ejectable media is served");
	is(helper_media_refusal("0FC63DAF-8483-4772-8E79-3D69D8477DE4", 1, 0, "ext4", 1) == NULL, 1, "internal Linux ext4 is served");
	is(helper_media_refusal("0x83", 1, 0, "btrfs", 1) == NULL, 1, "an internal MBR Linux partition is served");
	is(helper_media_refusal("", 1, 1, "ext4", 1) == NULL, 1, "an unpartitioned ejectable disk (a stick, an image) is served");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, NULL, 0) == NULL, 1, "an APFS partition may be opened read-only (to probe it)");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, "apfs", 0) == NULL, 1, "APFS is served read-only");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, "apfs", 1) == NULL, 1, "APFS on ejectable media may be served read-write (the user opted in: APFSWrite)");
	is(helper_media_refusal("", 1, 1, "apfs", 1) == NULL, 1, "so may an unpartitioned APFS disk");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 0, "apfs", 1) != NULL, 1, "internal APFS (a newer macOS's own) is never served read-write");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 0, "apfs", 0) == NULL, 1, "but is served read-only");
	is(helper_media_refusal("7C3457EF-0000-11AA-AA11-00306543ECAC", 1, 1, "ext4", 0) != NULL, 1, "an APFS-typed partition holding anything else is refused");
	{
		struct media_facts f;

		is(helper_media_facts("disk0s1", &f) == 0 && strcasecmp(f.content, "C12A7328-F81F-11D2-BA4B-00A0C93EC93B") == 0 &&
		   f.leaf && !f.ejectable, 1, "IOKit says disk0s1 is this Mac's internal ESP");
		is(helper_media_facts("disk0", &f) == 0 && !f.leaf, 1, "IOKit says disk0 has partitions under it");
		is(helper_media_facts("disk99s9", &f) < 0, 1, "a disk IOKit does not know gives no facts");
	}
	answers("open /dev/rdisk99s9 rw\n", 502, 501, "no only the user at the console", "a peer other than the console user is refused");
	answers("open /etc/master.passwd rw\n", 501, 501, "no not a raw disk node", "a path other than a raw disk node is refused");
	answers("open /dev/rdisk99s9 rwx\n", 501, 501, "no request is", "a mode other than rw or ro is refused");
	answers("gimme /dev/rdisk99s9\n", 501, 501, "no request is", "an unknown request is refused");
	answers("open /dev/rdisk0s1 rw\n", getuid(), getuid(), "no a system partition", "open of this Mac's EFI partition is refused (C1)");
	answers("open /dev/rdisk0 ro\n", getuid(), getuid(), "no a disk with partitions", "open of the whole boot disk is refused (I3)");
	answers("uuid /dev/rdisk0s1\n", getuid(), getuid(), "no a system partition", "uuid of this Mac's EFI partition is refused, as probe is");

	/* ---- /etc/fstab: noauto-add SPEC BUNDLE, noauto-remove SPEC ---- */
	{
		char dir[] = "/tmp/helper-fstab.XXXXXX", f[256], tmp[300], big[FSTAB_MAX + 16], other[256], link[256];
		const char *line = "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF none macfuse_ext4 rw,noauto # linuxfs\n";
		const char *mac = "# the Mac's\nUUID=0123ABCD-4567-89EF-0123-456789ABCDEF none hfs rw,noauto\nLABEL=Backup none hfs ro";
		struct stat st, st2;

		unsetenv("LINUXFS_FSTAB");
		iss(helper_fstab_path(), "/etc/fstab", "the fstab is /etc/fstab");
		mkdtemp(dir);
		snprintf(f, sizeof f, "%s/fstab", dir);
		snprintf(tmp, sizeof tmp, "%s/fstab.linuxfs-new", dir);
		setenv("LINUXFS_FSTAB", f, 1);
		iss(helper_fstab_path(), f, "LINUXFS_FSTAB names another, when not root");

		iss(helper_noauto(f, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", "macfuse_ext4"), NULL, "an add with no fstab yet is done");
		iss(slurp(f), line, "and makes the fstab with the one line");
		is(stat(f, &st) == 0 && (st.st_mode & 07777) == 0644 && S_ISREG(st.st_mode), 1, "mode 0644, a regular file");
		iss(helper_noauto(f, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", "macfuse_ext4"), NULL, "adding it again is ok");
		is(stat(f, &st2) == 0 && st2.st_ino == st.st_ino, 1, "and leaves the file alone (not rewritten)");
		iss(helper_noauto(f, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", NULL), NULL, "a remove is done");
		iss(slurp(f), "", "and takes the line away");
		iss(helper_noauto(f, "UUID=0123ABCD-4567-89EF-0123-456789ABCDEF", NULL), NULL, "removing a missing entry is ok");
		unlink(f);
		iss(helper_noauto(f, "LABEL=x", NULL), NULL, "so is removing from no fstab at all");
		is(access(f, F_OK) != 0, 1, "which makes none");

		spit(f, mac);
		iss(helper_noauto(f, "LABEL=my data\there", "linuxfs_ntfs"), NULL, "an add to an fstab with other lines is done");
		snprintf(big, sizeof big, "%s\nLABEL=my\\040data\\011here none linuxfs_ntfs rw,noauto # linuxfs\n", mac);
		iss(slurp(f), big, "every other line is kept byte for byte; the label's space and tab are escaped");
		iss(helper_noauto(f, "LABEL=my data\there", NULL), NULL, "and removed by the same label");
		snprintf(big, sizeof big, "%s\n", mac);
		iss(slurp(f), big, "leaving the others as they were");
		is(entries(dir), 1, "no temporary file is left behind");
		spit(tmp, "stale");
		iss(helper_noauto(f, "LABEL=y", "linuxfs_xfs"), NULL, "a stale temporary file from a crash does not stop an add");
		is(entries(dir) == 1 && strstr(slurp(f), "LABEL=y none linuxfs_xfs rw,noauto # linuxfs\n") != NULL, 1, "the add is whole, and the stale file gone");

		spit(f, mac);
		is(helper_noauto(f, "LABEL=a\nb", "macfuse_ext4") != NULL, 1, "a label with a newline is refused");
		is(helper_noauto(f, "LABEL=a#b", "macfuse_ext4") != NULL, 1, "a label with # is refused");
		is(helper_noauto(f, "LABEL=a\033b", "macfuse_ext4") != NULL, 1, "a label with a control byte is refused");
		is(helper_noauto(f, "UUID=0123abcd-4567-89ef-0123-456789abcdef", "macfuse_ext4") != NULL, 1, "a lowercase UUID is refused");
		is(helper_noauto(f, "UUID=nope", NULL) != NULL, 1, "a bad UUID is refused for a remove too");
		is(helper_noauto(f, "LABEL=a", "linuxfs_hfs") != NULL, 1, "a bundle that is not linuxfs's is refused");
		is(helper_noauto(f, "LABEL=a", "hfs") != NULL, 1, "the Mac's own bundle is refused");
		iss(slurp(f), mac, "and none of those touched the fstab");
		memset(big, '#', FSTAB_MAX + 1);
		big[FSTAB_MAX + 1] = '\0';
		spit(f, big);
		is(helper_noauto(f, "LABEL=a", NULL) != NULL, 1, "an fstab over 64 KiB is refused");
		is(strlen(slurp(f)), FSTAB_MAX + 1, "and left as it was");
		unlink(f);
		mkdir(f, 0755);
		is(helper_noauto(f, "LABEL=a", "macfuse_ext4") != NULL, 1, "an fstab that is a directory is refused");
		rmdir(f);
		mkfifo(f, 0644);
		is(helper_noauto(f, "LABEL=a", "macfuse_ext4") != NULL, 1, "an fstab that is a FIFO is refused (and not waited on)");
		unlink(f);
		snprintf(other, sizeof other, "%s/elsewhere", dir);
		spit(other, mac);
		snprintf(link, sizeof link, "%s", f);
		symlink(other, link);
		is(helper_noauto(f, "LABEL=a", "macfuse_ext4") != NULL, 1, "an fstab that is a symlink is refused");
		iss(slurp(other), mac, "and what it points at is untouched");
		is(lstat(f, &st) == 0 && S_ISLNK(st.st_mode), 1, "and the symlink is still a symlink");
		unlink(f);
		unlink(other);
		is(helper_noauto("/etc/hosts", "LABEL=a", NULL) != NULL, 1, "an fstab owned by someone else (root, for this test) is refused");

		/* through the socket's request lines; the attached disks are LINUXFS_TEST_DISKS (helper-test.sh): ext4 "helped" and ext4
		 * "my data" with UUID 0123ABCD-4567-89EF-0123-456789ABCDEF */
		spit(f, mac);
		if (!getenv("LINUXFS_TEST_DISKS"))
			printf("# LINUXFS_TEST_DISKS is not set: run me from helper-test.sh\n");
		/* noauto-add only for an attached volume of the bundle's type, by its UUID or volume name */
		answers("noauto-add LABEL=nowhere macfuse_ext4\n", getuid(), getuid(), "no no attached linuxfs volume matches", "noauto-add with no such disk attached is refused");
		answers("noauto-add LABEL=helped linuxfs_btrfs\n", getuid(), getuid(), "no no attached linuxfs volume matches", "noauto-add for a disk of another type is refused");
		answers("noauto-add UUID=0123ABCD-4567-89EF-0123-456789ABCDEE macfuse_ext4\n", getuid(), getuid(), "no no attached linuxfs volume matches", "noauto-add by a UUID no disk has is refused");
		answers("noauto-add LABEL=Linux macfuse_ext4\n", getuid(), getuid(), "no no attached linuxfs volume matches", "LABEL=Linux matches no volume that has another label");
		iss(slurp(f), mac, "and none of them touched the fstab");
		answers("noauto-add LABEL=helped macfuse_ext4\n", getuid(), getuid(), "ok", "noauto-add for the attached disk's volume name and type is done");
		answers("noauto-add UUID=0123abcd-4567-89EF-0123-456789ABCDEF macfuse_ext4\n", getuid(), getuid(), "no ", "a lowercase UUID is still refused");
		answers("noauto-remove LABEL=helped\n", getuid(), getuid(), "ok", "and removed");
		snprintf(big, sizeof big, "%s\n", mac);
		iss(slurp(f), big, "the fstab is the Mac's again (ended by a newline)");
		spit(f, mac);
		answers("noauto-add LABEL=my data macfuse_ext4\n", getuid(), getuid(), "ok", "noauto-add LABEL=<label with a space> BUNDLE is done");
		is(strstr(slurp(f), "\nLABEL=my\\040data none macfuse_ext4 rw,noauto # linuxfs\n") != NULL, 1, "the bundle is the last word, the rest the spec");
		answers("noauto-add LABEL=my data macfuse_ext4\n", getuid(), getuid(), "ok", "noauto-add again is ok");
		answers("noauto-remove LABEL=my data\n", getuid(), getuid(), "ok", "noauto-remove LABEL=<label> is done");
		snprintf(big, sizeof big, "%s\n", mac);
		iss(slurp(f), big, "and the fstab is back to the Mac's lines");
		answers("noauto-remove LABEL=my data\n", getuid(), getuid(), "ok", "noauto-remove of a missing entry is ok");
		answers("noauto-add LABEL=x\n", getuid(), getuid(), "no ", "noauto-add with no bundle is refused");
		answers("noauto-add LABEL=x linuxfs_hfs\n", getuid(), getuid(), "no ", "noauto-add with a bundle not ours is refused");
		answers("noauto-add LABEL=a#b macfuse_ext4\n", getuid(), getuid(), "no a label with #", "noauto-add with # in the label is refused, saying why");
		answers("noauto-add LABEL=a\nb macfuse_ext4\n", getuid(), getuid(), "no a request is one line", "a request with more after its line is refused");
		answers("noauto-remove \n", getuid(), getuid(), "no ", "noauto-remove with no spec is refused");
		answers("noauto-add LABEL=x macfuse_ext4\n", 502, 501, "no only the user at the console", "noauto-add from another user is refused");
		iss(slurp(f), big, "and none of the refused requests touched the fstab");
		/* noauto-remove-all (uninstall): every linuxfs line goes, no other */
		answers("noauto-add LABEL=helped macfuse_ext4\n", getuid(), getuid(), "ok", "an entry to remove");
		answers("noauto-add UUID=0123ABCD-4567-89EF-0123-456789ABCDEF macfuse_ext4\n", getuid(), getuid(), "ok", "and another");
		answers("noauto-remove-all extra\n", getuid(), getuid(), "no ", "noauto-remove-all takes nothing after it");
		answers("noauto-remove-all\n", 502, 501, "no only the user at the console", "noauto-remove-all from another user is refused");
		answers("noauto-remove-all\n", getuid(), getuid(), "ok", "noauto-remove-all is done");
		iss(slurp(f), big, "every linuxfs line is gone and the Mac's lines are as they were");
		answers("noauto-remove-all\n", getuid(), getuid(), "ok", "and with none left it is ok");
		iss(helper_noauto(f, NULL, "macfuse_ext4"), "a bundle needs a volume", "a bundle with no spec is refused");
		unlink(f);
		rmdir(dir);
		unsetenv("LINUXFS_FSTAB");
	}
	printf("1..%d\n", tapno);
	return failures ? 1 : 0;
}
